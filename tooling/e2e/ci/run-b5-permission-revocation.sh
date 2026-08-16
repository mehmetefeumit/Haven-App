#!/usr/bin/env bash
#
# B5 permission-revocation lane orchestrator —
# docs/CI_HARDENING_BACKLOG.md Workstream B, item B5: "Permission revocation
# mid-session | `pm revoke ACCESS_FINE_LOCATION`".
#
# # What this lane proves that no other lane does
#
# `haven/test/services/geolocator_location_service_test.dart` reaches
# `GeolocatorLocationService`'s `denied` / `deniedForever` branches
# (geolocator_location_service.dart:471-473, :474-482) only through a mocked
# `GeolocatorWrapper`, and every E2E scenario injects `FakeLocationService`,
# whose `checkPermission()` is a hardcoded `LocationPermissionStatus.always`
# (e2e/_lib/fake_location_service.dart:57). The REAL platform refusal — what
# a user who revokes the permission actually gets — executed nowhere in CI.
#
# B6 (`run-b6-location-provider-toggle.sh`) is the sibling, not a substitute:
# it switches the DEVICE-WIDE provider off, which lands on
# `isLocationServiceEnabled()` (:258). That is a different gate on a
# different object, and neither is reachable from the other.
#
# # Why TWO drives (this is the structural difference from B6)
#
# B6 keeps ONE drive alive and toggles underneath it. `pm revoke` cannot be
# used that way: AOSP's
# `PermissionManagerServiceImpl.revokeRuntimePermissionInternal` calls back
# into `PackageManagerService.onPermissionRevoked`, which posts
# `killUid(appId, userId, KILL_APP_REASON_PERMISSIONS_REVOKED)` — killing the
# app process is PART of the revocation. So on Android:
#
#   * the mid-session half is enforced by the OS, not by Haven; and
#   * Haven's own denied/deniedForever branches are reached only on the NEXT
#     launch.
#
# A single-drive lane could therefore only ever prove "a dead process
# publishes nothing", which is true of every app and says nothing about this
# one. ACT 2 — a second drive of the SAME target against the SAME install,
# with the permission still revoked — is what actually executes the branches
# B5 is about. The drive target selects its act from `checkPermission()`, so
# a revoke that silently failed cannot be mistaken for one that worked: the
# process would run ACT 1 again, publish, and the relay-side window below
# would go red with a real finding.
#
# ACT 1 does NOT assume the kill. If the process survives (a different OEM
# policy, a future AOSP change) it observes the revocation from the inside
# and MEASURES how long publishing continues — see the stale-cache trap.
#
# # Phase 4a: the APP-OP window, and why the revoke needs it
#
# The kill is also what makes `pm revoke` UNABLE to test the thing the
# stale-cache trap describes: the cache is process-local, so it dies with the
# app and a green revoke half is compatible with a cache that would have
# leaked. `cmd appops set --uid PKG android:fine_location deny` is the
# reachable variant — it withdraws location access with the process still
# running and with every permission read still answering "granted" — so ACT 1
# runs THAT first, in the same live session, and asserts the promise itself:
# after access is withdrawn, no coordinate is produced and none is published.
#
# `--uid` is load-bearing, not a flourish. `AppOpsService` resolves a
# non-default UID mode and returns it WITHOUT consulting the package mode, and
# the runtime-permission → app-op sync leaves a `whileInUse` location grant at
# UID mode `foreground` (allowed for a foregrounded app). The package-scoped
# `set` this lane shipped with was therefore overridden and withdrew nothing:
# CI run 31868809387 read the mode back as `deny` while the app went on
# receiving fixes and published five of them.
#
# The mode the platform then STORES at UID scope is `ignore`, not the `deny`
# that was asked for, and that is the denial WORKING rather than failing — see
# b5_appops_mode_withholds, which is why the read-back below tests a set of
# withholding modes and not one string.
#
# It is gated twice because either gate alone passes vacuously. `cmd appops
# set` exits 0 whether or not it took and an app-op has no `dumpsys package`
# line, so the EFFECTIVE mode is READ BACK (`cmd appops get`, uid scope over
# package scope — see b5_appops_mode) and a mode the platform still serves
# location under is fatal on the spot. A mode that reads as withholding and
# changes nothing is a different failure the read-back cannot see, so the drive
# target must independently report that real location reads stopped working.
#
# # The oracle
#
#   1. BASELINE_PUBLISHED n=<N>, N >= 1    permission held -> the app
#                                          publishes (PARSED, not grepped:
#                                          `n=0` is the failing case and
#                                          contains the marker)
#   A. the APP-OP window (see below)       access withdrawn from a LIVE
#                                          process: the app-op read back as
#                                          `deny` and back out again, the app
#                                          SAW reads stop, no coordinate was
#                                          produced (APPOPS_GPS_REFUSED, not
#                                          _LEAKED), APPOPS_DONE max=0, and
#                                          the relay saw nothing new
#   2. the RELAY independently holds >= 1  the same claim, off the wire, and
#      location event                      the self-validation of the
#                                          absence proof in (7): a scanner
#                                          that cannot see a publish that
#                                          DID happen cannot be trusted to
#                                          report one that should not have
#   3. both permissions revoked, VERIFIED  `pm revoke` is not trusted on its
#      via `dumpsys package`               exit code (trap 1)
#   4. ACT 2 ran, in a DIFFERENT pid       the relaunch really happened
#   5. ACT2_ARMED eligible=<n>, n >= 1     anti-vacuity: it had somewhere to
#                                          publish to
#   6. ACT2_GPS_REFUSED present,           the denied/deniedForever branch
#      ACT2_GPS_LEAKED absent,             executed, and no position was
#      ACT2_DONE max=0                     produced or published
#   7. ZERO new location events on the     the bounded-window ABSENCE proof,
#      relay for the whole ACT 2 window    independent of the app's own
#                                          reporting — and the only check
#                                          that also covers the per-circle
#                                          scheduler ticking in the
#                                          background
#
# (7) is a diff over EVENT IDS, never a count. Kind-445 location events carry
# a NIP-40 `expiration` (created_at + 228 s, MARMOT_PROTOCOL_KNOWLEDGE.md)
# and strfry deletes them on its expiry cron, so a cumulative count DROPS on
# its own and "count unchanged" is not an absence proof. The window is also
# POLLED rather than read once at the end, for the same reason: an event
# published early in the window can expire before the window closes.
#
# Only APPLICATION messages carry `expiration`; MLS commits and proposals do
# not (haven-core/src/circle/manager.rs, `evolution_commit_carries_no_
# expiration_tag`). That is what lets (7) discriminate a location publish
# from the group traffic ACT 2's own circle creation legitimately generates.
#
# # Traps this lane is built around
#
#   1. A REJECTED `pm grant`/`pm revoke` STILL EXITS 0 — the hard-restricted
#      gate is a bare `return` after a `Log.e`. `dumpsys package` is the
#      gate, in both directions.
#   2. THE STALE-FIX CACHE — and the reason `pm revoke` alone cannot see it.
#      `getCurrentLocation()` serves `_lastStreamPosition` whenever the
#      cached GPS FIX TIME is within `kStreamPositionMaxAge` (168 s), so
#      wherever the process survives losing location access, publishing
#      would continue on the last fix. `pm revoke` KILLS the process and the
#      cache is process-local, so the revoke half is compatible with a cache
#      that would have leaked; ACT 1 measures the tail anyway, and Phase 4a's
#      APP-OP window is what actually settles it (see below).
#   2b. AN APP-OP DENIAL IS INVISIBLE TO THE APP. `checkPermission()` and
#      `getLocationAccuracy()` both read the permission GRANT via
#      `ContextCompat.checkSelfPermission`, which does not consult the
#      app-op, and AOSP drops deliveries without a guaranteed stream error or
#      close. (An app-op CHANGE does re-evaluate live registrations, and run
#      31868809387 caught one surfacing as a transient
#      `LocationServiceDisabledException` on the position stream — but that is
#      an incidental consequence of the mode edit, not a contract, and a
#      denial applied before the app subscribes raises nothing at all.) So the
#      drive target cannot tell when the denial landed by asking — it waits
#      for a real one-shot read to stop working, which is also why the mode is
#      read back HERE rather than trusted.
#   2c. AN APP-OP HAS TWO SCOPES AND THE UID ONE WINS. `AppOpsService`
#      short-circuits on a non-default UID mode and never reads the package
#      mode, and a `whileInUse` location grant leaves the UID mode at
#      `foreground`. So `cmd appops set PKG <op> deny` — package scope — is a
#      no-op for a foregrounded app, while `cmd appops get` still prints
#      `deny` on the package line. Both the SET and the READ-BACK have to be
#      uid-aware, or the phase asserts against an app that never lost access
#      and reports its perfectly legitimate publishes as a leak.
#   2d. THE PLATFORM REWRITES THE MODE IT WAS ASKED FOR. `set --uid ... deny`
#      lands as UID mode `ignore`, because `deny` (MODE_ERRORED) drives
#      AppOpsService to flag the runtime permission REVOKED_COMPAT and the
#      permission↔app-op sync answers that flag with MODE_IGNORED. So the
#      read-back must accept the modes that WITHHOLD, not the string that was
#      typed — and `ignore` is also the only one of the two compatible with
#      this phase's premise, since MODE_ERRORED is defined to raise a fatal
#      error rather than fail silently. See b5_appops_mode_withholds.
#   3. RE-PROMPTING. `getCurrentLocation()` calls `requestPermission()`
#      whenever it sees `denied` (:268), which raises the SYSTEM permission
#      dialog unless the grant is USER_FIXED — from a periodic publish tick,
#      with no user gesture. Nothing in CI dismisses that dialog, so this
#      lane sets `pm set-permission-flags ... user-fixed` to keep ACT 2
#      deterministic, and RECORDS the read-back so a missing flag is
#      attributable instead of presenting as a hang.
#   4. `adb emu geo fix` is a ONE-SHOT injection into the goldfish GNSS HAL.
#      The re-issue loop keeps running THROUGH ACT 2 on purpose: a publish
#      that survived the revoke then proves the app ignored the permission,
#      not that its position source dried up. It also has to MOVE the point
#      between re-issues — the app's stream carries `distanceFilter: 1`, so
#      re-issuing the same coordinates emits once and never again, and the
#      cache the app-op window is about would age out on its own. See
#      GEO_STEP_DEG.
#   5. `pm clear` between acts resets runtime permissions to their default,
#      so the revoke MUST be re-applied and re-verified afterwards. It is
#      used because ACT 2 needs a fresh MLS database: the E2E keyring is
#      in-memory and process-scoped (`useInMemoryKeyringForTest`), so a
#      second process mints a NEW SQLCipher passphrase and cannot open ACT
#      1's database at all.
#
# Usage:
#   run-b5-permission-revocation.sh [<apk> [<target.dart>]]
#   run-b5-permission-revocation.sh --self-test   # hermetic, no device
#
# Optional env:
#   B5_DRIVE1_TIMEOUT      per-drive bound for ACT 1. Default 14m.
#   B5_DRIVE2_TIMEOUT      per-drive bound for ACT 2. Default 14m.
#   B5_ARM_MARKER_TIMEOUT  wait for ACT 1's revoke cue. Default 480s.
#   B5_REVOKE_SETTLE       seconds absorbed into the baseline after the
#                          revoke. Default 20.
#   B5_RELAY_POLL_SECS     ACT 2 relay poll period. Default 20.
#   B5_GEO_REISSUE_SECS    `geo fix` re-issue period. Default 5.
#   B5_GEO_LAT/B5_GEO_LON  injected point. Defaults to a public landmark.
#   B5_GEO_STEP_DEG        how far each re-issue moves the point. Default
#                          0.00003 (~3.3 m). MUST stay above the stream's 1 m
#                          distance filter — see Phase 3.
#   B5_APPOPS_VERIFY_TIMEOUT   `cmd appops get` read-back poll. Default 40s.
#   B5_APPOPS_SETTLE           seconds absorbed into the baseline after the
#                              app-op is verified denied. Default 20.
#   B5_APPOPS_WINDOW_TIMEOUT   wait for the app-op window to close. Default
#                              480s.
#   B5_APPOPS_MIN_DENY_SECS    minimum time the app-op stays denied. Default
#                              168 (one kLocationPublishMaxInterval).

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# Shared app-side failure predicate — `flutter drive` can exit 0 on a failed
# suite (drive-log-lib.sh). Sourced before the --self-test dispatch so the
# hermetic self-test runs against a fully-wired script.
# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "${SCRIPT_DIR}/drive-log-lib.sh"

# Shared `detect_strfry_bin`. The candidate path list is a property of the
# pinned relay IMAGE, not of this lane, and B9 probes the same one — sourced
# rather than copied so the two cannot drift.
# shellcheck source=tooling/e2e/ci/strfry-lib.sh
source "${SCRIPT_DIR}/strfry-lib.sh"

# ---------------------------------------------------------------------------
# VERBATIM markers. MUST match the `k*Marker` constants in
# haven/integration_test/b5_permission_revocation_test.dart — change both
# together or the lane silently stops finding them.
#
# Fixed literals matched with `grep -aF`: logcat is binary-tainted and these
# strings contain regex metacharacters.
# ---------------------------------------------------------------------------
readonly MARK_PHASE='[b5] PHASE'
readonly MARK_BASELINE='[b5] BASELINE_PUBLISHED'
readonly MARK_APPOPS_ARMED='[b5] APPOPS_ARMED'
readonly MARK_APPOPS_OBSERVED='[b5] APPOPS_OBSERVED'
readonly MARK_APPOPS_NOT_OBSERVED='[b5] APPOPS_NOT_OBSERVED'
readonly MARK_APPOPS_REFUSED='[b5] APPOPS_GPS_REFUSED'
readonly MARK_APPOPS_LEAKED='[b5] APPOPS_GPS_LEAKED'
readonly MARK_APPOPS_DONE='[b5] APPOPS_DONE'
readonly MARK_AWAIT_REVOKE='[b5] AWAITING_REVOKE'
readonly MARK_REVOKE_OBSERVED='[b5] REVOKE_OBSERVED'
readonly MARK_MIDSESSION_TAIL='[b5] MIDSESSION_TAIL'
readonly MARK_MIDSESSION_NEVER='[b5] MIDSESSION_NEVER_STOPPED'
readonly MARK_SURVIVED='[b5] SURVIVED_REVOKE'
readonly MARK_ACT2_ARMED='[b5] ACT2_ARMED'
readonly MARK_ACT2_REFUSED='[b5] ACT2_GPS_REFUSED'
readonly MARK_ACT2_LEAKED='[b5] ACT2_GPS_LEAKED'
readonly MARK_ACT2_DONE='[b5] ACT2_DONE'
# A publish cycle that never answered. Its own marker, never folded into
# ACT2_CYCLE: see the gate on `wedged=` in b5_assert_act2.
readonly MARK_ACT2_WEDGED='[b5] ACT2_WEDGED'
readonly MARK_COMPLETE='[b5] SEQUENCE_COMPLETE'

# The app-ops this lane denies and restores. `android:fine_location` is the
# one AOSP notes for an app holding ACCESS_FINE_LOCATION
# (`LocationPermissions.asAppOp`); the coarse op is denied alongside it so the
# withdrawal matches the both-permissions posture the revoke half uses.
readonly APPOPS_FINE='android:fine_location'
readonly APPOPS_COARSE='android:coarse_location'

# Mirrors `_maxArmingStreamAge` in b5_permission_revocation_test.dart. The
# app-op window is about a WARM cache, so an arming fix older than this means
# there was nothing left to leak.
readonly APPOPS_MAX_ARMING_STREAM_AGE_MS=60000

# Mirrors `kStreamPositionMaxAge` (haven/lib/src/constants/location.dart). A
# refusal recorded with a stream fix older than this discriminates nothing:
# the cache would have been refused with the app-op untouched.
readonly APPOPS_MAX_PROBE_STREAM_AGE_MS=168000

# The AOSP kill reason posted by `revokeRuntimePermissionInternal`. Recorded
# as EVIDENCE, never asserted: a platform that stops killing on revoke would
# make ACT 1's own mid-session measurements the interesting half, and the
# lane must not go red just because Android changed its mind.
readonly KILL_REASON='permissions revoked'

# ---------------------------------------------------------------------------
# Oracle predicates — pure text, no device, no relay. Everything the lane's
# verdict rests on lives here so `--self-test` can exercise it hermetically.
# ---------------------------------------------------------------------------

# b5_record_poll <log> <found-ids-text> — append EXACTLY ONE line for this poll.
#
# Unconditional by contract, and that is the whole point. This write used to sit
# inside the caller's "did we find anything?" branch, so the relay-poll log was
# only ever written when a new location event appeared — i.e. only when the lane
# was about to FAIL. On a passing run (no new events, which is precisely what B5
# asserts) the file stayed 0 bytes, the mandatory secret scan classified it
# UNUSABLE, returned rc=3, and the lane forced rc=1: B5 could not report PASS
# with every oracle satisfied.
#
# Extracted here, above the `--self-test` dispatch, so the property is pinned
# hermetically — the caller needs docker and a device, this does not.
b5_record_poll() {
  local log="${1:-}" found="${2:-}" count=0
  if [[ -n "${found}" ]]; then
    count="$(printf '%s\n' "${found}" | grep -ac . || true)"
  fi
  printf '%s poll: %s new location event(s) observed\n' \
    "$(date -u +%H:%M:%S)" "${count:-0}" >> "${log}"
}

# b5_prepare_logs_for_scan <dir> — make <dir> safe to hand to the secret scanner
# AND safe to upload, by ensuring every file left in it is a `*.log`.
#
# The scanner's directory walk only picks up `*.log`, so anything else would be
# uploaded as a CI artefact WITHOUT being scanned — the hole this lane's own
# workflow comment warns about for `diag.txt`.
#
# Non-empty files are promoted and therefore scanned. Empty ones are DELETED
# rather than promoted, and that distinction is the whole point: to the scanner
# every path is a caller ASSERTION that a capture happened, so a 0-byte input is
# a hard rc=3. `relay-act2-new.ids` and its `.raw` are written only when a new
# location event appears — this lane's FAILURE condition — so on a PASSING run
# they are legitimately empty, and promoting them forced rc=1 on a green lane.
# An empty intermediate has no bytes to leak and no evidence to keep.
#
# Scope, stated precisely because the obvious phrasing overclaims: this makes
# every file the LANE CAPTURED scannable. It says nothing about files the guard
# itself writes AFTERWARDS — `LEAK_DETECTED.txt` is created by `cleanup` on the
# leak branch, after both this call and the scan, and is therefore uploaded
# unscanned. That is deliberate and safe: its content is two fixed English lines
# this script emits, not captured output, so there is nothing in it to scan.
#
# Extracted above the `--self-test` dispatch so the property is pinned
# hermetically; it lived inline in `cleanup`, which no fixture can reach.
b5_prepare_logs_for_scan() {
  local dir="${1:-}" stray
  [[ -d "${dir}" ]] || return 0
  while IFS= read -r -d '' stray; do
    if [[ -s "${stray}" ]]; then
      mv -n -- "${stray}" "${stray}.log" 2>/dev/null || true
      if [[ -e "${stray}" ]]; then
        echo "WARN: could not promote ${stray} for scanning; deleting it rather" \
             "than uploading it unscanned." >&2
        rm -f -- "${stray}" || true
      fi
    else
      rm -f -- "${stray}" || true
    fi
  done < <(find "${dir}" -type f ! -name '*.log' -print0 2>/dev/null)
}

# b5_has_marker <logfile> <marker> — 0 (true) when the marker appears.
#
# Substring match, not anchored: the same line reaches us either as raw
# `debugPrint` output in a drive log or wrapped by logcat's
# `I/flutter ( 1234): ` prefix, and both must count.
b5_has_marker() {
  local logfile="${1:-}" marker="${2:-}"
  [[ -f "${logfile}" ]] || return 1
  grep -aqF -- "${marker}" "${logfile}"
}

# b5_marker_number <logfile> <marker> <key> — echoes the LARGEST integer
# following `<key>=` on any line carrying <marker>, or nothing when no such
# line exists.
#
# PARSED, never grepped for presence. `[b5] BASELINE_PUBLISHED n=0` is the
# failing case and contains the marker substring, so a presence check would
# bless a run in which the app published to nothing.
#
# `sort -n`, never lexical: '9' outranks '12' lexically.
b5_marker_number() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[0-9]+" \
      | grep -aoE '[0-9]+' | LC_ALL=C sort -n | tail -1; } || true
}

# b5_phase_pid <logfile> <act> — echoes the pid recorded by the `[b5] PHASE
# act=<act> ... pid=<pid>` line, or nothing.
#
# Used to prove ACT 2 ran in a DIFFERENT OS process from ACT 1 — i.e. that
# the app really was relaunched after the revoke, rather than the same
# process running the second half.
b5_phase_pid() {
  local logfile="${1:-}" act="${2:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${MARK_PHASE} act=${act} " "${logfile}" 2>/dev/null \
      | grep -aoE 'pid=[0-9]+' | grep -aoE '[0-9]+' | tail -1; } || true
}

# b5_permission_granted <dumpsys-file> <permission> — 0 (true) when
# `dumpsys package` reports the permission as granted.
#
# `pm grant` / `pm revoke` exit 0 even when they refuse (trap 1), so this is
# the gate in BOTH directions. Matched on the `<perm>: granted=true` shape
# rather than on `granted=true` alone, because one dump lists every
# permission and a neighbouring granted one would otherwise answer for ours.
b5_permission_granted() {
  local dump="${1:-}" perm="${2:-}"
  [[ -f "${dump}" ]] || return 1
  grep -aqE "${perm}: granted=true" "${dump}"
}

# b5_permission_user_fixed <dumpsys-file> <permission> — 0 (true) when the
# permission carries the USER_FIXED flag ("don't ask again").
#
# Informational: it is what keeps ACT 2 free of a system permission dialog
# (trap 3), and its absence is the first thing to check when ACT 2 reports a
# TimeoutException from its one-shot probe.
b5_permission_user_fixed() {
  local dump="${1:-}" perm="${2:-}"
  [[ -f "${dump}" ]] || return 1
  grep -aE "${perm}: granted=" "${dump}" 2>/dev/null | grep -q 'USER_FIXED'
}

# b5_appops_scoped_mode <appops-get-dump> <op> <uid|package> — echoes the mode
# `cmd appops get` reported for <op> AT THAT SCOPE, or nothing.
#
# `cmd appops get PKG OP` prints both scopes, the uid-scoped one on its own
# `Uid mode:` line and the package-scoped one bare, so the scope is a line
# filter:
#
#   Uid mode: FINE_LOCATION: foreground
#   FINE_LOCATION: deny; time=+754ms ago
#
# Three per-line shapes have shipped across AOSP releases and all three are
# accepted, because pinning one and reading an empty string on an image that
# uses another would fail OPEN, in the one place this lane cannot afford it:
#
#   android:fine_location: deny; rejectTime=+1m2s
#   FINE_LOCATION: deny
#   android:fine_location: mode=deny
b5_appops_scoped_mode() {
  local dump="${1:-}" op="${2:-}" scope="${3:-}" short lines
  [[ -f "${dump}" ]] || return 0
  short="$(printf '%s' "${op#android:}" | tr '[:lower:]' '[:upper:]')"
  if [[ "${scope}" == "uid" ]]; then
    lines="$(grep -a 'Uid mode:' "${dump}" 2>/dev/null || true)"
  else
    lines="$(grep -av 'Uid mode:' "${dump}" 2>/dev/null || true)"
  fi
  [[ -n "${lines}" ]] || return 0
  { printf '%s\n' "${lines}" \
      | grep -aoE "(${op}|${short}):[[:space:]]*(mode=)?[a-z_]+" \
      | grep -aoE '[a-z_]+$' | tail -1; } || true
}

# b5_appops_mode <appops-get-dump> <op> — echoes the EFFECTIVE mode for <op>,
# or nothing when the dump has no entry for it at either scope.
#
# THE GATE THAT KEEPS THIS LANE FROM PROVING NOTHING. `cmd appops set` exits 0
# whether or not it took, exactly like `pm revoke` (trap 1), and unlike the
# permission there is no `dumpsys package` line to fall back on — the app-op
# is invisible to the app by construction, so a silent no-op would leave every
# app-side assertion in the app-op phase satisfied by an app that never lost
# access.
#
# EFFECTIVE, not package-scoped, and that distinction cost CI run 31868809387.
# `AppOpsService` resolves a non-default UID mode and returns it WITHOUT ever
# consulting the package mode, and the runtime-permission → app-op sync leaves
# a `whileInUse` location grant at UID mode `foreground` — which evaluates to
# ALLOWED for a foregrounded app. A package-scoped `deny` under it changes
# nothing, so a reader that answered with the package mode reported the app-op
# denied while the app went on receiving fixes and published five of them.
# Reading the scope that actually governs is what turns that into a fast,
# attributable failure instead of a window that asserts against an app which
# never lost access.
#
# `cmd appops get` printing NOTHING is a real state (no entry recorded — see
# the probe caveat in CI_HARDENING_BACKLOG.md, Workstream B), which is why
# this echoes the empty string rather than guessing a default: the caller
# decides, and every caller here runs the answer through
# b5_appops_mode_withholds. An explicit `default` UID mode is the no-override
# state and defers to the package mode for the same reason `AppOpsService`
# does.
b5_appops_mode() {
  local dump="${1:-}" op="${2:-}" uid_mode
  uid_mode="$(b5_appops_scoped_mode "${dump}" "${op}" uid)"
  if [[ -n "${uid_mode}" && "${uid_mode}" != "default" ]]; then
    printf '%s\n' "${uid_mode}"
    return 0
  fi
  b5_appops_scoped_mode "${dump}" "${op}" package
}

# b5_appops_mode_withholds <mode> — 0 when the platform serves NO location
# under <mode>, 1 for every mode it does serve location under, the empty read
# included.
#
# WHY A SET AND NOT `[[ $mode == deny ]]`: `ignore` IS THE SUCCESSFUL DENIAL.
# `cmd appops set --uid PKG android:fine_location deny` asks for MODE_ERRORED,
# but `AppOpsService.setUidMode` runs `updatePermissionRevokedCompat` first,
# which stamps FLAG_PERMISSION_REVOKED_COMPAT on ACCESS_FINE_LOCATION for any
# mode that is neither `allow` nor `foreground`; `PermissionPolicyService`
# watches that state and its `shouldGrantAppOp()` returns false on exactly that
# flag, so its sync writes the UID mode back as MODE_IGNORED. `ignore` is the
# platform's own word for this op being denied, and CI run 31956248635 read it
# back on the first run of the `--uid` form.
#
# It is also the mode this phase NEEDS. MODE_IGNORED is specified as "silently
# fail (it should not cause the app to crash)" and REVOKED_COMPAT as data
# "protected by a no-op … instead of crashing the client", where MODE_ERRORED
# is "a fatal error, typically a SecurityException". A live process that keeps
# running while location is withheld is the only arrangement in which the
# stale-fix cache is observable at all — kill the process and there is no cache
# left to leak, which is precisely why `pm revoke` cannot reach this.
#
# `deny` stays accepted alongside it because it withholds too: the location
# stack asks `mode == MODE_ALLOWED` and nothing finer
# (`SystemAppOpsHelper.checkOpNoThrow` / `noteOpNoThrow` / `startOpNoThrow`),
# so an image that stores what was asked for still withdraws access.
#
# NOTHING ELSE IS A NEAR MISS, and each rejected mode means something different:
#   allow       access intact.
#   foreground  what the sync leaves for a `whileInUse` grant, and ALLOWED for
#               a foregrounded app — the vacuous pass of CI run 31868809387.
#   default     no override at either scope, and OP_FINE_LOCATION's own default
#               mode is MODE_ALLOWED.
#   <empty>     nothing read back at all; the fail-open direction this gate
#               exists to close.
b5_appops_mode_withholds() {
  case "${1:-}" in
    ignore | deny) return 0 ;;
    *) return 1 ;;
  esac
}

# b5_expiring_445_ids <scanfile> — echoes the sorted, unique ids of every
# kind-445 event in a `strfry scan` capture that carries a NIP-40
# `expiration` tag, i.e. every LOCATION event.
#
# The tag is the discriminator, not the kind: kind 445 also carries MLS
# commits and proposals, which ACT 2's own circle creation legitimately
# produces and which carry NO expiration (haven-core/src/circle/manager.rs,
# `evolution_commit_carries_no_expiration_tag`). Counting bare kind-445s
# would make the absence proof fail on correct behaviour.
#
# Anchored on `"id"` so the 64-hex `pubkey` on the same line is never
# harvested as an event id.
b5_expiring_445_ids() {
  local scan="${1:-}"
  [[ -f "${scan}" ]] || return 0
  { grep -aF '"expiration"' "${scan}" 2>/dev/null \
      | grep -aoE '"id"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' \
      | grep -aoE '[0-9a-f]{64}' \
      | LC_ALL=C sort -u; } || true
}

# b5_new_ids <ids-file> <baseline-file> — echoes every id present in
# <ids-file> and absent from <baseline-file>.
#
# A DIFF, never a count: location events expire off the relay on strfry's
# own cron (their NIP-40 expiration is created_at + 228 s), so the total
# falls on its own and "count unchanged" proves nothing. A missing baseline
# yields every id, which is the fail-closed direction — a lane that lost its
# baseline must not report "no new events".
b5_new_ids() {
  local ids="${1:-}" baseline="${2:-}"
  [[ -f "${ids}" ]] || return 0
  if [[ ! -f "${baseline}" ]]; then
    cat "${ids}"
    return 0
  fi
  LC_ALL=C comm -13 "${baseline}" "${ids}" || true
}

# ---------------------------------------------------------------------------
# The oracle itself, as a testable function over the capture files.
#
# Findings accumulate in B5_FINDINGS rather than exiting on the first one:
# the lane's value is the WHOLE picture (did it publish, did the OS kill it,
# did the branches run, did anything leak), and stopping at the first failure
# would hide the rest behind it. Returns 1 when any finding was recorded.
#
# NOTES (never failures) go to stdout as evidence.
# ---------------------------------------------------------------------------
B5_FINDINGS=()

b5_note() { printf '  NOTE: %s\n' "$*"; }
b5_finding() { B5_FINDINGS+=("$*"); }

# b5_run_oracle <logfile> <baseline-ids> <new-ids> [<killed:0|1>]
#                [<appops-new-ids> <appops-denied-mode> <appops-restored-mode>]
b5_run_oracle() {
  local log="${1:-}" baseline_ids="${2:-}" new_ids="${3:-}" killed="${4:-0}"
  local appops_new_ids="${5:-}" appops_denied="${6:-}" appops_restored="${7:-}"
  B5_FINDINGS=()

  if [[ ! -f "${log}" ]]; then
    b5_finding "no capture file at '${log}' — the lane recorded nothing."
    return 1
  fi

  # --- ACT 1 -------------------------------------------------------------
  local act1_pid act2_pid
  act1_pid="$(b5_phase_pid "${log}" 1)"
  act2_pid="$(b5_phase_pid "${log}" 2)"

  if [[ -z "${act1_pid}" ]]; then
    b5_finding "no '${MARK_PHASE} act=1' line — ACT 1 never reached the point \
where it reports its own permission state, so the permission was never held \
by a running app and nothing below is attributable to the revoke."
  fi

  # (1) The app published WITH the permission. PARSED.
  local baseline
  baseline="$(b5_marker_number "${log}" "${MARK_BASELINE}" 'n')"
  if [[ -z "${baseline}" ]]; then
    b5_finding "no '${MARK_BASELINE} n=<N>' line — ACT 1 never completed a \
baseline publish attempt, so observing that the app does not publish after \
the revoke proves nothing."
  elif (( baseline < 1 )); then
    b5_finding "the baseline publish reached ${baseline} circles with \
ACCESS_FINE_LOCATION GRANTED. The app was not publishing BEFORE the revoke, \
so this run has nothing to take away. Suspect the emulator GPS seed (\`adb \
emu geo fix\`), the verified permission grant, or circle eligibility."
  else
    b5_note "baseline: published to ${baseline} circle(s) with the \
permission granted."
  fi

  # (2) The RELAY saw it too — the independent half of the baseline, and the
  #     self-validation of the absence proof at (7). A scanner that cannot
  #     see a publish that DID happen cannot be trusted to report one that
  #     should not have.
  local baseline_count=0
  if [[ -f "${baseline_ids}" ]]; then
    baseline_count="$(grep -ac . "${baseline_ids}" 2>/dev/null || true)"
    baseline_count="${baseline_count:-0}"
  fi
  if (( baseline_count < 1 )); then
    b5_finding "the relay holds ZERO location events (kind 445 carrying a \
NIP-40 expiration) from ACT 1. Either the app published nothing, or the \
\`strfry scan\` oracle is not reading the relay — and in both cases the \
ACT 2 absence proof below is VACUOUS, because a scanner that reports 'none' \
unconditionally would pass it."
  else
    b5_note "the relay independently holds ${baseline_count} ACT 1 location \
event(s) — the absence oracle at (7) is proven able to see a publish."
  fi

  # --- (A) THE APP-OP PHASE — access withdrawn from a LIVE process. --------
  #
  # The only arrangement in which the stale-fix cache is observable at all:
  # `pm revoke` kills the process and takes the cache with it, so everything
  # ACT 1's revoke half and ACT 2 assert is compatible with a cache that
  # would have leaked. This block is where that is settled.

  # (A1) DISCRIMINATION. Did the app-op actually change, and was it put back?
  #      `cmd appops set` exits 0 either way and there is no `dumpsys` line
  #      to fall back on, so without this a no-op `set` passes everything.
  if ! b5_appops_mode_withholds "${appops_denied}"; then
    b5_finding "\`cmd appops get\` read '${appops_denied:-<nothing>}' for \
${APPOPS_FINE} after the lane denied it — a mode the platform still serves \
location under (b5_appops_mode_withholds). The app-op never changed, so \
nothing in this phase observed an app that lost location access — and every \
assertion in it passes trivially."
  elif b5_appops_mode_withholds "${appops_restored}"; then
    b5_finding "${APPOPS_FINE} still read \
'${appops_restored:-<nothing>}' after the lane restored it — location is \
still withheld from the package, which poisons every later scenario on it."
  else
    b5_note "the location app-op read '${appops_denied}' while the window ran \
and '${appops_restored:-<default>}' after it — the condition this phase rests \
on provably varied."
  fi

  # (A2) ANTI-VACUITY. A cold cache has nothing to leak, and a phase with no
  #      eligible circle has nowhere to leak it to.
  local appops_stream_age appops_eligible
  appops_stream_age="$(b5_marker_number "${log}" "${MARK_APPOPS_ARMED}" \
    'streamAgeMs')"
  appops_eligible="$(b5_marker_number "${log}" "${MARK_APPOPS_ARMED}" \
    'eligible')"
  if [[ -z "${appops_stream_age}" || -z "${appops_eligible}" ]]; then
    b5_finding "no '${MARK_APPOPS_ARMED} streamAgeMs=<ms> eligible=<n>' \
line — the app-op phase never armed, so the one scenario that can observe \
the stale-fix cache did not run. (The drive target prints streamAgeMs=-1 \
when it never saw a fresh stream fix, which reads as missing here on \
purpose.)"
  else
    if (( appops_stream_age > APPOPS_MAX_ARMING_STREAM_AGE_MS )); then
      b5_finding "the app-op phase armed with its newest stream fix \
${appops_stream_age}ms old. The cached fix it is supposed to withhold had \
already aged out, so refusing to serve it proves nothing. The emulator GPS \
must MOVE — an \`adb emu geo fix\` re-issued at one point is filtered out by \
the stream's 1 m distance filter."
    fi
    if (( appops_eligible < 1 )); then
      b5_finding "the app-op window ran with ${appops_eligible} \
publish-eligible circles, so 'the app published nothing' is vacuous there."
    fi
  fi

  # (A3) The denial has to be OBSERVABLE to the app. Unlike the revoke, it
  #      does not kill the process, so an app that never notices is an app
  #      the denial never reached — the second half of (A1)'s question, and
  #      the half a read-back cannot answer.
  if b5_has_marker "${log}" "${MARK_APPOPS_NOT_OBSERVED}"; then
    b5_finding "real location reads went on working for the whole app-op \
observation window ('${MARK_APPOPS_NOT_OBSERVED}'). The app-op read back as \
denied but had no effect on this app."
  elif ! b5_has_marker "${log}" "${MARK_APPOPS_OBSERVED}"; then
    b5_finding "neither '${MARK_APPOPS_OBSERVED}' nor \
'${MARK_APPOPS_NOT_OBSERVED}' was recorded — the app-op phase never reached \
the point where it checks whether the denial took effect."
  fi

  # (A4) THE PROMISE: no coordinate is produced from a live process whose
  #      access was withdrawn.
  if b5_has_marker "${log}" "${MARK_APPOPS_LEAKED}"; then
    b5_finding "getCurrentLocation() RETURNED A POSITION after the location \
app-op was denied ('${MARK_APPOPS_LEAKED}'). The permission gate cannot see \
an app-op, so this is the cached fix being served past the consent that \
produced it — the defect this phase exists to catch."
  elif ! b5_has_marker "${log}" "${MARK_APPOPS_REFUSED}"; then
    b5_finding "neither '${MARK_APPOPS_REFUSED}' nor '${MARK_APPOPS_LEAKED}' \
was recorded — the app-op phase never made its decisive read."
  else
    local probe_age
    probe_age="$(b5_marker_number "${log}" "${MARK_APPOPS_REFUSED}" \
      'streamAgeMs')"
    if [[ -z "${probe_age}" ]]; then
      b5_finding "'${MARK_APPOPS_REFUSED}' carries no streamAgeMs, so there \
is no evidence the withheld cache was warm and the refusal cannot be \
attributed to the app-op."
    elif (( probe_age > APPOPS_MAX_PROBE_STREAM_AGE_MS )); then
      b5_finding "the app-op probe refused with its newest stream fix \
${probe_age}ms old, past kStreamPositionMaxAge \
(${APPOPS_MAX_PROBE_STREAM_AGE_MS}ms). A cache that stale is refused with \
the app-op untouched, so this refusal discriminates nothing."
    fi
  fi

  # (A5) …and none is published, by the app's own count.
  local appops_cycles appops_max appops_wedged
  appops_cycles="$(b5_marker_number "${log}" "${MARK_APPOPS_DONE}" 'cycles')"
  appops_max="$(b5_marker_number "${log}" "${MARK_APPOPS_DONE}" 'max')"
  if [[ -z "${appops_cycles}" || -z "${appops_max}" ]]; then
    b5_finding "no '${MARK_APPOPS_DONE} cycles=<c> max=<m>' line — the \
app-op absence window never closed, so the app-side half of that proof is \
missing."
  else
    if (( appops_cycles < 1 )); then
      b5_finding "the app-op absence window ran ${appops_cycles} publish \
cycles — it proved nothing about what the app does once access is withdrawn."
    fi
    appops_wedged="$(b5_marker_number "${log}" "${MARK_APPOPS_DONE}" \
      'wedged')"
    appops_wedged="${appops_wedged:-0}"
    if (( appops_wedged > 0 )); then
      b5_finding "${appops_wedged} of ${appops_cycles} app-op publish \
cycle(s) never returned ('${MARK_ACT2_WEDGED}'). A hung publish path is not \
evidence that the app declined to publish, so max=${appops_max} proves \
nothing here."
    elif (( appops_max > 0 )); then
      b5_finding "the app published location to ${appops_max} circle(s) with \
the location app-op DENIED. Access was withdrawn from the running process \
and the app went on broadcasting the position it already held."
    else
      b5_note "app-op window: ${appops_cycles} production publish cycles, \
all returning and all reaching 0 circles, with location access withdrawn \
from the live process."
    fi
  fi

  # (A6) …and the relay agrees, which is the only check that also covers the
  #      per-circle scheduler ticking in the background.
  if [[ ! -f "${appops_new_ids}" ]]; then
    b5_finding "no app-op relay-diff file at '${appops_new_ids:-<unset>}' — \
the bounded-window absence proof did not run for the app-op phase."
  else
    local appops_new_count
    appops_new_count="$(grep -ac . "${appops_new_ids}" 2>/dev/null || true)"
    appops_new_count="${appops_new_count:-0}"
    if (( appops_new_count > 0 )); then
      b5_finding "${appops_new_count} NEW location event(s) reached the relay \
while the location app-op was denied. The app is still broadcasting the \
user's position after the platform stopped letting it collect one."
    else
      b5_note "the relay saw no new location event for the whole app-op \
window."
    fi
  fi

  # (3) What the OS did with the live session. EVIDENCE, never a gate.
  if (( killed == 1 )); then
    b5_note "the OS terminated the app process as part of the revocation \
(logcat: '${KILL_REASON}'). On Android the mid-session half of this \
scenario is enforced by the platform, and the app's own denied branches are \
reached only on the relaunch ACT 2 performs."
  elif b5_has_marker "${log}" "${MARK_SURVIVED}"; then
    b5_note "the app process SURVIVED the revoke, so ACT 1's mid-session \
readings are real measurements."
  else
    b5_note "the app process did not reach '${MARK_SURVIVED}' and no kill \
was recorded — ACT 1 ended for some third reason. The ACT 2 proof below is \
unaffected, but the mid-session half was not measured."
  fi

  # (4) The mid-session behaviour, only when it was observable.
  if b5_has_marker "${log}" "${MARK_MIDSESSION_NEVER}"; then
    b5_finding "the app kept publishing location for the whole mid-session \
window AFTER its permission was revoked ('${MARK_MIDSESSION_NEVER}'). This \
is a privacy failure, not a liveness one."
  elif b5_has_marker "${log}" "${MARK_MIDSESSION_TAIL}"; then
    local tail_secs
    tail_secs="$(b5_marker_number "${log}" "${MARK_MIDSESSION_TAIL}" 'tail')"
    b5_note "publishing stopped ${tail_secs:-?}s after the app observed the \
revocation. Expected ~0s; anything approaching kStreamPositionMaxAge (168s) \
means the access gate was reordered back BELOW the cache read in \
getCurrentLocation() (geolocator_location_service.dart:639 must stay ahead of \
:651). The app-op window above is the direct test of the same property — this \
is only reachable when the process outlives the revoke."
  fi

  # --- ACT 2 — where the denied/deniedForever branches actually run. -----
  if [[ -z "${act2_pid}" ]]; then
    b5_finding "no '${MARK_PHASE} act=2' line — the app was never relaunched \
with the permission revoked, so the production denied/deniedForever branches \
(geolocator_location_service.dart:471-473, :474-482) were not exercised at \
all. This lane's whole subject is missing."
  elif [[ -n "${act1_pid}" && "${act1_pid}" == "${act2_pid}" ]]; then
    b5_finding "ACT 1 and ACT 2 both report pid ${act2_pid} — the same OS \
process ran both halves, so no relaunch happened and ACT 2's readings are \
not the post-revocation cold-start state they claim to be."
  fi

  # (5) Anti-vacuity: it had somewhere to publish to.
  local eligible
  eligible="$(b5_marker_number "${log}" "${MARK_ACT2_ARMED}" 'eligible')"
  if [[ -z "${eligible}" ]]; then
    b5_finding "no '${MARK_ACT2_ARMED} eligible=<n>' line — ACT 2 never \
reported whether it had a publish-eligible circle, so 'the app published \
nothing' cannot be distinguished from 'the app had nowhere to publish'."
  elif (( eligible < 1 )); then
    b5_finding "ACT 2 ran with ${eligible} publish-eligible circles. The \
absence of location events is VACUOUS on this run — the app had nowhere to \
publish regardless of the permission."
  fi

  # (6) The branch under test, and the direct leak check.
  if b5_has_marker "${log}" "${MARK_ACT2_LEAKED}"; then
    b5_finding "getCurrentLocation() RETURNED A POSITION with the location \
permission revoked ('${MARK_ACT2_LEAKED}') — the app can still read the \
device position after the user took that away."
  elif ! b5_has_marker "${log}" "${MARK_ACT2_REFUSED}"; then
    b5_finding "neither '${MARK_ACT2_REFUSED}' nor '${MARK_ACT2_LEAKED}' was \
recorded — ACT 2 never reached its one-shot location probe, so the \
denied/deniedForever branch was not observed either way."
  fi

  local act2_cycles act2_max
  act2_cycles="$(b5_marker_number "${log}" "${MARK_ACT2_DONE}" 'cycles')"
  act2_max="$(b5_marker_number "${log}" "${MARK_ACT2_DONE}" 'max')"
  if [[ -z "${act2_cycles}" || -z "${act2_max}" ]]; then
    b5_finding "no '${MARK_ACT2_DONE} cycles=<c> max=<m>' line — the ACT 2 \
absence window never closed, so the app-side half of the proof is missing."
  else
    if (( act2_cycles < 1 )); then
      b5_finding "the ACT 2 absence window ran ${act2_cycles} publish \
cycles — it proved nothing about what the app does with a revoked \
permission."
    fi
    if (( act2_max > 0 )); then
      b5_finding "ACT 2's own publish path reached ${act2_max} circle(s) \
with ACCESS_FINE_LOCATION revoked — the app published location it had no \
permission to collect."
    fi

    # A WEDGED cycle is not a zero cycle. `max=0` is this lane's passing
    # condition, and a publish call that never answered contributes a 0 to it
    # without having observed anything — so without this gate a wholly hung
    # publish path reads as the strongest possible pass. Absent (an older
    # drive target that predates the field) is treated as 0 rather than as a
    # finding, so the gate cannot fail a run for a missing field alone.
    local act2_wedged
    act2_wedged="$(b5_marker_number "${log}" "${MARK_ACT2_DONE}" 'wedged')"
    act2_wedged="${act2_wedged:-0}"
    if (( act2_wedged > 0 )); then
      b5_finding "${act2_wedged} of ${act2_cycles} ACT 2 publish cycle(s) \
never returned ('${MARK_ACT2_WEDGED}'). A hung publish path is not evidence \
that the app declined to publish, so the max=${act2_max} reading above proves \
nothing. Check this phase's USER_FIXED read-back and the \`pm clear\` result \
first — both put ACT 2 in a state where the publish path stalls for reasons \
unrelated to the revocation."
    elif (( act2_max == 0 )); then
      b5_note "ACT 2: ${act2_cycles} production publish cycles, all returning \
and all reaching 0 circles, with the permission revoked."
    fi
  fi

  # (7) THE ABSENCE PROOF, off the relay and independent of the app's own
  #     reporting — the only check that also covers the per-circle scheduler
  #     ticking in the background, which ACT 2's explicit cycles cannot see.
  if [[ ! -f "${new_ids}" ]]; then
    b5_finding "no ACT 2 relay-diff file at '${new_ids}' — the bounded-window \
absence proof did not run, and the app's own reporting is the only evidence \
left."
  else
    local new_count
    new_count="$(grep -ac . "${new_ids}" 2>/dev/null || true)"
    new_count="${new_count:-0}"
    if (( new_count > 0 )); then
      b5_finding "${new_count} NEW location event(s) (kind 445 with a NIP-40 \
expiration) reached the relay during the ACT 2 window, with \
ACCESS_FINE_LOCATION revoked. The app is still broadcasting the user's \
location after the user revoked its permission to collect it."
    else
      b5_note "the relay saw no new location event for the whole ACT 2 \
window."
    fi
  fi

  (( ${#B5_FINDINGS[@]} == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no device, no relay, no docker.
#
# The fixtures are chosen so a predicate that has rotted into always-passing
# cannot survive: (4) is the `n=0` near-miss a presence-grep would bless,
# (9) is a commit-only relay capture that must yield NO location ids, and
# (20)/(21) are the two whole-capture cases that must land on opposite
# verdicts — without the passing one, a hard-coded "always red" oracle would
# look correct.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fails=0 checks=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <expected-rc> <actual-rc>
    local label="$1" want="$2" got="$3"
    checks=$(( checks + 1 ))
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%s, got rc=%s)\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _eq_case() { # _eq_case <label> <expected> <actual>
    local label="$1" want="$2" got="$3"
    checks=$(( checks + 1 ))
    if [[ "${got}" == "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want "%s", got "%s")\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  # _assert_mutated <fixture-no> <file> <expected-substring>
  #
  # A mutation that did not apply leaves a COPY of the passing capture, so the
  # "negative" fixture asserts nothing and the self-test reports a green it did
  # not earn. The fixture's own rc cannot tell the two apart, so the mutation
  # itself is checked here.
  #
  # Both ways of getting this wrong have already happened in this file: a
  # reworded marker line silently stops matching, and a `\`+newline inside a
  # `sed` REPLACEMENT inserts a LITERAL newline — splitting the line so the
  # field survives a `grep -F` but lands where the oracle never reads it.
  _assert_mutated() { # <fixture-no> <file> <expected-substring>
    local n="$1" file="$2" want="$3"
    if ! grep -qF -- "${want}" "${file}"; then
      printf '  \033[1;31mFAIL\033[0m self-test setup (%s): the mutation did \
not apply — expected %s\n' "${n}" "${want}" >&2
      fails=1
    fi
  }

  # A complete, PASSING capture: the app publishes with the permission, the
  # OS kills it on revoke, and the relaunch publishes nothing. Written as a
  # function so each negative fixture can mutate exactly one line.
  _fixture_full() { # _fixture_full <outfile> [act2-probe-line]
    local out="$1"
    local probe="${2:-I/flutter ( 91): ${MARK_ACT2_REFUSED} type=LocationServiceException}"
    printf '%s\n' \
      "I/flutter ( 40): ${MARK_PHASE} act=1 perm=whileInUse pid=40" \
      "I/flutter ( 40): ${MARK_BASELINE} n=1" \
      "I/flutter ( 40): ${MARK_APPOPS_ARMED} streamAgeMs=4200 eligible=1" \
      "I/flutter ( 40): ${MARK_APPOPS_OBSERVED} after=41" \
      "I/flutter ( 40): ${MARK_APPOPS_REFUSED} \
type=LocationServiceException streamAgeMs=52000" \
      "I/flutter ( 40): [b5] APPOPS_CYCLE i=1 n=0" \
      "I/flutter ( 40): ${MARK_APPOPS_DONE} cycles=5 max=0 wedged=0" \
      "I/flutter ( 40): ${MARK_AWAIT_REVOKE}" \
      "I/flutter ( 91): ${MARK_PHASE} act=2 perm=denied pid=91" \
      "I/flutter ( 91): ${MARK_ACT2_ARMED} eligible=1" \
      "${probe}" \
      "I/flutter ( 91): [b5] ACT2_CYCLE i=1 n=0" \
      "I/flutter ( 91): ${MARK_ACT2_DONE} cycles=9 max=0 wedged=0" \
      "I/flutter ( 91): ${MARK_COMPLETE}" \
      > "${out}"
  }

  echo "run-b5-permission-revocation.sh --self-test"

  # --- b5_has_marker ------------------------------------------------------
  # (1) A raw drive-log line (no logcat prefix).
  printf '%s\n' "${MARK_AWAIT_REVOKE}" > "${tmp}/raw.log"
  local rc=0; b5_has_marker "${tmp}/raw.log" "${MARK_AWAIT_REVOKE}" || rc=1
  _case "marker found in a raw drive log" 0 "${rc}"

  # (2) THE SHAPE THAT ACTUALLY SHIPS — the same line via logcat, prefixed.
  #     An anchored match would pass fixture (1) and fail every real run.
  printf '%s\n' "I/flutter ( 4021): ${MARK_AWAIT_REVOKE}" \
    > "${tmp}/logcat.log"
  rc=0; b5_has_marker "${tmp}/logcat.log" "${MARK_AWAIT_REVOKE}" || rc=1
  _case "marker found behind a logcat prefix" 0 "${rc}"

  # (3) Absent marker, and a missing file, are both false.
  rc=0; b5_has_marker "${tmp}/logcat.log" "${MARK_SURVIVED}" || rc=1
  _case "absent marker reports false" 1 "${rc}"
  rc=0; b5_has_marker "${tmp}/nope.log" "${MARK_AWAIT_REVOKE}" || rc=1
  _case "missing file reports false" 1 "${rc}"

  # --- b5_marker_number ---------------------------------------------------
  # (4) THE CRITICAL FIXTURE — `n=0` contains the marker substring. A
  #     presence grep would bless a run that published to nothing.
  printf '%s\n' "I/flutter ( 40): ${MARK_BASELINE} n=0" > "${tmp}/zero.log"
  _eq_case "n=0 parses as 0, not as presence" "0" \
    "$(b5_marker_number "${tmp}/zero.log" "${MARK_BASELINE}" 'n')"

  # (5) No such line yields EMPTY, never a spurious 0 a caller could confuse
  #     with "a cycle ran and published nothing".
  _eq_case "absent marker yields empty" "" \
    "$(b5_marker_number "${tmp}/zero.log" "${MARK_ACT2_DONE}" 'max')"

  # (6) Double digits must not mis-sort ('9' outranks '12' lexically).
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_BASELINE} n=9" \
    "I/flutter ( 40): ${MARK_BASELINE} n=12" \
    > "${tmp}/wide.log"
  _eq_case "largest of 9 and 12 is 12" "12" \
    "$(b5_marker_number "${tmp}/wide.log" "${MARK_BASELINE}" 'n')"

  # (7) Several keys on ONE line must not bleed into each other. `wedged=` was
  #     appended after `max=`, so the trailing key is the one most likely to be
  #     picked up by a lazy pattern anchored on the marker alone.
  printf '%s\n' "I/flutter ( 91): ${MARK_ACT2_DONE} cycles=9 max=0 wedged=3" \
    > "${tmp}/two.log"
  _eq_case "cycles= reads 9 on a line that also has max=0" "9" \
    "$(b5_marker_number "${tmp}/two.log" "${MARK_ACT2_DONE}" 'cycles')"
  _eq_case "max= reads 0 on a line that also has cycles=9" "0" \
    "$(b5_marker_number "${tmp}/two.log" "${MARK_ACT2_DONE}" 'max')"
  _eq_case "wedged= reads 3 past both earlier keys" "3" \
    "$(b5_marker_number "${tmp}/two.log" "${MARK_ACT2_DONE}" 'wedged')"

  # --- b5_phase_pid -------------------------------------------------------
  _fixture_full "${tmp}/full.log"
  # (8) Each act's pid is read from its OWN line, not from whichever came
  #     last — the relaunch proof depends on telling them apart.
  _eq_case "ACT 1 pid" "40" "$(b5_phase_pid "${tmp}/full.log" 1)"
  _eq_case "ACT 2 pid" "91" "$(b5_phase_pid "${tmp}/full.log" 2)"

  # --- b5_expiring_445_ids ------------------------------------------------
  local id_a='aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888'
  local id_b='1111aaaa2222bbbb3333cccc4444dddd5555eeee6666ffff7777aaaa8888bbbb'
  local pk='9999999999999999999999999999999999999999999999999999999999999999'

  # (9) A COMMIT-ONLY capture. Kind 445 with no `expiration` tag is MLS
  #     evolution traffic, which ACT 2's own circle creation legitimately
  #     produces. Counting it would fail a correct app.
  printf '%s\n' \
    "{\"id\":\"${id_a}\",\"pubkey\":\"${pk}\",\"kind\":445,\"tags\":[[\"h\",\"abc\"]]}" \
    > "${tmp}/commit.scan"
  _eq_case "a commit-only capture yields no location ids" "" \
    "$(b5_expiring_445_ids "${tmp}/commit.scan")"

  # (10) An application message — `h` + NIP-40 expiration — is a location.
  printf '%s\n' \
    "{\"id\":\"${id_b}\",\"pubkey\":\"${pk}\",\"kind\":445,\"tags\":[[\"h\",\"abc\"],[\"expiration\",\"1900000000\"]]}" \
    > "${tmp}/loc.scan"
  _eq_case "an expiration-tagged 445 yields its id" "${id_b}" \
    "$(b5_expiring_445_ids "${tmp}/loc.scan")"

  # (11) THE ANCHORING FIXTURE — the 64-hex `pubkey` on the same line must
  #      never be harvested as an event id, or every diff would be noise.
  _eq_case "the pubkey is not mistaken for an event id" "${id_b}" \
    "$(b5_expiring_445_ids "${tmp}/loc.scan")"

  # (12) Mixed capture: only the location event counts.
  cat "${tmp}/commit.scan" "${tmp}/loc.scan" > "${tmp}/mixed.scan"
  _eq_case "mixed capture yields only the location id" "${id_b}" \
    "$(b5_expiring_445_ids "${tmp}/mixed.scan")"

  # (13) An empty / missing capture yields nothing rather than erroring.
  : > "${tmp}/empty.scan"
  _eq_case "empty capture yields nothing" "" \
    "$(b5_expiring_445_ids "${tmp}/empty.scan")"
  _eq_case "missing capture yields nothing" "" \
    "$(b5_expiring_445_ids "${tmp}/absent.scan")"

  # --- b5_new_ids ---------------------------------------------------------
  printf '%s\n' "${id_a}" > "${tmp}/baseline.ids"
  printf '%s\n' "${id_a}" "${id_b}" | LC_ALL=C sort -u > "${tmp}/after.ids"
  # (14) Only the genuinely new id is reported.
  _eq_case "diff reports only the new id" "${id_b}" \
    "$(b5_new_ids "${tmp}/after.ids" "${tmp}/baseline.ids")"

  # (15) A baseline that still holds every id reports nothing — the passing
  #      direction, which must not be unreachable.
  _eq_case "unchanged set reports nothing" "" \
    "$(b5_new_ids "${tmp}/baseline.ids" "${tmp}/baseline.ids")"

  # (16) SHRINKAGE IS NOT A VIOLATION. Location events expire off the relay
  #      on strfry's own cron, so the set legitimately gets smaller.
  _eq_case "an expired-away baseline id is not reported as new" "" \
    "$(b5_new_ids "${tmp}/empty.scan" "${tmp}/baseline.ids")"

  # (17) A MISSING baseline reports everything — fail closed. A lane that
  #      lost its baseline must not answer "no new events".
  _eq_case "missing baseline reports every id" \
    "$(printf '%s\n%s' "${id_b}" "${id_a}" | LC_ALL=C sort -u)" \
    "$(b5_new_ids "${tmp}/after.ids" "${tmp}/absent.ids")"

  # --- b5_permission_granted / b5_permission_user_fixed -------------------
  local perm='android.permission.ACCESS_FINE_LOCATION'
  printf '%s\n' \
    '    runtime permissions:' \
    "      android.permission.ACCESS_COARSE_LOCATION: granted=true" \
    "      ${perm}: granted=false, flags=[ USER_SET|USER_FIXED ]" \
    > "${tmp}/revoked.dump"
  # (18) THE NEIGHBOUR FIXTURE — COARSE is granted on the line above. A
  #      bare `granted=true` grep would report FINE as granted.
  rc=0; b5_permission_granted "${tmp}/revoked.dump" "${perm}" || rc=1
  _case "a granted NEIGHBOUR does not answer for this permission" 1 "${rc}"
  rc=0
  b5_permission_granted "${tmp}/revoked.dump" \
    'android.permission.ACCESS_COARSE_LOCATION' || rc=1
  _case "the granted neighbour still reads as granted" 0 "${rc}"
  rc=0; b5_permission_user_fixed "${tmp}/revoked.dump" "${perm}" || rc=1
  _case "USER_FIXED is read off the permission's own line" 0 "${rc}"

  # (19) A permission absent from the dump is NOT granted (fail closed).
  rc=0
  b5_permission_granted "${tmp}/revoked.dump" \
    'android.permission.ACCESS_BACKGROUND_LOCATION' || rc=1
  _case "an unlisted permission reads as not granted" 1 "${rc}"

  # --- b5_appops_mode -----------------------------------------------------
  #
  # THE READ-BACK IS THE ONLY THING THAT KNOWS THE APP-OP CHANGED, so a
  # parser that silently answers "" on an image whose `cmd appops get`
  # wording differs would fail OPEN — the lane would call a no-op `set` a
  # denial and pass every app-side assertion. All three shipped shapes are
  # pinned here, and so is the genuinely-empty case.
  printf 'android:fine_location: deny; rejectTime=+1m2s743ms\n' \
    > "${tmp}/appops-semi.log"
  _eq_case "appops mode read from the 'deny; rejectTime=' shape" \
    "deny" "$(b5_appops_mode "${tmp}/appops-semi.log" "${APPOPS_FINE}")"

  printf 'FINE_LOCATION: deny\n' > "${tmp}/appops-short.log"
  _eq_case "appops mode read from the short op-name shape" \
    "deny" "$(b5_appops_mode "${tmp}/appops-short.log" "${APPOPS_FINE}")"

  printf 'android:fine_location: mode=allow\n' > "${tmp}/appops-mode.log"
  _eq_case "appops mode read from the 'mode=' shape" \
    "allow" "$(b5_appops_mode "${tmp}/appops-mode.log" "${APPOPS_FINE}")"

  printf 'No operations.\n' > "${tmp}/appops-none.log"
  _eq_case "an op with no recorded entry reads empty, never a guess" \
    "" "$(b5_appops_mode "${tmp}/appops-none.log" "${APPOPS_FINE}")"
  _eq_case "a missing appops dump reads empty" \
    "" "$(b5_appops_mode "${tmp}/nope.log" "${APPOPS_FINE}")"

  printf 'android:coarse_location: deny\n' > "${tmp}/appops-coarse.log"
  _eq_case "the fine op is not answered by a neighbouring coarse entry" \
    "" "$(b5_appops_mode "${tmp}/appops-coarse.log" "${APPOPS_FINE}")"

  # THE SHAPE THAT ACTUALLY SHIPS ON AN AVD, verbatim from CI run
  # 31868809387's own `appops.denied.b5.log`. Both scopes are printed and the
  # UID one governs: reading the last line answered "deny" for a package whose
  # app-op was still ALLOWED, so the phase ran against an app that had lost
  # nothing and reported five published location events as a leak.
  printf '%s\n' \
    'Uid mode: FINE_LOCATION: foreground' \
    'FINE_LOCATION: deny; time=+754ms ago' \
    > "${tmp}/appops-uid-foreground.log"
  _eq_case "a uid-scoped override outranks a denied package mode" \
    "foreground" \
    "$(b5_appops_mode "${tmp}/appops-uid-foreground.log" "${APPOPS_FINE}")"

  # …and the direction the lane depends on: a uid-scoped deny is the denial,
  # whatever the package mode says.
  printf '%s\n' \
    'Uid mode: FINE_LOCATION: deny' \
    'FINE_LOCATION: allow; time=+2s ago' \
    > "${tmp}/appops-uid-deny.log"
  _eq_case "a uid-scoped deny outranks an allowed package mode" \
    "deny" "$(b5_appops_mode "${tmp}/appops-uid-deny.log" "${APPOPS_FINE}")"

  # `default` is the no-override state, so the package mode governs — the same
  # rule AppOpsService applies, and the reason this is not simply "uid wins".
  printf '%s\n' \
    'Uid mode: FINE_LOCATION: default' \
    'FINE_LOCATION: deny; time=+2s ago' \
    > "${tmp}/appops-uid-default.log"
  _eq_case "a default uid mode defers to the package mode" \
    "deny" "$(b5_appops_mode "${tmp}/appops-uid-default.log" "${APPOPS_FINE}")"

  # A uid line for a NEIGHBOURING op must not answer for this one, exactly as
  # the package-scoped fixture above requires.
  printf '%s\n' \
    'Uid mode: COARSE_LOCATION: deny' \
    'COARSE_LOCATION: deny' \
    > "${tmp}/appops-uid-coarse.log"
  _eq_case "the fine op is not answered by a neighbouring coarse uid entry" \
    "" "$(b5_appops_mode "${tmp}/appops-uid-coarse.log" "${APPOPS_FINE}")"

  # WHAT `set --uid ... deny` ACTUALLY LEAVES BEHIND, verbatim from CI run
  # 31956248635 — the first run of the uid-scoped form. The platform stored
  # `ignore`, not the `deny` that was asked for, because the requested
  # MODE_ERRORED drove FLAG_PERMISSION_REVOKED_COMPAT onto the permission and
  # the sync answered that flag with MODE_IGNORED. The uid scope still governs.
  printf '%s\n' \
    'Uid mode: FINE_LOCATION: ignore' \
    'FINE_LOCATION: deny; time=+39s967ms ago' \
    > "${tmp}/appops-uid-ignore.log"
  _eq_case "the uid-scoped 'ignore' the platform stores is read back" \
    "ignore" \
    "$(b5_appops_mode "${tmp}/appops-uid-ignore.log" "${APPOPS_FINE}")"

  # --- b5_appops_mode_withholds -------------------------------------------
  #
  # THE ACCEPT SET IS THE GATE. Widening it past the modes that provably
  # withhold location would re-open exactly the vacuous window the read-back
  # exists to close, so both directions are pinned mode by mode.
  local mode
  for mode in ignore deny; do
    rc=0; b5_appops_mode_withholds "${mode}" || rc=1
    _case "'${mode}' withholds location" 0 "${rc}"
  done
  # `foreground` is the 31868809387 vacuous pass, `default` is
  # OP_FINE_LOCATION's own MODE_ALLOWED, and the empty read is the fail-open
  # direction. None of them may ever read as a denial.
  for mode in allow foreground default '' unknown; do
    rc=0; b5_appops_mode_withholds "${mode}" || rc=1
    _case "'${mode:-<nothing>}' does NOT withhold location" 1 "${rc}"
  done
  rc=0; b5_appops_mode_withholds || rc=1
  _case "a missing argument does NOT withhold location" 1 "${rc}"

  # --- shared libs are still wired ----------------------------------------
  # Their real behaviour is exercised elsewhere (drive-log-lib.sh's own
  # self-test; detect_strfry_bin needs docker). What is checkable here is that
  # the `source` survived a refactor — a lost one fails at Phase 0, after the
  # APK build.
  rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
  _case "drive-log failure predicate is in scope" 0 "${rc}"
  rc=0; declare -F detect_strfry_bin >/dev/null || rc=1
  _case "shared strfry reader is in scope" 0 "${rc}"

  # --- b5_run_oracle ------------------------------------------------------
  printf '%s\n' "${id_a}" > "${tmp}/oracle-baseline.ids"
  : > "${tmp}/oracle-new.ids"
  : > "${tmp}/oracle-appops.ids"

  # (20) THE PASSING CAPTURE. Without it a hard-coded "always red" oracle
  #      would look correct.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "a correct capture passes the oracle" 0 "${rc}"

  # (21) THE HEADLINE FAILURE — a new location event on the relay during the
  #      ACT 2 window.
  printf '%s\n' "${id_b}" > "${tmp}/oracle-leak.ids"
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-leak.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "a new relay location event fails the oracle" 1 "${rc}"

  # (22) The app's own leak marker fails it too, independently of the relay.
  _fixture_full "${tmp}/leaked.log" \
    "I/flutter ( 91): ${MARK_ACT2_LEAKED}"
  rc=0
  b5_run_oracle "${tmp}/leaked.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "ACT2_GPS_LEAKED fails the oracle" 1 "${rc}"

  # (23) VACUITY GUARD — an empty relay baseline means the scanner never saw
  #      a publish that DID happen, so the absence proof cannot be trusted.
  : > "${tmp}/oracle-nobaseline.ids"
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-nobaseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "an empty relay baseline fails the oracle" 1 "${rc}"

  # (24) VACUITY GUARD — ACT 2 with no eligible circle proves nothing.
  #
  # The mutations here and below quote the marker WITHOUT its `[b5]` prefix,
  # and the exclusion below uses `grep -F`: `[b5]` is a regex character class
  # (one of `b`, `5`), so a `sed`/`grep` pattern carrying it silently matches
  # nothing and the "negative" fixture would be a copy of the passing one —
  # a self-test that always passes, which is the failure mode this whole file
  # exists to prevent.
  sed 's/ACT2_ARMED eligible=1/ACT2_ARMED eligible=0/' \
    "${tmp}/full.log" > "${tmp}/noeligible.log"
  rc=0
  b5_run_oracle "${tmp}/noeligible.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "ACT 2 with no eligible circle fails the oracle" 1 "${rc}"

  # (25) ACT 2 never ran at all — the lane's whole subject missing.
  grep -avF -- "${MARK_PHASE} act=2" "${tmp}/full.log" > "${tmp}/noact2.log"
  rc=0
  b5_run_oracle "${tmp}/noact2.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "a missing ACT 2 fails the oracle" 1 "${rc}"

  # (26) SAME-PROCESS GUARD — both acts reporting one pid means no relaunch.
  sed 's/act=2 perm=denied pid=91/act=2 perm=denied pid=40/' \
    "${tmp}/full.log" > "${tmp}/samepid.log"
  rc=0
  b5_run_oracle "${tmp}/samepid.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "both acts in one process fails the oracle" 1 "${rc}"

  # (27) The baseline near-miss: the app never published WITH the permission.
  sed 's/BASELINE_PUBLISHED n=1/BASELINE_PUBLISHED n=0/' "${tmp}/full.log" \
    > "${tmp}/nobaseline.log"
  rc=0
  b5_run_oracle "${tmp}/nobaseline.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "a zero baseline publish fails the oracle" 1 "${rc}"

  # (28) THE SURVIVING-PROCESS PATH — publishing that never stopped after a
  #      revoke the process outlived. Must be a finding, not a note.
  {
    cat "${tmp}/full.log"
    printf '%s\n' \
      "I/flutter ( 40): ${MARK_SURVIVED}" \
      "I/flutter ( 40): ${MARK_MIDSESSION_NEVER}"
  } > "${tmp}/neverstopped.log"
  rc=0
  b5_run_oracle "${tmp}/neverstopped.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 0 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "mid-session publishing that never stopped fails the oracle" 1 "${rc}"

  # (29) …while a MEASURED stale-cache tail is recorded, not failed: the
  #      cache is documented behaviour and the number is the deliverable.
  {
    cat "${tmp}/full.log"
    printf '%s\n' \
      "I/flutter ( 40): ${MARK_SURVIVED}" \
      "I/flutter ( 40): ${MARK_MIDSESSION_TAIL} tail=176"
  } > "${tmp}/tail.log"
  rc=0
  b5_run_oracle "${tmp}/tail.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 0 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "a measured stale-cache tail is a note, not a failure" 0 "${rc}"

  # (30) A missing relay-diff file is fail-closed.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/absent-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "a missing relay diff fails the oracle" 1 "${rc}"

  # (31) THE WEDGED-CYCLE FIXTURE, and the reason the gate exists at all: a
  #      window whose publish cycles never ANSWERED still reports max=0, which
  #      is this lane's passing value. Every other field here is the passing
  #      capture, so this fixture isolates `wedged=` alone — a gate that read
  #      only `max` would call this the strongest possible pass.
  sed "s/ACT2_DONE cycles=9 max=0 wedged=0/ACT2_DONE cycles=9 max=0 wedged=2/" \
    "${tmp}/full.log" > "${tmp}/wedged.log"
  if ! grep -qF 'wedged=2' "${tmp}/wedged.log"; then
    echo "  SELF-TEST SETUP FAIL (31): the wedged mutation did not apply —" \
         "the passing fixture's ACT2_DONE line was reworded" >&2
    fails=1
  fi
  rc=0
  b5_run_oracle "${tmp}/wedged.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "publish cycles that never returned fail the oracle" 1 "${rc}"

  # (32) BACKWARD COMPATIBILITY, and the other direction of the same risk: a
  #      drive target that predates the field must not fail merely for
  #      omitting it. Absent reads as 0.
  sed "s/ ACT2_DONE cycles=9 max=0 wedged=0/ ACT2_DONE cycles=9 max=0/" \
    "${tmp}/full.log" > "${tmp}/nowedgefield.log"
  rc=0
  b5_run_oracle "${tmp}/nowedgefield.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 \
    "${tmp}/oracle-appops.ids" deny allow >/dev/null || rc=$?
  _case "an ACT2_DONE without the wedged field still passes" 0 "${rc}"

  # --- the app-op phase ----------------------------------------------------
  #
  # Every fixture below mutates exactly ONE field of the PASSING capture, so
  # each names the single thing it catches. Mutations quote markers WITHOUT
  # their `[b5]` prefix and exclusions use `grep -F` — see (24) for why.

  # (33) THE VACUOUS-ORACLE FIXTURE, and the reason this phase has a
  #      read-back at all: `cmd appops set` no-opped, so the app never lost
  #      access and every app-side marker above is still the passing one.
  #      Only the read-back can tell, which is exactly why it is a gate.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" foreground allow \
    >/dev/null || rc=$?
  _case "an app-op that never changed fails the oracle" 1 "${rc}"

  # (34) …and the same for a read-back that answered nothing at all.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" '' allow \
    >/dev/null || rc=$?
  _case "an empty app-op read-back fails the oracle" 1 "${rc}"

  # (35) CONTAINMENT — a lane that left the app-op denied poisons the runner.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny deny \
    >/dev/null || rc=$?
  _case "an app-op left denied fails the oracle" 1 "${rc}"

  # (36) The op changed and had NO EFFECT — the half a read-back cannot see.
  #
  #      The MESSAGE is pinned, not just the rc. Deleting the
  #      APPOPS_NOT_OBSERVED branch leaves the neighbouring "neither marker was
  #      recorded" one to fail this fixture for a DIFFERENT reason, so an
  #      rc-only assertion stays green over a diagnosis that no longer exists.
  #      Found by mutating the branch to `if false`.
  grep -avF -- 'APPOPS_OBSERVED' "${tmp}/full.log" > "${tmp}/notobserved.log"
  printf '%s\n' "I/flutter ( 40): ${MARK_APPOPS_NOT_OBSERVED}" \
    >> "${tmp}/notobserved.log"
  rc=0
  b5_run_oracle "${tmp}/notobserved.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "a denial the app never observed fails the oracle" 1 "${rc}"
  if [[ "${B5_FINDINGS[*]}" != *"had no effect on this app"* ]]; then
    printf '  \033[1;31mFAIL\033[0m an ineffective denial is not named as such\n' >&2
    fails=1
  fi

  # (37) THE HEADLINE — a coordinate produced after access was withdrawn from
  #      the live process. The defect `pm revoke` structurally cannot reach,
  #      and therefore the one finding in this phase that must be named rather
  #      than merely counted: with an rc-only assertion, deleting the leak
  #      branch outright still fails this fixture (through the neighbouring
  #      "never made its decisive read" one) and the self-test stays green over
  #      a missing detector. Found by mutating the branch to `if false`.
  grep -avF -- 'APPOPS_GPS_REFUSED' "${tmp}/full.log" > "${tmp}/appleak.log"
  printf '%s\n' "I/flutter ( 40): ${MARK_APPOPS_LEAKED} streamAgeMs=52000" \
    >> "${tmp}/appleak.log"
  rc=0
  b5_run_oracle "${tmp}/appleak.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "APPOPS_GPS_LEAKED fails the oracle" 1 "${rc}"
  if [[ "${B5_FINDINGS[*]}" != *"RETURNED A POSITION after the location"* ]]; then
    printf '  \033[1;31mFAIL\033[0m the app-op leak is not named as the defect\n' >&2
    fails=1
  fi

  # (38) VACUITY — armed with a cache that had already aged out. Every
  #      assertion still passes; there was simply nothing to withhold.
  sed 's/ARMED streamAgeMs=4200/ARMED streamAgeMs=140000/' \
    "${tmp}/full.log" > "${tmp}/coldarm.log"
  _assert_mutated 38 "${tmp}/coldarm.log" 'streamAgeMs=140000'
  rc=0
  b5_run_oracle "${tmp}/coldarm.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "an app-op window armed on a stale cache fails the oracle" 1 "${rc}"

  # (39) VACUITY — the refusal itself made against a cache past
  #      kStreamPositionMaxAge, which is refused with the app-op untouched.
  sed 's/streamAgeMs=52000/streamAgeMs=200000/' "${tmp}/full.log" \
    > "${tmp}/staleprobe.log"
  _assert_mutated 39 "${tmp}/staleprobe.log" \
    "APPOPS_GPS_REFUSED type=LocationServiceException streamAgeMs=200000"
  rc=0
  b5_run_oracle "${tmp}/staleprobe.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "a refusal made against a stale cache fails the oracle" 1 "${rc}"

  # (40) The app's own count says it published with access withdrawn.
  sed 's/DONE cycles=5 max=0/DONE cycles=5 max=2/' \
    "${tmp}/full.log" > "${tmp}/apppublished.log"
  _assert_mutated 40 "${tmp}/apppublished.log" 'cycles=5 max=2'
  rc=0
  b5_run_oracle "${tmp}/apppublished.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "publishing during the app-op window fails the oracle" 1 "${rc}"

  # (41) …and a window whose cycles never ANSWERED reports max=0 too.
  sed 's/cycles=5 max=0 wedged=0/cycles=5 max=0 wedged=3/' "${tmp}/full.log" \
    > "${tmp}/appwedged.log"
  _assert_mutated 41 "${tmp}/appwedged.log" 'cycles=5 max=0 wedged=3'
  rc=0
  b5_run_oracle "${tmp}/appwedged.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "wedged app-op publish cycles fail the oracle" 1 "${rc}"

  # (42) The RELAY saw a location event while the op was denied — the half
  #      the app's own cycles cannot see, because the per-circle scheduler
  #      ticks behind them.
  printf '%s\n' "${id_b}" > "${tmp}/oracle-appops-leak.ids"
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops-leak.ids" deny allow \
    >/dev/null || rc=$?
  _case "a relay location event during the app-op window fails" 1 "${rc}"

  # (43) A missing app-op relay diff is fail-closed, like (30).
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/absent-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "a missing app-op relay diff fails the oracle" 1 "${rc}"

  # (44) The phase never ran at all. Not a silent skip: `pm revoke` cannot
  #      substitute for it, so its absence removes the lane's only proof
  #      about the stale-fix cache.
  grep -avF -- 'APPOPS_ARMED' "${tmp}/full.log" > "${tmp}/noappops.log"
  rc=0
  b5_run_oracle "${tmp}/noappops.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" deny allow \
    >/dev/null || rc=$?
  _case "a missing app-op phase fails the oracle" 1 "${rc}"

  # (45) THE READING A REAL DEVICE PRODUCES. `set --uid ... deny` is stored as
  #      `ignore`, and that is the denial having taken — the run this pair was
  #      written for (31956248635) aborted on a gate that demanded the literal
  #      `deny`. The restored side lands on `foreground`, which is what the
  #      permission sync writes back for a `whileInUse` grant once the
  #      revoked-compat flag is cleared. Both halves must pass.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" ignore foreground \
    >/dev/null || rc=$?
  _case "a uid 'ignore' denial restored to 'foreground' passes" 0 "${rc}"

  # (46) …and the containment half of (35) for the mode the platform actually
  #      leaves: a restore that reads `ignore` is location STILL WITHHELD, and
  #      the gate that only knew the string `deny` could not see it. That is
  #      the state a uid-scoped `default` restore produces, so this is a
  #      reachable regression, not a hypothetical one.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" ignore ignore \
    >/dev/null || rc=$?
  _case "an app-op left on 'ignore' fails the oracle" 1 "${rc}"

  # (47) The remaining non-withholding modes, each fatal on the denied side for
  #      its own reason: `allow` never lost access, `default` is
  #      OP_FINE_LOCATION's own MODE_ALLOWED. (`foreground` is (33), the empty
  #      read is (34).) Without these the accept set could be widened to
  #      "anything but allow" and the self-test would not notice.
  for mode in allow default; do
    rc=0
    b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
      "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" "${mode}" allow \
      >/dev/null || rc=$?
    _case "a denied-side read of '${mode}' fails the oracle" 1 "${rc}"
  done

  # (48) An EMPTY restored read is not a denial — nothing was recorded at
  #      either scope, which for this op is MODE_ALLOWED. It must not be
  #      swept into the containment failure above.
  rc=0
  b5_run_oracle "${tmp}/full.log" "${tmp}/oracle-baseline.ids" \
    "${tmp}/oracle-new.ids" 1 "${tmp}/oracle-appops.ids" ignore '' \
    >/dev/null || rc=$?
  _case "an empty restored read passes the containment gate" 0 "${rc}"

  # --- the relay-poll capture must survive a PASSING run --------------------
  #
  # THE LANE-CANNOT-BE-GREEN FIXTURE. B5 passes when the relay sees NO new
  # location event in the ACT 2 window, and the poll log used to be written only
  # when one DID appear. So the passing run left a 0-byte log, the mandatory
  # secret scan reported it UNUSABLE (rc=3), and the lane forced rc=1 — red on
  # success, in both CI runs 30925179141 and 30964250098. If this ever regresses
  # to a conditional write, B5 becomes unpassable again and this fixture is the
  # only thing that says so without a device.
  local poll_log="${tmp}/relay-poll.b5.log"
  : > "${poll_log}"
  b5_record_poll "${poll_log}" ""
  _eq_case "a poll that finds nothing still writes its line" \
    "1" "$(grep -ac . "${poll_log}" || true)"
  _eq_case "…and the line records zero, not silence" \
    "1" "$(grep -ac '0 new location event' "${poll_log}" || true)"
  # Resolved here rather than via ${SECRET_SCAN}: that is declared with the rest
  # of the config, BELOW the --self-test dispatch, so it does not exist yet.
  local scanner
  scanner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan-logs-for-secrets.sh"
  _case "…so the scanner can read the log a PASSING lane leaves" \
    0 "$(bash "${scanner}" "${poll_log}" >/dev/null 2>&1; echo $?)"

  b5_record_poll "${poll_log}" "$(printf 'aa\nbb\n')"
  _eq_case "a poll that finds events appends a second line" \
    "2" "$(grep -ac . "${poll_log}" || true)"
  _eq_case "…and counts them" \
    "1" "$(grep -ac '2 new location event' "${poll_log}" || true)"

  # --- the WHOLE LOG DIR must scan clean on a passing lane ------------------
  #
  # The fixtures above scan ONE file; `cleanup` scans the DIRECTORY. That gap
  # is not academic — it is where the first version of this fix reintroduced
  # the bug it was fixing. Promoting every non-`*.log` file so nothing is
  # uploaded unscanned also promoted `relay-act2-new.ids` and its `.raw`, which
  # are written ONLY when a new location event appears (the lane's failure
  # condition) and are therefore 0 bytes on a GREEN run. Three empty
  # assertions, scanner rc=3, `rc=1` on a passing lane.
  local scandir="${tmp}/logdir"
  mkdir -p "${scandir}"
  printf '12:00:00 poll: 0 new location event(s) observed\n' \
    > "${scandir}/relay-poll.b5.log"
  printf 'drive output\n' > "${scandir}/drive1.log"
  : > "${scandir}/relay-act2-new.ids"          # empty on a PASSING lane
  : > "${scandir}/relay-act2-new.ids.raw"      # ditto
  : > "${scandir}/relay-baseline.ids"          # ditto
  printf 'deadbeef\n' > "${scandir}/relay-scan.tmp"   # has content -> must be scanned
  b5_prepare_logs_for_scan "${scandir}"
  _case "a PASSING lane's whole log dir still scans clean" \
    0 "$(bash "${scanner}" "${scandir}" >/dev/null 2>&1; echo $?)"
  _eq_case "…with every remaining file scannable (*.log)" \
    "0" "$(find "${scandir}" -type f ! -name '*.log' | grep -ac . || true)"
  _eq_case "…the non-empty intermediate kept, promoted and scanned" \
    "1" "$(find "${scandir}" -name 'relay-scan.tmp.log' | grep -ac . || true)"
  _eq_case "…and the empty ones dropped rather than asserted" \
    "0" "$(find "${scandir}" -name 'relay-act2-new.ids*' | grep -ac . || true)"

  if (( fails != 0 )); then
    echo "run-b5-permission-revocation.sh --self-test: FAILED" >&2
    return 1
  fi
  # COUNTED, never restated: a hardcoded total goes stale the moment a
  # fixture is added, and a self-test that misreports its own size is the
  # first thing a reader stops trusting.
  echo "run-b5-permission-revocation.sh --self-test: all ${checks} checks passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
readonly PKG="com.oblivioustech.haven"
readonly DEVICE="emulator-5554"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly LOG_DIR="/tmp/b5-logs"
readonly APK="${1:-/tmp/integration-apks/b5_permission_revocation_test.apk}"
readonly TARGET="${2:-integration_test/b5_permission_revocation_test.dart}"

readonly STRFRY_CONTAINER="${STRFRY_CONTAINER:-strfry}"

# Per-drive bounds. Both sit below the step deadline that wraps this script
# (see .github/workflows/e2e-permission-revocation.yml), so a hung drive
# fails with an attributable message rather than an anonymous 124.
readonly DRIVE1_TIMEOUT="${B5_DRIVE1_TIMEOUT:-14m}"
readonly DRIVE2_TIMEOUT="${B5_DRIVE2_TIMEOUT:-14m}"

# ACT 1 has to boot RustLib + SQLCipher, mount the app, create a circle and
# land a publish before it prints its cue. Generous: a late marker is still
# usable evidence, while a marker wait that fires early destroys the run.
readonly ARM_MARKER_TIMEOUT="${B5_ARM_MARKER_TIMEOUT:-480}"

# Absorbed into the relay baseline after the revoke. This lane deliberately
# makes NO claim about a publish already in flight at the instant the
# permission was withdrawn — that is a race with the OS kill, not a product
# behaviour, and asserting on it would produce a flaky red.
readonly REVOKE_SETTLE="${B5_REVOKE_SETTLE:-20}"

readonly RELAY_POLL_SECS="${B5_RELAY_POLL_SECS:-20}"
readonly GEO_REISSUE_SECS="${B5_GEO_REISSUE_SECS:-5}"

# Poll bound on the `cmd appops get` read-back. Polled rather than read once
# because the permission→app-op path is asynchronous (PermissionPolicyService
# posts to FgThread), and a single immediate read can still show the old mode
# (CI_HARDENING_BACKLOG.md, Workstream B).
readonly APPOPS_VERIFY_TIMEOUT="${B5_APPOPS_VERIFY_TIMEOUT:-40}"

# Absorbed into the relay baseline after the app-op is verified denied, for
# the same reason REVOKE_SETTLE exists: a publish already IN FLIGHT when
# access was withdrawn is a race with the platform, not a product behaviour,
# and asserting on it is a flaky red.
#
# It cannot hide the leak this window hunts. A served stale fix is not a
# one-shot: the cache stays inside `kStreamPositionMaxAge` for 168 s after the
# denial, the per-circle scheduler ticks at most every
# `kLocationPublishMaxInterval`, and the denial is held at least that long —
# so a leak necessarily publishes again after this settle. The app-side probe
# is a direct call and return, with no such race at all.
readonly APPOPS_SETTLE="${B5_APPOPS_SETTLE:-20}"

# Bound on ACT 1's app-op window, from the denial to the drive target's
# `APPOPS_DONE`. Above the target's own budget (arm + observation + probe +
# window) so a lane-side timeout means the drive is stuck, not merely slow.
readonly APPOPS_WINDOW_TIMEOUT="${B5_APPOPS_WINDOW_TIMEOUT:-480}"

# How long the app-op stays denied REGARDLESS of when the app-side window
# closes.
#
# `kLocationPublishMaxInterval` (haven/lib/src/constants/location.dart) is the
# longest interval the per-circle scheduler can sample, so holding the denial
# at least this long is what makes the relay-side absence proof cover a
# scheduled publish the app's own explicit cycles never see.
#
# COUPLED, and not obviously: this hold delays `pm revoke` past the drive
# target's `AWAITING_REVOKE`, and the target only waits
# `_revokeObservationTimeout` (120 s) for the revoke to become visible. The
# slack is `_revokeObservationTimeout - (this - the target's minimum app-op
# window)`; with `_appOpsAbsenceWindow` at 90 s the earliest APPOPS_DONE is
# ~100 s after the denial, so the revoke lands ~73 s into a 120 s wait. Raise
# this much above ~215, or shrink `_appOpsAbsenceWindow`, and ACT 1's
# mid-session half silently stops running WHEREVER THE PROCESS SURVIVES THE
# REVOKE — on stock Android the OS kill makes that half unreachable anyway,
# which is exactly why the regression would go unnoticed.
readonly APPOPS_MIN_DENY_SECS="${B5_APPOPS_MIN_DENY_SECS:-168}"

# Synthetic coordinates fed to the emulator's GPS: Dam Square, Amsterdam — a
# well-known public landmark, chosen precisely BECAUSE it is obviously not a
# real user's position. The kind-445 carrying it is MLS-encrypted on the wire.
#
# WARNING before overriding: `fail()` dumps `dumpsys location`, which PRINTS
# the active position into the step log and the uploaded artifact. Fine for a
# hardcoded landmark; NOT fine for anything derived from a real device.
readonly GEO_LON="${B5_GEO_LON:-4.895168}"
readonly GEO_LAT="${B5_GEO_LAT:-52.370216}"

# How far each re-issue moves the point, in degrees of latitude.
#
# NOT cosmetic, and NOT jitter for its own sake. The app's position stream
# carries `distanceFilter: 1` (metres), so a `geo fix` re-issued at the SAME
# point is filtered out by the platform and the stream emits exactly once for
# the life of the lane. The stale-fix cache the app-op window is about would
# then age out on its own long before the denial lands, the window would have
# nothing to withhold, and it would pass having proved nothing — which the
# drive target's `streamAgeMs` reports and the oracle treats as a finding.
#
# 0.00003° of latitude is ~3.3 m: comfortably above the filter, and still
# inside the same public landmark, so the "obviously not a real user's
# position" property of GEO_LAT/GEO_LON is unchanged.
readonly GEO_STEP_DEG="${B5_GEO_STEP_DEG:-0.00003}"
GEO_LAT_B="$(awk -v a="${GEO_LAT}" -v s="${GEO_STEP_DEG}" \
  'BEGIN { printf "%.6f", a + s }')"
readonly GEO_LAT_B

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
GEO_PID=""
DRIVE_PID=""
STRFRY_BIN=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b5.log"
readonly DRIVE1_LOG="${LOG_DIR}/flutter-drive.act1.log"
readonly DRIVE2_LOG="${LOG_DIR}/flutter-drive.act2.log"
readonly PERM_GRANTED_DUMP="${LOG_DIR}/permissions.granted.b5.log"
readonly PERM_REVOKED_DUMP="${LOG_DIR}/permissions.revoked.b5.log"
readonly PERM_ACT2_DUMP="${LOG_DIR}/permissions.act2-end.b5.log"
readonly BASELINE_IDS="${LOG_DIR}/relay-baseline.ids"
readonly NEW_IDS="${LOG_DIR}/relay-act2-new.ids"
readonly APPOPS_NEW_IDS="${LOG_DIR}/relay-appops-new.ids"
readonly APPOPS_DENIED_DUMP="${LOG_DIR}/appops.denied.b5.log"
readonly APPOPS_RESTORED_DUMP="${LOG_DIR}/appops.restored.b5.log"
readonly RELAY_POLL_LOG="${LOG_DIR}/relay-poll.b5.log"

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, RESTORE the permission
# (a lane that left the package revoked would silently poison any later job
# on this runner), run the MANDATORY secret scan over every captured log
# (Security Rule 6 — must run even on a phase failure), snapshot + tear down
# strfry. Escalates on a leak; never masks a phase rc.
#
# Mirrors run-b1/b3/b6 containment, including the deliberate asymmetry
# between rc 1 (leak -> destroy the logs) and rc 3 (unscannable -> keep them,
# because there is no leak and the truncated artefacts ARE the evidence of
# the failure that tripped the guard).
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  local scan_rc=0
  trap - EXIT
  if [[ -n "${DRIVE_PID}" ]] && kill -0 "${DRIVE_PID}" 2>/dev/null; then
    kill "${DRIVE_PID}" 2>/dev/null || true
  fi
  if [[ -n "${GEO_PID}" ]] && kill -0 "${GEO_PID}" 2>/dev/null; then
    kill "${GEO_PID}" 2>/dev/null || true
  fi
  # Restore BEFORE logcat is stopped so the restore itself is captured.
  #
  # BOTH SCOPES, because Phase 4 denies both. The uid one is the load-bearing
  # half here: it OUTRANKS the package mode, so a uid denial left behind is a
  # package with no location access no matter what the package mode says.
  # Unconditional, because the lane can die inside the denied window and a
  # package left without location access silently poisons every later job on
  # this runner.
  #
  # The uid scope goes to `allow`, NOT to `default`, for the reason spelled out
  # at the Phase 4 restore: `default` leaves FLAG_PERMISSION_REVOKED_COMPAT
  # standing and the permission↔app-op sync answers it with `ignore`, so the
  # tidy-looking teardown is the one that leaves location withheld. Only the
  # uid `allow` clears the flag; the package scope can then go to `default`,
  # which is the no-override state and never touches that flag.
  for op in "${APPOPS_FINE}" "${APPOPS_COARSE}"; do
    adb -s "${DEVICE}" shell cmd appops set --uid "${PKG}" "${op}" allow \
      >/dev/null 2>&1 || true
    adb -s "${DEVICE}" shell cmd appops set "${PKG}" "${op}" default \
      >/dev/null 2>&1 || true
  done
  adb -s "${DEVICE}" shell pm clear-permission-flags "${PKG}" \
    android.permission.ACCESS_FINE_LOCATION user-fixed >/dev/null 2>&1 || true
  adb -s "${DEVICE}" shell pm clear-permission-flags "${PKG}" \
    android.permission.ACCESS_COARSE_LOCATION user-fixed >/dev/null 2>&1 \
    || true
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  docker logs "${STRFRY_CONTAINER}" > "${LOG_DIR}/strfry.final.log" 2>&1 \
    || true
  # Everything in LOG_DIR is uploaded as a CI artefact, but the scanner's
  # directory walk only picks up `*.log` (scan-logs-for-secrets.sh) — so the
  # relay scratch and id files (`relay-scan.tmp`, `*.ids`, `*.raw`, `*.err`)
  # were being uploaded UNSCANNED, the exact hole this lane's own workflow
  # comment warns about for `diag.txt`. Closed here rather than by renaming
  # every call site, so a future file cannot opt out by accident.
  #
  # Rules and rationale live on b5_prepare_logs_for_scan, which is above the
  # --self-test dispatch so the "a passing lane must still scan clean" property
  # is pinned by a fixture rather than only by this call site.
  b5_prepare_logs_for_scan "${LOG_DIR}"
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  bash "${SECRET_SCAN}" "${LOG_DIR}" || scan_rc=$?
  if (( scan_rc == 1 )); then
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    {
      echo "Logs withheld: the secret-leak guard tripped (Security Rule 6)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped on B5 logs — logs deleted," \
         "not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    # An unscannable log is only NEWS on a lane that otherwise succeeded. When
    # the lane has already failed, the abort is why the capture is short or
    # missing, and reporting it as a second, differently-worded ERROR buries the
    # real cause under a downstream symptom — which is precisely what happened
    # in CI runs 30925179141 and 30964250098, where `B5-LANE-FAIL` was followed
    # by an rc=3 complaint about a relay-poll log the abort had prevented.
    #
    # The guard itself is NOT relaxed: the scan still runs unconditionally, and
    # an unscannable log on a PASSING lane is still fatal. Only the reporting
    # changes, and only in the direction of not overwriting a more specific rc
    # with a less specific one. A leak (rc=1) escalates in both branches above
    # regardless — that path is untouched.
    if (( rc == 0 )); then
      echo "ERROR: secret-leak guard could not scan the B5 logs" \
           "(rc=${scan_rc}) — see the UNUSABLE line(s) above. The lane" \
           "otherwise PASSED, so this is a real capture failure: an expected" \
           "log was never written and the privacy scan therefore proved" \
           "nothing. Logs kept for triage." >&2
      rc=1
    else
      echo "NOTE: the secret-leak guard could not scan every B5 log" \
           "(rc=${scan_rc}) because the lane aborted before those captures" \
           "were written — see the UNUSABLE line(s) above and the" \
           "B5-LANE-FAIL line for the actual failure. Preserving the original" \
           "exit code ${rc}. Logs kept for triage." >&2
    fi
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "B5-LANE-FAIL: $*" >&2
  echo "---- [b5] markers seen ----" >&2
  grep -ahF '[b5] ' "${LOGCAT_FILE}" "${DRIVE1_LOG}" "${DRIVE2_LOG}" \
    2>/dev/null | tail -60 >&2 \
    || echo "(none — the drive target reached no checkpoint at all)" >&2
  echo "---- permission state (revoked dump) ----" >&2
  grep -aE 'ACCESS_(FINE|COARSE)_LOCATION' "${PERM_REVOKED_DUMP}" 2>/dev/null \
    | sed 's/^/    /' >&2 || echo "(no revoked dump captured)" >&2
  echo "---- app-op read-backs ----" >&2
  cat "${APPOPS_DENIED_DUMP}" "${APPOPS_RESTORED_DUMP}" 2>/dev/null \
    | sed 's/^/    /' >&2 || echo "(no appops dumps captured)" >&2
  # The injected point is a hardcoded public landmark, so printing it is
  # acceptable here (same posture as run-b1/b3/b6).
  echo "---- emulator location state ----" >&2
  adb -s "${DEVICE}" shell dumpsys location 2>/dev/null \
    | grep -aiA 4 'last location\|fused\|gps provider' | head -40 >&2 \
    || echo "(dumpsys location unavailable)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Relay access. `strfry scan` reads the LMDB directly, which is the only way
# to see what the hermetic relay actually holds: at `dumpInEvents = false` /
# `dumpInReqs = false` (tooling/e2e/strfry.conf) strfry logs no EVENT, REQ or
# connection lines at all, so every log-scraping oracle over it is vacuous
# (CI_HARDENING_BACKLOG.md, Workstream B).
# ---------------------------------------------------------------------------

# `detect_strfry_bin` lives in strfry-lib.sh, sourced at the top: B9 probes
# the same pinned image and the candidate list must not drift between them.

# relay_scan <outfile> — captures every kind-445 the relay holds.
#
# Hard-fails rather than `|| true`-ing: an unreadable relay makes the whole
# absence proof vacuous, and "the container would not answer" must never be
# indistinguishable from "there were no events" (the repo's documented
# recurring failure mode).
relay_scan() {
  local out="$1"
  if ! docker exec "${STRFRY_CONTAINER}" "${STRFRY_BIN}" scan \
         '{"kinds":[445]}' > "${out}" 2>"${out}.err"; then
    sed 's/^/    /' "${out}.err" >&2 || true
    fail "\`${STRFRY_BIN} scan\` failed inside the '${STRFRY_CONTAINER}'" \
         "container. The relay-side absence proof cannot run, and a lane" \
         "that cannot read the relay must not report 'no events'."
  fi
}

# absorb_into_baseline — folds the relay's CURRENT location-event ids into
# the baseline set.
#
# Union, not replace: location events expire off the relay on strfry's own
# cron, so an id present at one snapshot and gone at the next must stay in
# the baseline or it would resurface as "new" if it were ever re-observed.
absorb_into_baseline() {
  local scan="${LOG_DIR}/relay-scan.tmp"
  relay_scan "${scan}"
  {
    b5_expiring_445_ids "${scan}"
    cat "${BASELINE_IDS}" 2>/dev/null || true
  } | LC_ALL=C sort -u > "${BASELINE_IDS}.next"
  mv "${BASELINE_IDS}.next" "${BASELINE_IDS}"
}

# poll_relay_for_new — one ACT 2 poll: scan, diff against the baseline, and
# append anything new to NEW_IDS.
#
# POLLED rather than read once at the end because a location event published
# early in the window can EXPIRE before the window closes (created_at +
# 228 s), and a single closing read would miss it entirely.
# Every poll appends a line, INCLUDING the "0 new" ones. That is deliberate and
# it is what makes this lane greenable at all.
#
# The write used to sit inside the `found` branch, so the file was only ever
# written when a new location event appeared — i.e. only when the lane was about
# to FAIL. On a passing run (no new events, which is the whole point of B5) the
# file stayed 0 bytes, the mandatory secret scan in `cleanup` classified it
# UNUSABLE and returned rc=3, and the lane forced rc=1. B5 could not report PASS
# even with every oracle satisfied.
#
# Writing unconditionally also restores the invariant the scanner assumes and
# b6/b9 already honour (run-b6-location-provider-toggle.sh, run-b9-network-
# reconnect.sh both append on every iteration): an empty aux log means the
# capture never ran, not that the run went well.
#
# Takes the diff file as an argument because this lane now bounds TWO
# absence windows against the same baseline — the app-op one in ACT 1 and
# ACT 2's — and folding both into one file would let a leak in either be
# reported against the other.
poll_relay_for_new() { # poll_relay_for_new <new-ids-file>
  local out="$1"
  local scan="${LOG_DIR}/relay-scan.tmp"
  relay_scan "${scan}"
  local ids="${LOG_DIR}/relay-scan.ids"
  b5_expiring_445_ids "${scan}" > "${ids}"
  local found
  found="$(b5_new_ids "${ids}" "${BASELINE_IDS}")"
  if [[ -n "${found}" ]]; then
    printf '%s\n' "${found}" >> "${out}.raw"
    LC_ALL=C sort -u "${out}.raw" > "${out}"
  fi
  b5_record_poll "${RELAY_POLL_LOG}" "${found}"
}

# read_appops_mode <op> <dumpfile> — capture `cmd appops get` and echo the
# mode it reports for <op>. The dump is kept: it is the lane's evidence that
# the condition varied, and `fail()` has nothing else to show for it.
read_appops_mode() {
  local op="$1" dump="$2"
  adb -s "${DEVICE}" shell cmd appops get "${PKG}" "${op}" > "${dump}" 2>&1 \
    || true
  b5_appops_mode "${dump}" "${op}"
}

# wait_for_appops_mode <op> <withheld|permitted> <timeout-secs> <dumpfile> —
# poll the read-back until location is withheld / served, then echo the mode.
#
# Waits on the PROPERTY, not on a mode name: the platform rewrites the mode it
# was asked for (b5_appops_mode_withholds), so waiting for a literal `deny`
# burns the whole timeout on a denial that already took, and waiting for a
# literal `allow` does the same on a restore the sync normalised to
# `foreground`.
#
# Echoes whatever it LAST read on timeout rather than failing here, so the
# caller reports the actual mode ("foreground", or nothing at all) instead of
# a generic timeout — the difference between "the set was refused" and "this
# image words its output differently".
wait_for_appops_mode() {
  local op="$1" want="$2" timeout_s="$3" dump="$4" waited=0 mode="" state
  while (( waited < timeout_s )); do
    mode="$(read_appops_mode "${op}" "${dump}")"
    state=permitted
    if b5_appops_mode_withholds "${mode}"; then
      state=withheld
    fi
    if [[ "${state}" == "${want}" ]]; then
      break
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  printf '%s' "${mode}"
}

# wait_for_marker <marker> <timeout-secs> — 0 when the marker appears in the
# logcat capture, 1 on timeout or on the drive dying first.
#
# Watching the drive's liveness matters: a target that crashed will never
# print its next cue, and burning the full marker timeout on a corpse turns
# a clear "the drive died" into an anonymous lane-level timeout.
wait_for_marker() {
  local marker="$1" timeout_s="$2" waited=0
  while (( waited < timeout_s )); do
    if grep -aqF -- "${marker}" "${LOGCAT_FILE}" 2>/dev/null; then
      echo "  observed '${marker}' after ${waited}s"
      return 0
    fi
    if [[ -n "${DRIVE_PID}" ]] && ! kill -0 "${DRIVE_PID}" 2>/dev/null; then
      echo "  the drive exited before '${marker}' appeared (after ${waited}s)" >&2
      return 1
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  echo "  timed out after ${timeout_s}s waiting for '${marker}'" >&2
  return 1
}

# wait_for_marker_polling_relay <marker> <timeout-secs> <new-ids-file> —
# [wait_for_marker] that also runs a relay poll on every iteration.
#
# The app-op window is the one stretch of this lane where the app is alive,
# has lost location access, and is NOT being watched by a relay poll unless
# this does it: ACT 2's loop only starts later, and the per-circle scheduler
# ticks behind the drive target's explicit publish cycles where its own
# markers cannot see it.
wait_for_marker_polling_relay() {
  local marker="$1" timeout_s="$2" out="$3" waited=0
  while (( waited < timeout_s )); do
    if grep -aqF -- "${marker}" "${LOGCAT_FILE}" 2>/dev/null; then
      echo "  observed '${marker}' after ${waited}s"
      return 0
    fi
    if [[ -n "${DRIVE_PID}" ]] && ! kill -0 "${DRIVE_PID}" 2>/dev/null; then
      echo "  the drive exited before '${marker}' appeared (after ${waited}s)" \
        >&2
      return 1
    fi
    sleep "${RELAY_POLL_SECS}"
    waited=$(( waited + RELAY_POLL_SECS ))
    poll_relay_for_new "${out}"
  done
  echo "  timed out after ${timeout_s}s waiting for '${marker}'" >&2
  return 1
}

# dump_permissions <outfile> — the authoritative permission state.
dump_permissions() {
  adb -s "${DEVICE}" shell dumpsys package "${PKG}" > "$1" 2>&1 || true
}

# report_drive <label> <logfile> <rc> — echoes the drive log (after a secret
# scan) and sets DRIVE_FAILED/DRIVE_REASON for the caller.
#
# Scans BEFORE echoing: the EXIT trap's scan runs far too late to protect the
# STEP log, which has no retention control and cannot be redacted after the
# fact — a wider, more permanent sink than the artifact upload.
DRIVE_FAILED=0
DRIVE_REASON=""
report_drive() {
  local label="$1" logfile="$2" drc="$3"
  DRIVE_FAILED=0
  DRIVE_REASON=""
  local clean=1
  if bash "${SECRET_SCAN}" "${logfile}"; then
    cat "${logfile}" || true
  else
    clean=0
    echo "${label} drive log withheld from the step log — secret-leak guard" \
         "tripped." >&2
  fi
  if (( drc != 0 )); then
    DRIVE_FAILED=1
    DRIVE_REASON="flutter drive exited ${drc}"
  elif drive_log_reports_test_failure "${logfile}"; then
    DRIVE_FAILED=1
    DRIVE_REASON="flutter drive exited 0 but the on-device suite reported \
failures"
  fi
  if (( DRIVE_FAILED == 1 && clean == 1 )); then
    drive_log_failure_evidence "${logfile}" >&2
  fi
}

# ---------------------------------------------------------------------------
# Phase 0 — hermetic relay, a relay reader, and device readiness.
#
# The `strfry scan` probe happens FIRST, before anything expensive: the
# relay-side absence proof is half this lane's oracle, and discovering at
# minute 20 that the container cannot answer would waste both drives.
# ---------------------------------------------------------------------------
echo "Phase 0/7 — starting hermetic strfry..."
bash "${START_STRFRY}"
if ! detect_strfry_bin; then
  fail "no working \`strfry scan\` inside the '${STRFRY_CONTAINER}'" \
       "container (tried: strfry, /app/strfry, /usr/local/bin/strfry," \
       "/usr/bin/strfry). This lane's absence proof reads the LMDB directly" \
       "because strfry logs no EVENT/REQ lines at this config, so without it" \
       "there is no independent oracle at all."
fi
echo "  relay reader: ${STRFRY_BIN} scan"
adb -s "${DEVICE}" wait-for-device
: > "${BASELINE_IDS}"
: > "${NEW_IDS}"
: > "${NEW_IDS}.raw"
: > "${RELAY_POLL_LOG}"
echo "Phase 0/7 — device ready."

# ---------------------------------------------------------------------------
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky state
# from a prior target survives into this run.
# ---------------------------------------------------------------------------
echo "Phase 1/7 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — grant the permission this lane is about to take away, VERIFIED.
#
# `pm grant` exits 0 even when it refuses (trap 1), so `dumpsys package` is
# the gate: a silently-rejected grant would otherwise present as an
# unattributable baseline-publish timeout.
#
# ACCESS_BACKGROUND_LOCATION is deliberately NOT granted: both acts publish
# from a VISIBLE activity, and granting more than the scenario needs would
# quietly stop the lane representing real foreground users' permission state.
# ---------------------------------------------------------------------------
echo "Phase 2/7 — granting and VERIFYING runtime permissions..."
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.POST_NOTIFICATIONS
do
  adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}" 2>&1 | sed 's/^/    /' \
    || true
done

dump_permissions "${PERM_GRANTED_DUMP}"
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION
do
  if b5_permission_granted "${PERM_GRANTED_DUMP}" "${perm}"; then
    echo "  verified ${perm}: granted=true"
  else
    grep -a "${perm}" "${PERM_GRANTED_DUMP}" | sed 's/^/    /' >&2 || true
    fail "${perm} is NOT granted according to dumpsys package. \`pm grant\`" \
         "exits 0 even when it refuses, so a silent rejection here would" \
         "otherwise present as an unattributable baseline-publish timeout."
  fi
done

# ---------------------------------------------------------------------------
# Phase 3 — a GPS fix, re-issued for the life of the lane (both acts).
#
# Keeping it running through ACT 2 is deliberate (trap 4): a publish that
# survived the revoke then proves the app ignored the permission, rather than
# that its position source dried up.
#
# NOTE the argument order: `geo fix` takes LONGITUDE first, then LATITUDE.
# ---------------------------------------------------------------------------
echo "Phase 3/7 — seeding emulator GPS (lon=${GEO_LON} lat=${GEO_LAT}," \
     "alternating with lat=${GEO_LAT_B})..."
adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" \
  || fail "\`adb emu geo fix\` was rejected by the emulator console — no" \
          "position can be injected, so this lane cannot establish a" \
          "baseline and has nothing to take away."
(
  while sleep "${GEO_REISSUE_SECS}"; do
    adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT_B}" \
      >/dev/null 2>&1 || true
    sleep "${GEO_REISSUE_SECS}"
    adb -s "${DEVICE}" emu geo fix "${GEO_LON}" "${GEO_LAT}" \
      >/dev/null 2>&1 || true
  done
) &
GEO_PID=$!

# ---------------------------------------------------------------------------
# Phase 4 — ACT 1: drive with the permission held, then revoke underneath it.
#
# The drive runs in the BACKGROUND so the revoke can land MID-session. No
# `--keep-app-running`: nothing has to outlive ACT 1 (the OS is about to end
# it anyway), and letting `flutter drive` stop the app keeps this lane from
# leaving a live MLS session behind for the next job on the runner (Rule 14).
# ---------------------------------------------------------------------------
echo "Phase 4/7 — capturing logcat and driving ACT 1..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!

: > "${DRIVE1_LOG}"
(
  cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE1_TIMEOUT}" \
    flutter drive \
      --no-pub \
      --device-id "${DEVICE}" \
      --use-application-binary "${APK}" \
      --driver "${DRIVER_FILE}" \
      --target "${TARGET}"
) > "${DRIVE1_LOG}" 2>&1 &
DRIVE_PID=$!

# ---------------------------------------------------------------------------
# Phase 4a — THE APP-OP WINDOW. Location access withdrawn from a process that
# STAYS ALIVE.
#
# This is the half `pm revoke` structurally cannot reach: the revoke kills the
# app, and the stale-fix cache it would have to serve from is process-local,
# so it dies with it. `cmd appops set ... deny` removes access without the
# kill and without touching anything the app's permission gate reads, so the
# app goes on believing it has access while the platform delivers nothing.
#
# Two gates, because either alone passes vacuously:
#
#   * `cmd appops set` exits 0 whether or not it took, and there is no
#     `dumpsys package` line for an app-op — so the mode is READ BACK, and a
#     mode the platform still serves location under (b5_appops_mode_withholds
#     — `ignore` is what this `deny` normalises to, and is a real denial) is
#     fatal here rather than a finding 20 minutes later. (B7's discrimination
#     gate, in this lane's terms.)
#   * a mode that reads as withholding and changes nothing is a different
#     failure and invisible to the read-back, so the DRIVE TARGET has to report
#     that real location reads stopped working (`APPOPS_OBSERVED`).
#
# The denial is then held for at least APPOPS_MIN_DENY_SECS whatever the app
# does, so the relay-side absence spans a full scheduler interval.
# ---------------------------------------------------------------------------
: > "${APPOPS_NEW_IDS}"
: > "${APPOPS_NEW_IDS}.raw"
appops_denied_mode=""
appops_restored_mode=""

if wait_for_marker "${MARK_APPOPS_ARMED}" "${ARM_MARKER_TIMEOUT}"; then
  # Everything published while access was intact belongs to the baseline.
  absorb_into_baseline

  echo "Phase 4/7 — denying the location app-op (the process stays alive)..."
  # BOTH SCOPES, uid first. `AppOpsService` returns a non-default UID mode
  # without ever consulting the package mode, and the runtime-permission →
  # app-op sync leaves a `whileInUse` grant at UID mode `foreground`, which
  # evaluates to ALLOWED for a foregrounded app — so the package-scoped `set`
  # alone withdrew nothing (CI run 31868809387). The package scope is kept
  # alongside it for an image whose UID mode is default.
  for op in "${APPOPS_FINE}" "${APPOPS_COARSE}"; do
    adb -s "${DEVICE}" shell cmd appops set --uid "${PKG}" "${op}" deny 2>&1 \
      | sed 's/^/    /' || true
    adb -s "${DEVICE}" shell cmd appops set "${PKG}" "${op}" deny 2>&1 \
      | sed 's/^/    /' || true
  done
  appops_denied_at="$(date +%s)"

  appops_denied_mode="$(wait_for_appops_mode "${APPOPS_FINE}" withheld \
    "${APPOPS_VERIFY_TIMEOUT}" "${APPOPS_DENIED_DUMP}")"
  if ! b5_appops_mode_withholds "${appops_denied_mode}"; then
    sed 's/^/    /' "${APPOPS_DENIED_DUMP}" >&2 || true
    fail "\`cmd appops get ${PKG} ${APPOPS_FINE}\` reads an EFFECTIVE mode of" \
         "'${appops_denied_mode:-<nothing>}' after \`cmd appops set ... deny\`," \
         "and the platform still serves location under it. \`set\` exits 0 even" \
         "when it refuses and an app-op has no \`dumpsys package\` line, so this" \
         "read-back is the ONLY thing that knows the condition changed — and" \
         "every app-side assertion in this window passes trivially against an" \
         "app that never lost access. The withholding modes are 'ignore' (what" \
         "the permission↔app-op sync normalises this \`deny\` to, and the" \
         "expected reading) and 'deny'. 'foreground' means the UID-scoped mode" \
         "is still the one the permission sync left behind, i.e. the \`set" \
         "--uid\` above did not take: check whether this image's \`cmd appops" \
         "set\` accepts --uid. 'allow' or 'default' mean nothing was withdrawn" \
         "at either scope. The dump printed above shows both scopes."
  fi
  echo "  verified ${APPOPS_FINE}: ${appops_denied_mode}"

  # Close the baseline on anything that was already in flight — see
  # APPOPS_SETTLE for why this cannot swallow the leak.
  sleep "${APPOPS_SETTLE}"
  absorb_into_baseline

  if ! wait_for_marker_polling_relay "${MARK_APPOPS_DONE}" \
       "${APPOPS_WINDOW_TIMEOUT}" "${APPOPS_NEW_IDS}"; then
    echo "WARN: ACT 1 never printed '${MARK_APPOPS_DONE}'. The oracle reports" \
         "the missing app-side half; the relay-side window below still ran." >&2
  fi

  # Hold the denial for a full scheduler interval however early the app-side
  # window closed, and keep polling: the per-circle scheduler ticks behind the
  # drive target's explicit cycles, and this is the only thing watching it.
  held=$(( $(date +%s) - appops_denied_at ))
  while (( held < APPOPS_MIN_DENY_SECS )); do
    sleep "${RELAY_POLL_SECS}"
    poll_relay_for_new "${APPOPS_NEW_IDS}"
    held=$(( $(date +%s) - appops_denied_at ))
  done
  poll_relay_for_new "${APPOPS_NEW_IDS}"
  echo "  app-op held denied for ${held}s (>= ${APPOPS_MIN_DENY_SECS}s, one" \
       "full kLocationPublishMaxInterval)"

  echo "Phase 4/7 — restoring the location app-op..."
  # `allow` AT BOTH SCOPES, and the uid one must NOT go back to `default`.
  # Clearing the uid override looks like the tidier restore and is the one that
  # cannot work: `default` is not `allow` or `foreground`, so
  # `updatePermissionRevokedCompat` LEAVES FLAG_PERMISSION_REVOKED_COMPAT set on
  # the permission, and the sync immediately writes the uid mode back to
  # `ignore` — location still withheld, for the whole rest of the lane. Only a
  # uid-scoped `allow` clears that flag; the sync then normalises the mode to
  # the `foreground` a `whileInUse` grant implies, which is the no-override
  # state the platform would have chosen anyway.
  for op in "${APPOPS_FINE}" "${APPOPS_COARSE}"; do
    adb -s "${DEVICE}" shell cmd appops set --uid "${PKG}" "${op}" allow \
      2>&1 | sed 's/^/    /' || true
    adb -s "${DEVICE}" shell cmd appops set "${PKG}" "${op}" allow 2>&1 \
      | sed 's/^/    /' || true
  done
  appops_restored_mode="$(wait_for_appops_mode "${APPOPS_FINE}" permitted \
    "${APPOPS_VERIFY_TIMEOUT}" "${APPOPS_RESTORED_DUMP}")"
  if b5_appops_mode_withholds "${appops_restored_mode}"; then
    sed 's/^/    /' "${APPOPS_RESTORED_DUMP}" >&2 || true
    fail "${APPOPS_FINE} still reads '${appops_restored_mode}' after the" \
         "restore, a mode the platform withholds location under. The revoke" \
         "half below would then be measuring an app that had already lost" \
         "access for a second reason, and the runner would be left with" \
         "location withheld from ${PKG}."
  fi
  echo "  restored ${APPOPS_FINE}: ${appops_restored_mode:-<default>}"

  # Whatever the app publishes now that access is back belongs to the
  # baseline, not to either absence window.
  absorb_into_baseline
else
  echo "WARN: ACT 1 never printed '${MARK_APPOPS_ARMED}'." >&2
fi

revoke_issued=0
if wait_for_marker "${MARK_AWAIT_REVOKE}" "${ARM_MARKER_TIMEOUT}"; then
  # Snapshot what ACT 1 has already published BEFORE touching the permission.
  absorb_into_baseline

  echo "Phase 4/7 — revoking ACCESS_FINE_LOCATION and ACCESS_COARSE_LOCATION..."
  for perm in \
    android.permission.ACCESS_FINE_LOCATION \
    android.permission.ACCESS_COARSE_LOCATION
  do
    adb -s "${DEVICE}" shell pm revoke "${PKG}" "${perm}" 2>&1 \
      | sed 's/^/    /' || true
    # "Don't ask again". Without it the app's next publish tick raises the
    # SYSTEM permission dialog from `requestPermission()` (trap 3), which
    # nothing in CI dismisses. Recorded, not gated: an Android without this
    # shell command must present as a named ACT 2 finding, not as a silent
    # harness assumption.
    adb -s "${DEVICE}" shell pm set-permission-flags "${PKG}" "${perm}" \
      user-fixed 2>&1 | sed 's/^/    /' || true
  done
  revoke_issued=1

  dump_permissions "${PERM_REVOKED_DUMP}"
  for perm in \
    android.permission.ACCESS_FINE_LOCATION \
    android.permission.ACCESS_COARSE_LOCATION
  do
    if b5_permission_granted "${PERM_REVOKED_DUMP}" "${perm}"; then
      grep -a "${perm}" "${PERM_REVOKED_DUMP}" | sed 's/^/    /' >&2 || true
      fail "${perm} is STILL granted after \`pm revoke\`. \`pm revoke\` exits" \
           "0 even when it refuses, so this is the only place the refusal is" \
           "visible — the whole lane would otherwise run ACT 1 twice and" \
           "report a green that proved nothing."
    fi
    echo "  verified ${perm}: granted=false"
    if b5_permission_user_fixed "${PERM_REVOKED_DUMP}" "${perm}"; then
      echo "    USER_FIXED set (no system dialog will be raised)"
    else
      echo "    NOTE: USER_FIXED absent — \`pm set-permission-flags\` did not" \
           "take. ACT 2's one-shot probe may hit the system permission" \
           "dialog and report a TimeoutException; read that as this, not as" \
           "a product defect."
    fi
  done
else
  echo "WARN: ACT 1 never printed '${MARK_AWAIT_REVOKE}'." >&2
fi

echo "Phase 4/7 — draining the ACT 1 drive..."
drc=0
wait "${DRIVE_PID}" || drc=$?
DRIVE_PID=""
report_drive "ACT 1" "${DRIVE1_LOG}" "${drc}"

# ACT 1's drive is EXPECTED to die once the revoke lands: the OS kills the
# app process as part of the revocation, which takes the VM service
# connection with it. That is the scenario working, not a lane failure — so
# it is only fatal when the revoke was never issued, i.e. when ACT 1 failed
# before it ever reached the point this lane cares about.
act1_killed=0
if grep -aF "${KILL_REASON}" "${LOGCAT_FILE}" 2>/dev/null \
     | grep -aqF "${PKG}"; then
  act1_killed=1
  echo "  the OS terminated the app as part of the revocation:"
  grep -aF "${KILL_REASON}" "${LOGCAT_FILE}" 2>/dev/null | grep -aF "${PKG}" \
    | tail -3 | sed 's/^/    /' || true
fi
if (( revoke_issued == 0 )); then
  fail "ACT 1 never reached '${MARK_AWAIT_REVOKE}', so the permission was" \
       "never revoked mid-session and there is no scenario to assert on." \
       "${DRIVE_REASON:+ACT 1 drive verdict: ${DRIVE_REASON}.}"
fi
if (( DRIVE_FAILED == 1 && act1_killed == 0 )); then
  echo "WARN: the ACT 1 drive did not complete cleanly (${DRIVE_REASON}) and" \
       "no OS kill was recorded. The revoke WAS issued, so ACT 2 still" \
       "carries the proof; this is reported by the oracle rather than being" \
       "fatal here." >&2
fi

# ---------------------------------------------------------------------------
# Phase 5 — settle, then close the relay baseline.
#
# Everything the relay holds at this point belongs to ACT 1 and is absorbed
# into the baseline, including anything published in the moments around the
# revoke. That absorption is deliberate: a publish already IN FLIGHT when the
# permission was withdrawn is a race with the OS kill, not a product
# behaviour, and asserting on it would produce a flaky red. ACT 1's own
# MIDSESSION_* markers are what speak to the surviving-process case.
# ---------------------------------------------------------------------------
echo "Phase 5/7 — settling ${REVOKE_SETTLE}s, then closing the relay baseline..."
sleep "${REVOKE_SETTLE}"
absorb_into_baseline
baseline_ids_count="$(grep -ac . "${BASELINE_IDS}" 2>/dev/null || true)"
echo "  relay baseline: ${baseline_ids_count:-0} ACT 1 location event(s)"

# ---------------------------------------------------------------------------
# Phase 6 — reset app state, re-assert the revocation, and run ACT 2.
#
# `pm clear` is required, not cosmetic: the E2E keyring is in-memory and
# process-scoped (`useInMemoryKeyringForTest`), so ACT 2's fresh process
# mints a NEW SQLCipher passphrase and physically cannot open ACT 1's MLS
# database. Clearing also resets runtime permissions to their default, so the
# revoke is re-applied and RE-VERIFIED afterwards — otherwise ACT 2 would run
# with the permission in whatever state `pm clear` chose.
# ---------------------------------------------------------------------------
echo "Phase 6/7 — clearing app state and re-asserting the revocation..."

# ACT 1's `flutter drive` UNINSTALLED the package on its way out, so there is
# nothing here to clear until it is put back.
#
# This is not obvious and it cost two CI runs. ACT 1 deliberately omits
# `--keep-app-running` (Rule 14: do not leave a live MLS session behind for the
# next job on this runner) — but `flutter drive`'s teardown does not merely stop
# the app. `DriveCommand` calls `driverService.stop()` unconditionally, including
# when the suite failed, and that runs `stopApp(...)` AND THEN
# `uninstallApp(...)` (flutter_tools/lib/src/drive/drive_service.dart). By the
# time this phase runs, `${PKG}` is gone from the device entirely.
#
# `pm clear` on an absent package takes AOSP's invalid-package fast path and
# prints `Failed` — which is exactly what CI runs 30925179141 and 30964250098
# showed, both returning in tens of milliseconds, far too fast for a real
# force-stop plus data wipe. It also silently made the `pm revoke` and
# `pm set-permission-flags` calls below no-ops against a package that did not
# exist, which is why ACT 2 met the system permission dialog instead of a
# USER_FIXED denial.
#
# `install -r` puts the package back. Being precise about what that buys, because
# the obvious reading is wrong: the uninstall already deleted the data directory,
# so there is no ACT 1 state left to preserve and the `pm clear` below is a
# no-op in the ordinary case — a fresh install has an empty data dir and default
# (ungranted, unflagged) permissions, which is the state this phase wanted
# anyway. The load-bearing calls are the `pm revoke` + `pm set-permission-flags
# user-fixed` pair further down, which need a package that EXISTS to act on;
# without this reinstall they were writing into the void, which is why ACT 2 met
# the system permission dialog instead of a USER_FIXED denial.
#
# `pm clear` and its Success gate are kept rather than dropped because they still
# matter on the one path where the teardown did NOT run: the `timeout
# --kill-after` above can kill the ACT 1 drive before `flutter drive` reaches
# its stop/uninstall, leaving the package installed WITH ACT 1's data. That is
# the case the gate's failure text describes, and it is the case that must not
# proceed silently.
echo "  restoring the package ACT 1's drive teardown uninstalled..."
if ! adb -s "${DEVICE}" install -r "${APK}" 2>&1 | sed 's/^/    /'; then
  fail "could not reinstall ${APK} before \`pm clear\`. ACT 1's drive teardown" \
       "uninstalls the package (flutter_tools drive_service.dart: stopApp then" \
       "uninstallApp), so this reinstall is what gives Phase 6 something to" \
       "clear; without it every step below operates on a package that is not" \
       "on the device."
fi
if ! adb -s "${DEVICE}" shell pm list packages "${PKG}" 2>/dev/null \
     | tr -d '\r' | grep -qF "package:${PKG}"; then
  fail "${PKG} is still not installed after \`install -r\`, so \`pm clear\`," \
       "\`pm revoke\` and \`pm set-permission-flags\` would all be no-ops and" \
       "ACT 2 would run with permissions in whatever state a fresh install" \
       "chose."
fi

# `pm clear` REPORTS in its output, not in its exit status: it prints "Failed"
# and still exits 0, so `|| true` on the exit code checked nothing. Run
# 30925179141 printed exactly that "Failed" and the lane carried on into ACT 2
# regardless — which, by this phase's own comment above, means ACT 2 ran
# against ACT 1's data directory with a fresh in-memory keyring, i.e. in the
# one state this phase exists to prevent.
CLEAR_OUT="$(adb -s "${DEVICE}" shell pm clear "${PKG}" 2>&1 | tr -d '\r' || true)"
printf '%s\n' "${CLEAR_OUT}" | sed 's/^/    /'
if ! grep -qF 'Success' <<<"${CLEAR_OUT}"; then
  fail "\`pm clear ${PKG}\` did not report Success (it exits 0 either way, so" \
       "its OUTPUT is the only signal). ACT 2 would then start on ACT 1's data" \
       "directory while its in-memory keyring mints a NEW SQLCipher" \
       "passphrase, so the MLS database cannot be opened and every publish" \
       "path it exercises fails or hangs for a reason that has nothing to do" \
       "with the revoked permission."
fi

for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION
do
  adb -s "${DEVICE}" shell pm revoke "${PKG}" "${perm}" >/dev/null 2>&1 || true
  adb -s "${DEVICE}" shell pm set-permission-flags "${PKG}" "${perm}" \
    user-fixed >/dev/null 2>&1 || true
done
# POST_NOTIFICATIONS is re-granted: it is not the subject, and a missing
# notification permission would change ACT 2's startup for an unrelated
# reason.
adb -s "${DEVICE}" shell pm grant "${PKG}" \
  android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

dump_permissions "${PERM_REVOKED_DUMP}"
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION
do
  if b5_permission_granted "${PERM_REVOKED_DUMP}" "${perm}"; then
    fail "${perm} is granted again after \`pm clear\` + re-revoke. ACT 2" \
         "would run WITH the permission and prove the opposite of what this" \
         "lane claims."
  fi
  # The SAME read-back Phase 4 performs, in the phase that actually governs
  # ACT 2. `pm clear` resets runtime permission FLAGS along with the grants,
  # so USER_FIXED has to be re-established here and re-read here; without this
  # the only place the lane ever confirmed it was a phase whose state ACT 2
  # does not inherit, and an ACT 2 that then stalls on the system dialog is
  # unattributable — which is precisely how it presented.
  if b5_permission_user_fixed "${PERM_REVOKED_DUMP}" "${perm}"; then
    echo "    USER_FIXED set for ACT 2 (no system dialog will be raised)"
  else
    echo "    NOTE: USER_FIXED absent for ACT 2 — \`pm set-permission-flags\`" \
         "did not take. ACT 2's probe and its publish cycles may hit the" \
         "system permission dialog and report TimeoutException /" \
         "'${MARK_ACT2_WEDGED}'; read those as this, not as a product defect."
  fi
done
echo "  both location permissions verified revoked for ACT 2."

echo "Phase 6/7 — driving ACT 2 (permission revoked) and watching the relay..."
: > "${DRIVE2_LOG}"
(
  cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE2_TIMEOUT}" \
    flutter drive \
      --no-pub \
      --device-id "${DEVICE}" \
      --use-application-binary "${APK}" \
      --driver "${DRIVER_FILE}" \
      --target "${TARGET}"
) > "${DRIVE2_LOG}" 2>&1 &
DRIVE_PID=$!

# The bounded ABSENCE window. Polled for the life of ACT 2 rather than read
# once at the end, because a location event published early can expire off
# the relay (created_at + 228 s) before the window closes.
while kill -0 "${DRIVE_PID}" 2>/dev/null; do
  sleep "${RELAY_POLL_SECS}"
  poll_relay_for_new "${NEW_IDS}"
done

drc=0
wait "${DRIVE_PID}" || drc=$?
DRIVE_PID=""
# One final read, after the drive is gone, so the tail of the window is
# covered too.
poll_relay_for_new "${NEW_IDS}"
report_drive "ACT 2" "${DRIVE2_LOG}" "${drc}"
act2_drive_failed="${DRIVE_FAILED}"
act2_drive_reason="${DRIVE_REASON}"

dump_permissions "${PERM_ACT2_DUMP}"
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION
do
  if b5_permission_granted "${PERM_ACT2_DUMP}" "${perm}"; then
    fail "${perm} was granted again by the END of ACT 2. Something re-granted" \
         "it mid-window (a reinstall by \`flutter drive\`, or the app itself)," \
         "so the absence of location events cannot be attributed to the" \
         "revocation."
  fi
done

# ---------------------------------------------------------------------------
# Phase 7 — the oracle. Reads over complete captures; no live polling.
# ---------------------------------------------------------------------------
echo "Phase 7/7 — asserting the revocation sequence..."
oracle_rc=0
b5_run_oracle "${LOGCAT_FILE}" "${BASELINE_IDS}" "${NEW_IDS}" \
  "${act1_killed}" "${APPOPS_NEW_IDS}" "${appops_denied_mode}" \
  "${appops_restored_mode}" || oracle_rc=$?

if (( oracle_rc != 0 )); then
  if [[ -s "${RELAY_POLL_LOG}" ]]; then
    echo "---- relay poll log ----" >&2
    cat "${RELAY_POLL_LOG}" >&2 || true
  fi
  {
    echo "B5 findings (${#B5_FINDINGS[@]}):"
    for finding in "${B5_FINDINGS[@]}"; do
      echo "  * ${finding}"
    done
  } >&2
  fail "the permission-revocation sequence did not hold — see the" \
       "${#B5_FINDINGS[@]} finding(s) above."
fi

if (( act2_drive_failed == 1 )); then
  fail "the oracle passed, but the ACT 2 drive did not complete cleanly" \
       "(${act2_drive_reason}). Treat the lane as RED — a drive that dies" \
       "early truncates the very window the absence proof measures, and an" \
       "app that is not running trivially publishes nothing."
fi

echo "B5 PASS — the app published with ACCESS_FINE_LOCATION granted; produced" \
     "and published NOTHING once the location app-op was denied under a live" \
     "process (verified denied and verified restored); and published nothing" \
     "at all across the relaunch its revocation forced, with the production" \
     "denied/deniedForever branch refusing every location read and the relay" \
     "seeing no location event for either window."
