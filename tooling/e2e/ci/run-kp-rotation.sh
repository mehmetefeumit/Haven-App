#!/usr/bin/env bash
#
# KPR lane orchestrator — "does a ROTATED KeyPackage still work for somebody
# else?", proven on the wire against a hermetic relay.
#
# # What this lane proves that nothing else does
#
# `decide_kp_maintenance` re-mints a KeyPackage once it passes 0.75 of its own
# MLS `Lifetime`. The host suite covers that thoroughly — 21 unit tests on the
# lifetime reader, `haven-core/tests/kp_rotation_e2e.rs`, and FFI tests in
# `haven/rust_builder/src/api.rs` — but every one of them observes the rotation
# from the PUBLISHER's side: what the decision returned, and what the publisher
# published.
#
# The property a user actually depends on is the other half. RFC 9420 makes the
# INVITER validate `not_before`/`not_after` at Add time, so a rotation that
# publishes successfully while producing material an inviter rejects would pass
# every existing test and still leave the account uninvitable. This lane
# therefore asserts, off a real relay:
#
#   * a SECOND party fetches the rotated package through the production
#     discovery cascade, adds its owner to a circle, and
#   * the added party DECRYPTS a message in the resulting group — because a
#     Welcome that is accepted but yields an unusable group is exactly the
#     failure a "did the Add succeed" check would miss.
#
# # How a 63-day threshold is made testable in minutes
#
# By moving the device wall clock BACKWARDS by 70 days before the first mint,
# then restoring true time. Every part of the production path then runs for
# real: the mint, the `Lifetime` OpenMLS stamps on it, the lifetime reader, the
# 0.75 arithmetic, `now`, the publish, and the relay.
#
# The alternatives were each ruled out against the tree:
#
#   * A FORWARD clock jump cannot work. `tooling/e2e/strfry.conf` sets
#     `rejectEventsNewerThanSeconds = 900` — the B8 lane leans on that as its
#     own oracle — so a device 70 days ahead cannot publish anything at all.
#   * A short-lifetime package cannot be minted. The 84-day span is fixed three
#     layers below Haven: `cgka-engine` builds through
#     `MlsKeyPackage::builder()` and never calls `.key_package_lifetime(...)`,
#     so OpenMLS's `Lifetime::default()` applies, and the engine additionally
#     REJECTS a package whose range exceeds that same maximum. Hand-building a
#     package would take the material Bob validates OUT of the real mint path,
#     which is the one thing this lane must not do.
#   * A test-only rotation-threshold override was rejected on this repo's own
#     precedent (`scripts/ci/check_no_exporter_label_override.sh`).
#
# The mechanism CANNOT make the lane pass without the production code rotating.
# The pre-fix `decide_kp_maintenance` had no time awareness at all: with every
# responder already serving the slot it returned `NoOp`, so the tick reports
# `alreadyHealthy`, no new event reaches the relay, and the peer's re-fetch
# returns the byte-identical package it already had. The lane requires BOTH a
# `rotatedExpiringMaterial` verdict (read from the decision) AND a superseding
# event with different material in the same `d` (read from the relay), which
# are independent observations of the same claim.
#
# # The oracle is deliberately doubled
#
# The comparisons live in the drive target, because that is the only place the
# fetched packages exist. But `flutter drive` CAN EXIT 0 ON A FAILED SUITE, and
# also exits 0 when NOTHING ran (drive-log-lib.sh, run 30753193231). So the
# shell independently requires each `[kpr]` checkpoint, PARSES the counts
# rather than grepping for them (`healed=0` contains the marker), and reads its
# own servo record to confirm the clock actually moved — `date` on Android
# exits 0 in several situations where it changed nothing, the same lesson
# `pm grant` taught this repo.
#
# # Two relays, and why
#
# R2 exists only for the final phase. Adding a relay that does not yet serve
# the account's slot is, to `decide_kp_maintenance`, indistinguishable from a
# relay that dropped the event: either way a responder does not serve the slot,
# so the tick republishes the CACHED bytes under a fresh `created_at`. Reading
# both copies back is direct wire evidence that a heal moves the EVENT
# timestamp and leaves the material — and therefore `not_before`, and therefore
# the rotation clock — exactly where it was. The host suite proves that
# in-process; proving it across a real relay is stronger.
#
# Usage:
#   run-kp-rotation.sh [<apk> [<target.dart>]]
#   run-kp-rotation.sh --self-test      # hermetic; no device, no relay
#
# Required env (set by the calling job):
#   HAVEN_LIVE_SYNC   'true' | 'false'. Read here only to fail closed if the
#                     job forgot it; the value is baked into the APK by
#                     build-kp-rotation-apk.sh.
#
# Optional env:
#   KPR_DRIVE_TIMEOUT      per-drive bound. Default 24m.
#   KPR_BACKDATE_SECS      how far back the clock goes. Default 6048000 (70d).
#   KPR_SERVO_POLL_SECS    servo logcat re-read period. Default 1.

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "${SCRIPT_DIR}/drive-log-lib.sh"

# ---------------------------------------------------------------------------
# VERBATIM markers. MUST match the `k*Marker` constants in
# haven/integration_test/kp_rotation_wire_test.dart — change both together or
# the lane silently stops finding its own evidence.
#
# Fixed literals matched with `grep -aF`: logcat is binary-tainted and these
# strings contain regex metacharacters.
#
# Every negative twin is a DISTINCT string rather than a prefix or suffix of
# its positive, so a substring match can never read one as the other
# (`[kpr] ROTATED` is not a substring of `[kpr] ROTATION_DECLINED`, and
# `[kpr] HEALED` is not a substring of `[kpr] HEAL_MATERIAL_ROTATED`).
# ---------------------------------------------------------------------------
readonly MARK_REQ_CLOCK='[kpr] REQ_CLOCK'
readonly MARK_BASELINE_MINTED='[kpr] BASELINE_MINTED'
readonly MARK_BASELINE_MINT_FAILED='[kpr] BASELINE_MINT_FAILED'
readonly MARK_CLOCK_RESTORED='[kpr] CLOCK_RESTORED'
readonly MARK_CLOCK_RESTORE_TIMEOUT='[kpr] CLOCK_RESTORE_TIMEOUT'
readonly MARK_BASELINE_FETCHED='[kpr] BASELINE_FETCHED'
readonly MARK_BASELINE_UNFETCHABLE='[kpr] BASELINE_UNFETCHABLE'
readonly MARK_ROTATED='[kpr] ROTATED'
readonly MARK_ROTATION_DECLINED='[kpr] ROTATION_DECLINED'
readonly MARK_SUPERSEDED='[kpr] SUPERSEDED'
readonly MARK_SUPERSEDE_FAILED='[kpr] SUPERSEDE_FAILED'
readonly MARK_WELCOME_ACCEPTED='[kpr] WELCOME_ACCEPTED'
readonly MARK_WELCOME_FAILED='[kpr] WELCOME_FAILED'
readonly MARK_PEER_DECRYPT_MATCH='[kpr] PEER_DECRYPT_MATCH'
readonly MARK_PEER_DECRYPT_DEAD='[kpr] PEER_DECRYPT_DEAD'
readonly MARK_HEAL_TARGET_ADDED='[kpr] HEAL_TARGET_ADDED'
readonly MARK_HEALED='[kpr] HEALED'
readonly MARK_HEAL_DECLINED='[kpr] HEAL_DECLINED'
readonly MARK_HEAL_MATERIAL_STABLE='[kpr] HEAL_MATERIAL_STABLE'
readonly MARK_HEAL_MATERIAL_ROTATED='[kpr] HEAL_MATERIAL_ROTATED'
readonly MARK_COMPLETE='[kpr] SEQUENCE_COMPLETE'

# The one action name that means "the 0.75 threshold fired on readable
# material". `rotatedUnreadableLifetime` is a DIFFERENT branch (the lifetime
# could not be parsed) and must not satisfy this lane.
readonly EXPECTED_ROTATE_ACTION='rotatedExpiringMaterial'
# The heal branch: cached bytes republished into the tracked slot.
readonly EXPECTED_HEAL_ACTION='republishedStableD'

# ---------------------------------------------------------------------------
# Protocol arithmetic, mirrored from outside bash. Pinned by --self-test so a
# future edit of KPR_BACKDATE_SECS cannot silently move the lane off the
# property it claims to test.
# ---------------------------------------------------------------------------

# `Lifetime::default()`: 84 days + a 1-hour `not_before` margin
# (openmls-0.8.1/src/key_packages/lifetime.rs). Also the maximum cgka-engine
# accepts on receive, so a package cannot be longer-lived than this.
readonly MLS_KP_LIFETIME_SPAN_SECS=7261200
# `KP_ROTATE_AT_LIFETIME_FRACTION = 0.75`
# (haven-core/src/relay/maintenance/kp_lifetime.rs), as integer arithmetic.
readonly MLS_KP_ROTATE_AT_SECS=5445900
# `not_after - not_before_margin`: the instant the package stops validating.
readonly MLS_KP_EXPIRES_AFTER_SECS=7257600

# How far back the clock goes before the first mint. 70 days sits ~7 days past
# the rotation point and ~14 days short of expiry, so neither boundary is
# anywhere near the emulator's own clock error.
readonly BACKDATE_SECS="${KPR_BACKDATE_SECS:-6048000}"

# Read-back tolerance for a clock write, in seconds. Wide enough to absorb the
# adb round trips, far narrower than any jump this lane makes.
readonly JUMP_DRIFT_TOLERANCE_SECS=60

# The servo record seq the PRE-DRIVE backdate is written under. The drive's own
# requests start at 1, so 0 can never collide with one.
readonly BACKDATE_SEQ=0

# ---------------------------------------------------------------------------
# Oracle predicates — pure text, no device. Everything the lane's verdict rests
# on lives here so `--self-test` can exercise it hermetically.
# ---------------------------------------------------------------------------

# kpr_has_marker <logfile> <marker> — 0 (true) when the marker appears.
#
# Substring match, not anchored: the same line reaches us either as raw
# `debugPrint` output in the drive log or wrapped by logcat's
# `I/flutter ( 1234): ` prefix, and both must count.
kpr_has_marker() {
  local logfile="${1:-}" marker="${2:-}"
  [[ -f "${logfile}" ]] || return 1
  grep -aqF -- "${marker}" "${logfile}"
}

# kpr_marker_number <logfile> <marker> <key> — echoes the LARGEST integer
# following `<key>=` on any line carrying <marker>, or nothing.
#
# PARSED, never grepped for presence. `healed=0` and `elapsedPct=3` both
# CONTAIN their marker, and both are failures; a presence check would call
# either a pass. Largest rather than first because a checkpoint may legitimately
# be re-emitted and a later, higher value is still the honest one.
kpr_marker_number() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[0-9]+" \
      | grep -aoE '[0-9]+' | sort -n | tail -1; } || true
}

# kpr_marker_flag <logfile> <marker> <key> — echoes the LAST `<key>=<word>`
# value on any line carrying <marker>, or nothing.
#
# Used where the VALUE is the verdict (`action=`, `dSame=`) and the marker's
# presence means only that the drive reached that point.
kpr_marker_flag() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[A-Za-z0-9_.-]+" \
      | sed "s/^${key}=//" | tail -1 | tr -d '\r'; } || true
}

# kpr_req_clock_seqs <logfile> — the seq of every `REQ_CLOCK`, deduplicated.
#
# Deduplicated because the drive deliberately RE-EMITS its request while
# waiting (a single line lost to a truncated logcat read would otherwise wedge
# the lane), and logcat can repeat a line on its own. A repeated request is not
# a second request; counting it as one would make the servo check below demand
# a record that was never supposed to exist.
kpr_req_clock_seqs() {
  local logfile="${1:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aoE '\[kpr\] REQ_CLOCK [0-9]+ -?[0-9]+' "${logfile}" 2>/dev/null \
      | awk '{ print $3 }' | awk '!seen[$0]++'; } || true
}

# kpr_jump_ok_seqs <servo-log> — the seqs the servo recorded as APPLIED.
#
# The servo log is written by THIS script, one line per attempt:
#   seq=<n> offset=<o> expected=<e> device=<d> drift=<x> status=<ok|drift|error>
# `status=ok` is produced only by an in-tolerance adb READ-BACK, so this reads
# what happened on the device rather than trusting a command that exited 0.
kpr_jump_ok_seqs() {
  local jumpfile="${1:-}"
  [[ -f "${jumpfile}" ]] || return 0
  { grep -aoE 'seq=[0-9]+ .*status=ok' "${jumpfile}" 2>/dev/null \
      | awk '{ print $1 }' | sed 's/^seq=//' | awk '!seen[$0]++'; } || true
}

# kpr_jump_record <servo-log> <seq> — the full servo record for one seq.
kpr_jump_record() {
  local jumpfile="${1:-}" seq="${2:-}"
  [[ -f "${jumpfile}" ]] || return 0
  { grep -aE "^seq=${seq} " "${jumpfile}" 2>/dev/null | tail -1; } || true
}

# The `settings put` commands that UNDO the phase-2 clock pin, one per line.
#
# A list rather than two inline `adb` calls so --self-test can assert that
# every global this script pins to 0 has a matching restore to 1, and that the
# EXIT trap actually issues them. The pin is the one mutation this lane makes
# that a clock restore does NOT cover, and every Android lane in this repo
# shares one AVD cache key.
auto_time_restore_cmds() {
  printf '%s\n' \
    'settings put global auto_time 1' \
    'settings put global auto_time_zone 1'
}

# ---------------------------------------------------------------------------
# The oracle itself, as a testable function over a capture file and a servo
# record.
#
# Findings ACCUMULATE rather than exiting on the first one: the lane's value is
# the whole picture (did anything get published, did the clock really move, did
# a peer see a supersession, did the group work), and stopping early would hide
# the rest. Returns 1 when any finding was recorded. NOTES (never failures) go
# to stdout as evidence.
# ---------------------------------------------------------------------------
KPR_FINDINGS=()

kpr_note() { printf '  NOTE: %s\n' "$*"; }
kpr_finding() { KPR_FINDINGS+=("$*"); }

kpr_run_oracle() {
  local log="${1:-}" servo="${2:-}"
  KPR_FINDINGS=()

  if [[ ! -f "${log}" ]]; then
    kpr_finding "no capture file at '${log}' — the lane recorded nothing."
    return 1
  fi

  # (1) The drive reached the end of its own sequence. Checked FIRST because
  #     every later "checkpoint absent" finding would otherwise be reported as
  #     a product defect when the true cause is a drive that died early.
  if ! kpr_has_marker "${log}" "${MARK_COMPLETE}"; then
    kpr_finding "the drive never printed '${MARK_COMPLETE}' — it did not \
reach the end of its sequence, so every absent checkpoint below may be a \
consequence of that rather than a product defect. Rule the drive out first."
  fi

  # (2) THE ANTI-VACUITY ROOT. If the pre-drive backdate never landed on the
  #     device, Alice's package is seconds old, no rotation is due, and every
  #     oracle below is about a transition that never happened. Read from the
  #     servo's own adb read-back, not from the exit code of `date`.
  local ok_seqs
  ok_seqs=" $(kpr_jump_ok_seqs "${servo}" | tr '\n' ' ')"
  if [[ "${ok_seqs}" != *" ${BACKDATE_SEQ} "* ]]; then
    kpr_finding "the PRE-DRIVE backdate (servo seq ${BACKDATE_SEQ}) was never \
recorded as applied: '$(kpr_jump_record "${servo}" "${BACKDATE_SEQ}")'. \
\`date\` on Android exits 0 when it changed nothing (no root, a re-enabled \
auto_time, a read-only clock), so without an in-tolerance read-back this run \
minted a BRAND-NEW KeyPackage and then asked whether it needed rotating. That \
is vacuous, not green."
  fi

  # (3) Every clock change the DRIVE asked for was fulfilled. Separate from
  #     (4) on purpose: a servo that set a clock nothing under test could see,
  #     and a drive that never asked, are different failures with different
  #     fixes.
  local seq
  while IFS= read -r seq; do
    [[ -n "${seq}" ]] || continue
    if [[ "${ok_seqs}" != *" ${seq} "* ]]; then
      kpr_finding "the drive requested clock change seq=${seq} and the servo \
did not record it as applied: '$(kpr_jump_record "${servo}" "${seq}")'."
    fi
  done < <(kpr_req_clock_seqs "${log}")

  # (4) The app-visible clock really moved. The drive measures the
  #     discontinuity itself against a monotonic stopwatch.
  if kpr_has_marker "${log}" "${MARK_CLOCK_RESTORE_TIMEOUT}"; then
    kpr_finding "the wall clock the APP reads never jumped forward \
('${MARK_CLOCK_RESTORE_TIMEOUT}'). HARNESS failure: the servo did not fulfil \
the request inside the drive's window, so the package under test is still \
seconds old."
  elif ! kpr_has_marker "${log}" "${MARK_CLOCK_RESTORED}"; then
    kpr_finding "no '${MARK_CLOCK_RESTORED}' line — the drive never confirmed \
that the wall clock returned to true time."
  else
    kpr_note "clock restored: the app observed a \
$(kpr_marker_number "${log}" "${MARK_CLOCK_RESTORED}" 'jumpedSecs')s \
discontinuity."
  fi

  # (5) Something was published to supersede.
  if kpr_has_marker "${log}" "${MARK_BASELINE_MINT_FAILED}"; then
    kpr_finding "Alice's FIRST KeyPackage never reached the relay \
('${MARK_BASELINE_MINT_FAILED}'). There is nothing for a rotation to \
supersede, so every verdict below is VACUOUS — fix the harness before reading \
anything into it."
  else
    local minted
    minted="$(kpr_marker_number "${log}" "${MARK_BASELINE_MINTED}" 'onRelay')"
    if [[ -z "${minted}" ]]; then
      kpr_finding "no '${MARK_BASELINE_MINTED} onRelay=<N>' line — the drive \
never established that a baseline KeyPackage existed on the relay."
    elif (( minted < 1 )); then
      kpr_finding "the relay served ${minted} baseline KeyPackage(s) for \
Alice. Nothing was published, so the rotation below has nothing to replace."
    fi
  fi

  # (6) THE SECOND ANTI-VACUITY GATE, and the one that makes this a TRANSITION
  #     rather than a fresh account: a peer fetched the PRE-rotation package,
  #     and that material really was past the 0.75 point but not yet expired.
  if kpr_has_marker "${log}" "${MARK_BASELINE_UNFETCHABLE}"; then
    kpr_finding "the peer could not fetch Alice's PRE-rotation KeyPackage \
('${MARK_BASELINE_UNFETCHABLE}'). Without a baseline the lane cannot claim to \
have watched a transition."
  else
    local pct
    pct="$(kpr_marker_number "${log}" "${MARK_BASELINE_FETCHED}" 'elapsedPct')"
    if [[ -z "${pct}" ]]; then
      kpr_finding "no '${MARK_BASELINE_FETCHED} elapsedPct=<N>' line — the \
peer never read the pre-rotation package off the relay, so there is no \
baseline to measure the rotation against."
    elif (( pct <= 75 )); then
      kpr_finding "the baseline material was only ${pct}% through its MLS \
Lifetime — BELOW the 75% rotation point. A rotation observed here would be \
some other branch firing, not the threshold. Either KPR_BACKDATE_SECS is too \
small or the upstream default Lifetime changed."
    elif (( pct >= 100 )); then
      kpr_finding "the baseline material was ${pct}% through its MLS Lifetime, \
i.e. EXPIRED. The tick then re-mints because the lifetime reads as \
not-current, which is a DIFFERENT code path from the 0.75 threshold this lane \
exists to prove. Reduce KPR_BACKDATE_SECS."
    else
      kpr_note "baseline: a peer fetched material ${pct}% through its own MLS \
Lifetime — past the 75% rotation point, still inside its validity window."
    fi
  fi

  # (7) THE DECISION. Read from the production tick's own verdict.
  if kpr_has_marker "${log}" "${MARK_ROTATION_DECLINED}"; then
    kpr_finding "the production maintenance tick DECLINED to rotate \
(action=$(kpr_marker_flag "${log}" "${MARK_ROTATION_DECLINED}" 'action')) on \
material past 75% of its own Lifetime. \`alreadyHealthy\` here is the pre-fix \
behaviour exactly: every responder serves the slot, so a decision with no \
time awareness reports nothing to do while the account silently ages out of \
being invitable."
  elif ! kpr_has_marker "${log}" "${MARK_ROTATED}"; then
    kpr_finding "neither '${MARK_ROTATED}' nor '${MARK_ROTATION_DECLINED}' was \
recorded — the drive never reached the rotation decision."
  else
    local action healed
    action="$(kpr_marker_flag "${log}" "${MARK_ROTATED}" 'action')"
    healed="$(kpr_marker_number "${log}" "${MARK_ROTATED}" 'healed')"
    if [[ "${action}" != "${EXPECTED_ROTATE_ACTION}" ]]; then
      kpr_finding "the tick rotated for the WRONG reason \
(action=${action:-<absent>}, expected ${EXPECTED_ROTATE_ACTION}). \
\`rotatedUnreadableLifetime\` means the package's Lifetime could not be \
parsed at all, which is a fallback branch — it proves the reader broke, not \
that the 0.75 threshold works."
    fi
    if [[ -z "${healed}" ]]; then
      kpr_finding "no 'healed=<N>' on the '${MARK_ROTATED}' line — there is no \
evidence any relay accepted the rotated package."
    elif (( healed < 1 )); then
      kpr_finding "the tick rotated and ${healed} relay(s) acked the publish. \
The action names the branch that RAN and is chosen BEFORE the write is \
attempted, so a Rotated* action with zero heals is a rotation nobody \
received — the account is now holding material no peer can fetch."
    fi
  fi

  # (8) SUPERSESSION, from a FETCHER's point of view. Independent of (7): that
  #     reads the decision, this reads the relay.
  if kpr_has_marker "${log}" "${MARK_SUPERSEDE_FAILED}"; then
    local reason
    reason="$(kpr_marker_flag "${log}" "${MARK_SUPERSEDE_FAILED}" 'reason')"
    case "${reason}" in
      slot_changed)
        kpr_finding "the rotated package landed in a DIFFERENT addressable \
slot (${MARK_SUPERSEDE_FAILED} reason=${reason}). The transport binding makes \
reuse of the stable \`d\` a MUST: a new slot leaves the old, expiring package \
addressable and live ALONGSIDE the new one instead of replacing it."
        ;;
      material_reused)
        kpr_finding "the 'rotated' event carries byte-identical KeyPackage \
material (${MARK_SUPERSEDE_FAILED} reason=${reason}). That is a HEAL — cached \
bytes republished under a new event id — not a re-mint, so the expiring \
Lifetime is unchanged and the account still ages out."
        ;;
      *)
        kpr_finding "a peer never saw the rotation supersede the old package \
(${MARK_SUPERSEDE_FAILED} reason=${reason:-<absent>}). Whatever the tick \
reported, from a peer's point of view nothing changed."
        ;;
    esac
  elif ! kpr_has_marker "${log}" "${MARK_SUPERSEDED}"; then
    kpr_finding "neither '${MARK_SUPERSEDED}' nor '${MARK_SUPERSEDE_FAILED}' \
was recorded — the drive never re-read the relay after the rotation."
  else
    local d_same material_changed id_changed
    d_same="$(kpr_marker_flag "${log}" "${MARK_SUPERSEDED}" 'dSame')"
    material_changed="$(kpr_marker_flag "${log}" "${MARK_SUPERSEDED}" \
      'materialChanged')"
    id_changed="$(kpr_marker_flag "${log}" "${MARK_SUPERSEDED}" 'idChanged')"
    if [[ "${d_same}" != "true" || "${material_changed}" != "true" \
          || "${id_changed}" != "true" ]]; then
      kpr_finding "the supersession reading is incomplete \
(dSame=${d_same:-<absent>}, materialChanged=${material_changed:-<absent>}, \
idChanged=${id_changed:-<absent>}). All three must hold: same slot, new event, \
new material."
    else
      kpr_note "supersession: new material in the same \`d\`, \
$(kpr_marker_number "${log}" "${MARK_SUPERSEDED}" 'dCreatedAt')s newer than \
the package it replaced."
    fi
  fi

  # (9) THE HEADLINE, part 1 — the Add. This is the RFC 9420 validation point.
  if kpr_has_marker "${log}" "${MARK_WELCOME_FAILED}"; then
    kpr_finding "a peer could not build a working circle from the ROTATED \
KeyPackage ('${MARK_WELCOME_FAILED}'). This is the defect the whole lane \
exists to catch: the rotation published successfully and produced material an \
inviter rejects at Add time, or a Welcome the rotated identity cannot apply."
  elif ! kpr_has_marker "${log}" "${MARK_WELCOME_ACCEPTED}"; then
    kpr_finding "no '${MARK_WELCOME_ACCEPTED}' line — the drive never \
confirmed that the rotated package produced a joinable group."
  fi

  # (10) THE HEADLINE, part 2 — the group actually WORKS. An accepted Welcome
  #      that yields an unusable group is exactly what a "did the Add succeed"
  #      check would miss, so this is a separate gate rather than a detail of
  #      the one above.
  if kpr_has_marker "${log}" "${MARK_PEER_DECRYPT_DEAD}"; then
    kpr_finding "the rotated identity joined the circle and then decrypted \
NOTHING ('${MARK_PEER_DECRYPT_DEAD}'). The Welcome was accepted, so an \
Add-succeeded check would have passed — and the group is unusable."
  elif ! kpr_has_marker "${log}" "${MARK_PEER_DECRYPT_MATCH}"; then
    kpr_finding "neither '${MARK_PEER_DECRYPT_MATCH}' nor \
'${MARK_PEER_DECRYPT_DEAD}' was recorded — the drive never reached the \
message-decrypt proof, which is this lane's deliverable."
  fi

  # (11) THE HEAL. A relay that does not serve the slot must be re-served with
  #      the SAME material under a NEWER `created_at` — the pair that shows the
  #      rotation clock lives in the package, not in the event timestamp.
  if kpr_has_marker "${log}" "${MARK_HEAL_MATERIAL_ROTATED}"; then
    kpr_finding "the heal published DIFFERENT material \
('${MARK_HEAL_MATERIAL_ROTATED}'). A heal must republish the cached bytes; \
re-minting on an under-served relay would restart the Lifetime on every relay \
hiccup, which is precisely the reset this phase exists to rule out."
  elif kpr_has_marker "${log}" "${MARK_HEAL_DECLINED}"; then
    kpr_finding "the tick did not heal the under-served relay \
(action=$(kpr_marker_flag "${log}" "${MARK_HEAL_DECLINED}" 'action')). The \
freshly rotated material is nowhere near its rotation point, so the heal \
branch is the only correct answer."
  elif ! kpr_has_marker "${log}" "${MARK_HEAL_TARGET_ADDED}"; then
    kpr_finding "no '${MARK_HEAL_TARGET_ADDED}' line — the second relay was \
never added, so the heal phase never armed."
  else
    local healed_n heal_material heal_advanced heal_slot
    healed_n="$(kpr_marker_number "${log}" "${MARK_HEALED}" 'healed')"
    heal_material="$(kpr_marker_flag "${log}" "${MARK_HEAL_MATERIAL_STABLE}" \
      'materialSame')"
    heal_advanced="$(kpr_marker_flag "${log}" "${MARK_HEAL_MATERIAL_STABLE}" \
      'createdAtAdvanced')"
    heal_slot="$(kpr_marker_flag "${log}" "${MARK_HEAL_MATERIAL_STABLE}" \
      'dSame')"
    if [[ -z "${healed_n}" ]]; then
      kpr_finding "no '${MARK_HEALED} ... healed=<N>' line — the under-served \
relay was added but no heal was recorded."
    elif (( healed_n < 1 )); then
      kpr_finding "the tick chose to heal and ${healed_n} relay(s) acked it."
    fi
    if [[ "${heal_material}" != "true" || "${heal_advanced}" != "true" \
          || "${heal_slot}" != "true" ]]; then
      kpr_finding "the heal reading is incomplete \
(materialSame=${heal_material:-<absent>}, \
createdAtAdvanced=${heal_advanced:-<absent>}, dSame=${heal_slot:-<absent>}). \
All three must hold, and the pair 'same material, newer created_at' is the \
whole point: it is the direct wire evidence that a heal moves the EVENT \
timestamp and leaves the rotation clock alone."
    else
      kpr_note "heal: identical material re-served into the same slot \
$(kpr_marker_number "${log}" "${MARK_HEAL_MATERIAL_STABLE}" 'dCreatedAt')s \
later — the event timestamp advanced, the Lifetime did not."
    fi
  fi

  (( ${#KPR_FINDINGS[@]} == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no device, no relay.
#
# Chosen so a predicate that has rotted into always-passing cannot survive.
# (20) is the HEALTHY app and must PASS — without it an oracle hard-coded to
# red would look correct everywhere else. (21)-(24) are the near-misses the
# brief named: not rotated, rotated into a different `d`, published but acked
# by nobody, and an Add that succeeded while decryption failed. (25)-(29) are
# the vacuity routes, each of which would otherwise let the headline pass or
# fail for a reason that is not about rotation at all.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <expected-rc> <actual-rc>
    local label="$1" want="$2" got="$3"
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
    if [[ "${got}" == "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want "%s", got "%s")\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _names_case() { # _names_case <label> <needle>
    local label="$1" needle="$2"
    if [[ "${KPR_FINDINGS[*]}" == *"${needle}"* ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (no finding mentioning "%s")\n' \
        "${label}" "${needle}" >&2
      fails=1
    fi
  }

  # Applies each sed expression and FAILS if the file came out unchanged.
  #
  # This exists because the first draft of these fixtures silently did nothing:
  # the marker literals start `[kpr]`, which sed reads as a character class, so
  # every "negative" fixture was a byte-identical copy of the healthy one and
  # every negative case passed vacuously. A mutation that changes nothing is a
  # fixture that proves nothing, and it is invisible without this check.
  _mutate() { # _mutate <file> <sed-expr ...>
    local out="$1"; shift
    (( $# == 0 )) && return 0
    local before expr
    before="$(mktemp)"
    cp "${out}" "${before}"
    for expr in "$@"; do
      sed -i "${expr}" "${out}"
    done
    if cmp -s "${before}" "${out}"; then
      printf '  \033[1;31mFAIL\033[0m fixture mutation changed NOTHING (%s) — this negative fixture is a copy of the healthy one\n' \
        "$*" >&2
      fails=1
    fi
    rm -f "${before}"
  }

  # A complete, PASSING capture. Written as a function so each negative fixture
  # mutates exactly one line and nothing else — the difference between the
  # fixtures IS the property under test.
  _fixture_full() { # _fixture_full <outfile> [sed-expr ...]
    local out="$1"; shift
    printf '%s\n' \
      "I/flutter ( 40): ${MARK_BASELINE_MINTED} onRelay=1" \
      "I/flutter ( 40): ${MARK_REQ_CLOCK} 1 0" \
      "I/flutter ( 40): ${MARK_REQ_CLOCK} 1 0" \
      "I/flutter ( 40): ${MARK_CLOCK_RESTORED} jumpedSecs=6047998" \
      "I/flutter ( 40): ${MARK_BASELINE_FETCHED} elapsedPct=83 ageDays=70 slotStable=true" \
      "I/flutter ( 40): ${MARK_ROTATED} action=${EXPECTED_ROTATE_ACTION} healed=1 probed=1" \
      "I/flutter ( 40): ${MARK_SUPERSEDED} dSame=true idChanged=true materialChanged=true dCreatedAt=6047999" \
      "I/flutter ( 40): ${MARK_WELCOME_ACCEPTED}" \
      "I/flutter ( 40): ${MARK_PEER_DECRYPT_MATCH} dLat=0.0 dLon=0.0" \
      "I/flutter ( 40): ${MARK_HEAL_TARGET_ADDED}" \
      "I/flutter ( 40): ${MARK_HEALED} action=${EXPECTED_HEAL_ACTION} healed=1" \
      "I/flutter ( 40): ${MARK_HEAL_MATERIAL_STABLE} materialSame=true createdAtAdvanced=true dSame=true dCreatedAt=4" \
      "I/flutter ( 40): ${MARK_COMPLETE}" \
      > "${out}"
    _mutate "${out}" "$@"
  }

  # The matching healthy servo record: the pre-drive backdate plus the one
  # restore the drive asked for.
  _fixture_servo() { # _fixture_servo <outfile> [sed-expr ...]
    local out="$1"; shift
    printf '%s\n' \
      "seq=${BACKDATE_SEQ} offset=-${BACKDATE_SECS} expected=1748000000 device=1748000000 drift=0 status=ok" \
      'seq=1 offset=0 expected=1754048000 device=1754048000 drift=0 status=ok' \
      > "${out}"
    _mutate "${out}" "$@"
  }

  echo "run-kp-rotation.sh --self-test"

  # --- The protocol arithmetic this lane's whole premise rests on -----------
  # (1) The backdate must sit strictly between the rotation point and expiry.
  #     A future edit of KPR_BACKDATE_SECS that fell outside would make every
  #     run either test nothing (below the threshold) or test the WRONG branch
  #     (past not_after), and both would still look like an ordinary red.
  local rc=0
  (( BACKDATE_SECS > MLS_KP_ROTATE_AT_SECS )) || rc=1
  _case "backdate is past the 0.75 rotation point" 0 "${rc}"
  rc=0; (( BACKDATE_SECS < MLS_KP_EXPIRES_AFTER_SECS )) || rc=1
  _case "backdate is short of the package's expiry" 0 "${rc}"
  # (2) 0.75 of the span, recomputed. Pins the two constants against each
  #     other so one cannot be edited without the other.
  _eq_case "rotate-at is 0.75 of the lifetime span" "${MLS_KP_ROTATE_AT_SECS}" \
    "$(( MLS_KP_LIFETIME_SPAN_SECS * 3 / 4 ))"

  # --- kpr_has_marker ------------------------------------------------------
  # (3) A raw drive-log line.
  printf '%s\n' "${MARK_ROTATED} action=x healed=1" > "${tmp}/raw.log"
  rc=0; kpr_has_marker "${tmp}/raw.log" "${MARK_ROTATED}" || rc=1
  _case "marker found in a raw drive log" 0 "${rc}"

  # (4) THE SHAPE THAT ACTUALLY SHIPS — the same line via logcat, prefixed.
  #     An anchored match would pass (3) and silently fail every real run.
  printf '%s\n' "I/flutter ( 4021): ${MARK_COMPLETE}" > "${tmp}/lc.log"
  rc=0; kpr_has_marker "${tmp}/lc.log" "${MARK_COMPLETE}" || rc=1
  _case "marker found behind a logcat prefix" 0 "${rc}"

  # (5) A missing file is not evidence of success.
  rc=0; kpr_has_marker "${tmp}/nope.log" "${MARK_ROTATED}" || rc=1
  _case "missing log reports absent" 1 "${rc}"

  # (6) THE NEGATIVE-TWIN TRAP. `ROTATION_DECLINED` must never satisfy a search
  #     for `ROTATED`, or a run in which nothing rotated would read as one that
  #     did — the single most dangerous false green available here.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_ROTATION_DECLINED} action=alreadyHealthy" \
    > "${tmp}/twin.log"
  rc=0; kpr_has_marker "${tmp}/twin.log" "${MARK_ROTATED}" || rc=1
  _case "ROTATION_DECLINED does not satisfy ROTATED" 1 "${rc}"

  # (7) The same trap on the heal pair, where the twin CONTAINS the word.
  printf '%s\n' "I/flutter ( 40): ${MARK_HEAL_MATERIAL_ROTATED}" \
    > "${tmp}/twin2.log"
  rc=0; kpr_has_marker "${tmp}/twin2.log" "${MARK_ROTATED}" || rc=1
  _case "HEAL_MATERIAL_ROTATED does not satisfy ROTATED" 1 "${rc}"
  rc=0; kpr_has_marker "${tmp}/twin2.log" "${MARK_HEALED}" || rc=1
  _case "HEAL_MATERIAL_ROTATED does not satisfy HEALED" 1 "${rc}"

  # (8) …and on the two `BASELINE_` pairs, whose positives are prefixes of
  #     nothing but whose twins are near-anagrams.
  printf '%s\n' "I/flutter ( 40): ${MARK_BASELINE_MINT_FAILED}" \
    > "${tmp}/twin3.log"
  rc=0; kpr_has_marker "${tmp}/twin3.log" "${MARK_BASELINE_MINTED}" || rc=1
  _case "BASELINE_MINT_FAILED does not satisfy BASELINE_MINTED" 1 "${rc}"
  printf '%s\n' "I/flutter ( 40): ${MARK_CLOCK_RESTORE_TIMEOUT}" \
    > "${tmp}/twin4.log"
  rc=0; kpr_has_marker "${tmp}/twin4.log" "${MARK_CLOCK_RESTORED}" || rc=1
  _case "CLOCK_RESTORE_TIMEOUT does not satisfy CLOCK_RESTORED" 1 "${rc}"

  # --- kpr_marker_number ---------------------------------------------------
  # (9) Double digits must not lose to a lexical sort ('9' > '12').
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_ROTATED} action=x healed=9" \
    "I/flutter ( 40): ${MARK_ROTATED} action=x healed=12" \
    > "${tmp}/wide.log"
  _eq_case "numeric (not lexical) max" "12" \
    "$(kpr_marker_number "${tmp}/wide.log" "${MARK_ROTATED}" 'healed')"

  # (10) THE CRITICAL PARSE. `healed=0` is a rotation nobody received, and it
  #      CONTAINS the marker — a presence grep would call it a pass.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_ROTATED} action=x healed=0 probed=1" \
    > "${tmp}/zero.log"
  _eq_case "zero heal count parsed as 0 (not as presence)" "0" \
    "$(kpr_marker_number "${tmp}/zero.log" "${MARK_ROTATED}" 'healed')"

  # (11) A key on an UNRELATED marker must not answer for ours — both ROTATED
  #      and HEALED carry `healed=`.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_ROTATED} action=x healed=1" \
    "I/flutter ( 40): ${MARK_HEALED} action=y healed=7" \
    > "${tmp}/mixed.log"
  _eq_case "key scoped to its own marker" "1" \
    "$(kpr_marker_number "${tmp}/mixed.log" "${MARK_ROTATED}" 'healed')"

  # (12) Absent marker -> empty, which is DISTINCT from "0".
  printf '%s\n' 'I/flutter ( 40): nothing here' > "${tmp}/none.log"
  _eq_case "absent marker yields empty (not 0)" "" \
    "$(kpr_marker_number "${tmp}/none.log" "${MARK_ROTATED}" 'healed')"

  # --- kpr_marker_flag -----------------------------------------------------
  # (13) The verdict reading, with the CRLF adb actually emits.
  printf "I/flutter ( 40): ${MARK_ROTATED} action=${EXPECTED_ROTATE_ACTION} healed=1\r\n" \
    > "${tmp}/flag.log"
  _eq_case "action flag parsed (CRLF)" "${EXPECTED_ROTATE_ACTION}" \
    "$(kpr_marker_flag "${tmp}/flag.log" "${MARK_ROTATED}" 'action')"

  # --- kpr_req_clock_seqs / kpr_jump_ok_seqs -------------------------------
  # (14) The drive RE-EMITS its request; a repeat is not a second request.
  _fixture_full "${tmp}/dedup.log"
  _eq_case "repeated REQ_CLOCK deduplicated to one seq" "1" \
    "$(kpr_req_clock_seqs "${tmp}/dedup.log" | tr '\n' ' ' | tr -d ' ')"

  # (15) An empty / absent servo log must yield NO applied seqs. A grep that
  #      matches nothing is how a guard becomes a silent no-op.
  : > "${tmp}/servo-empty.log"
  _eq_case "empty servo log reports no applied jumps" "" \
    "$(kpr_jump_ok_seqs "${tmp}/servo-empty.log")"
  _eq_case "missing servo log reports no applied jumps" "" \
    "$(kpr_jump_ok_seqs "${tmp}/servo-absent.log")"

  # (16) THE B8 FIXTURE, inherited: a record whose read-back drift is the FULL
  #      requested magnitude means `date` exited 0 and the clock never moved.
  #      It must never count as applied.
  printf '%s\n' \
    "seq=0 offset=-${BACKDATE_SECS} expected=1748000000 device=1754048000 drift=${BACKDATE_SECS} status=drift" \
    > "${tmp}/servo-drift.log"
  _eq_case "a full-magnitude drift is NOT an applied jump" "" \
    "$(kpr_jump_ok_seqs "${tmp}/servo-drift.log")"

  # --- kpr_run_oracle: THE HEALTHY APP -------------------------------------
  # (17) Must PASS. Without this, an oracle hard-coded to red would look
  #      correct on every negative fixture below.
  _fixture_full "${tmp}/ok.log"
  _fixture_servo "${tmp}/ok.servo"
  rc=0; kpr_run_oracle "${tmp}/ok.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "a fully-healthy capture PASSES" 0 "${rc}"

  # --- kpr_run_oracle: THE NEAR-MISSES -------------------------------------
  # (18) THE PRE-FIX CONDITION. Everything else is identical; the tick simply
  #      reported `alreadyHealthy` and the peer's re-fetch was unchanged. This
  #      is the state the repo shipped in, and the lane MUST go red on it.
  _fixture_full "${tmp}/notrotated.log" \
    "s/ROTATED action=${EXPECTED_ROTATE_ACTION} healed=1 probed=1/ROTATION_DECLINED action=alreadyHealthy/" \
    "s/SUPERSEDED .*/SUPERSEDE_FAILED reason=unchanged/"
  rc=0
  kpr_run_oracle "${tmp}/notrotated.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "a run in which NOTHING rotated is REPORTED" 1 "${rc}"
  _names_case "not-rotated finding names the pre-fix behaviour" "pre-fix"

  # (19) Rotated into a DIFFERENT `d`. The tick is happy, a peer sees new
  #      material — and the old, expiring package stays addressable next to it.
  _fixture_full "${tmp}/slot.log" \
    "s/SUPERSEDED .*/SUPERSEDE_FAILED reason=slot_changed/"
  rc=0; kpr_run_oracle "${tmp}/slot.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "rotation into a DIFFERENT d slot fails the lane" 1 "${rc}"
  _names_case "different-slot finding names the reuse MUST" "MUST"

  # (20) Published, acked by NOBODY. The action names the branch that RAN and
  #      is chosen before the write is attempted, so this is the shape in which
  #      a completed-looking rotation reaches no peer at all.
  _fixture_full "${tmp}/unacked.log" \
    "s/ROTATED action=${EXPECTED_ROTATE_ACTION} healed=1 probed=1/ROTATED action=${EXPECTED_ROTATE_ACTION} healed=0 probed=1/"
  rc=0; kpr_run_oracle "${tmp}/unacked.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "a rotation no relay acked fails the lane" 1 "${rc}"
  _names_case "unacked finding names the zero-heal shape" "zero heals"

  # (21) THE ADD SUCCEEDED AND DECRYPTION FAILED. The Welcome was accepted, so
  #      an "Add succeeded" check passes — and the group is unusable. This is
  #      the exact failure mode the brief singles out.
  _fixture_full "${tmp}/deadgroup.log" \
    "s/PEER_DECRYPT_MATCH .*/PEER_DECRYPT_DEAD/"
  rc=0
  kpr_run_oracle "${tmp}/deadgroup.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "an accepted Welcome with a dead group fails the lane" 1 "${rc}"
  _names_case "dead-group finding names the Add-succeeded blind spot" \
    "Add-succeeded"

  # (22) The heal RE-MINTED instead of republishing — the rotation clock would
  #      restart on every relay hiccup.
  _fixture_full "${tmp}/healrotated.log" \
    "s/HEAL_MATERIAL_STABLE .*/HEAL_MATERIAL_ROTATED/"
  rc=0
  kpr_run_oracle "${tmp}/healrotated.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "a heal that re-minted fails the lane" 1 "${rc}"

  # (23) The Add itself was rejected — the headline defect.
  _fixture_full "${tmp}/addfail.log" \
    "s/WELCOME_ACCEPTED/WELCOME_FAILED/" \
    "s/PEER_DECRYPT_MATCH .*/PEER_DECRYPT_DEAD/"
  rc=0; kpr_run_oracle "${tmp}/addfail.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "an Add the inviter rejected fails the lane" 1 "${rc}"

  # --- kpr_run_oracle: THE VACUITY ROUTES ----------------------------------
  # (24) THE ROOT VACUITY. The pre-drive backdate never landed, so the package
  #      was minted seconds before it was asked whether it needed rotating.
  #      Every other marker is present and healthy.
  _fixture_servo "${tmp}/nobackdate.servo" \
    "s/^seq=${BACKDATE_SEQ} .*status=ok/seq=${BACKDATE_SEQ} offset=-${BACKDATE_SECS} expected=1748000000 device=1754048000 drift=${BACKDATE_SECS} status=drift/"
  rc=0
  kpr_run_oracle "${tmp}/ok.log" "${tmp}/nobackdate.servo" >/dev/null || rc=1
  _case "a backdate that never applied fails as vacuous" 1 "${rc}"
  _names_case "unapplied-backdate finding says vacuous" "vacuous"

  # (25) The drive asked for a clock change the servo never fulfilled.
  _fixture_servo "${tmp}/norestore.servo" "/^seq=1 /d"
  rc=0
  kpr_run_oracle "${tmp}/ok.log" "${tmp}/norestore.servo" >/dev/null || rc=1
  _case "an unfulfilled REQ_CLOCK fails the lane" 1 "${rc}"

  # (26) Nothing was ever published, so there is nothing to supersede.
  _fixture_full "${tmp}/nobaseline.log" \
    "s/BASELINE_MINTED onRelay=1/BASELINE_MINT_FAILED/"
  rc=0
  kpr_run_oracle "${tmp}/nobaseline.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "no baseline package fails as vacuous" 1 "${rc}"

  # (27) A peer never read the PRE-rotation package, so the lane cannot claim
  #      to have watched a transition rather than a fresh account.
  _fixture_full "${tmp}/nofetch.log" \
    "s/BASELINE_FETCHED .*/BASELINE_UNFETCHABLE/"
  rc=0; kpr_run_oracle "${tmp}/nofetch.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "no pre-rotation fetch fails the lane" 1 "${rc}"

  # (28) THE SILENT-VACUITY FIXTURE. Every marker present, every count right —
  #      but the material was only 12% through its lifetime, so whatever the
  #      tick did was not the 0.75 threshold firing. This is what a lane with a
  #      too-small backdate looks like, and it must NOT be green.
  _fixture_full "${tmp}/tooyoung.log" \
    "s/elapsedPct=83 ageDays=70/elapsedPct=12 ageDays=10/"
  rc=0
  kpr_run_oracle "${tmp}/tooyoung.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "material below the 75% point fails the lane" 1 "${rc}"

  # (29) …and its twin at the other boundary: EXPIRED material re-mints through
  #      the not-current branch, not the threshold branch.
  _fixture_full "${tmp}/expired.log" \
    "s/elapsedPct=83 ageDays=70/elapsedPct=118 ageDays=99/"
  rc=0; kpr_run_oracle "${tmp}/expired.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "EXPIRED material fails the lane" 1 "${rc}"

  # (30) The wrong rotate branch: `rotatedUnreadableLifetime` proves the reader
  #      broke, not that the threshold works.
  _fixture_full "${tmp}/unreadable.log" \
    "s/action=${EXPECTED_ROTATE_ACTION} healed=1 probed=1/action=rotatedUnreadableLifetime healed=1 probed=1/"
  rc=0
  kpr_run_oracle "${tmp}/unreadable.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "rotation via the unreadable-lifetime branch fails the lane" 1 "${rc}"

  # (31) A truncated capture (the drive died) must say so FIRST, so its
  #      downstream absences are not misread as product defects.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_BASELINE_MINTED} onRelay=1" \
    "I/flutter ( 40): ${MARK_REQ_CLOCK} 1 0" \
    > "${tmp}/truncated.log"
  rc=0
  kpr_run_oracle "${tmp}/truncated.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "truncated capture fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${KPR_FINDINGS[0]}" != *"${MARK_COMPLETE}"* ]]; then
    printf '  \033[1;31mFAIL\033[0m truncated capture does not report the drive first\n' >&2
    fails=1
  fi

  # (32) An EMPTY log proves nothing. It must read as "every checkpoint
  #      missing", never as "nothing wrong here".
  : > "${tmp}/empty.log"
  rc=0; kpr_run_oracle "${tmp}/empty.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "empty capture fails the lane" 1 "${rc}"

  # (33) A missing capture likewise.
  rc=0; kpr_run_oracle "${tmp}/absent.log" "${tmp}/ok.servo" >/dev/null || rc=1
  _case "missing capture fails the lane" 1 "${rc}"

  # --- state restoration ---------------------------------------------------
  # (34) THE STATE-RESTORE FIXTURE. Phase 2 pins `auto_time`/`auto_time_zone`
  #      to 0 so NITZ/NTP cannot undo the backdate. Restoring the clock VALUE
  #      does not undo that pin, and every Android lane in this repo shares one
  #      AVD cache key — a leaked pin hands the next lane an AVD that can never
  #      re-synchronise.
  local self restore_list restore_rc=0 g
  self="${BASH_SOURCE[0]}"
  restore_list="$(auto_time_restore_cmds)"
  for g in auto_time auto_time_zone; do
    grep -qE "^adb -s .*settings put global ${g} 0" "${self}" || restore_rc=1
    [[ "${restore_list}" == *"settings put global ${g} 1"* ]] || restore_rc=1
  done
  sed -n '/^cleanup()/,/^}/p' "${self}" \
    | grep -qE '^[[:space:]]+restore_auto_time_pin$' || restore_rc=1
  _case "every pinned clock global is applied AND restored by cleanup()" 0 \
    "${restore_rc}"

  # (35) THE MIRROR. Every marker above must exist VERBATIM in the drive
  #      target, and every marker the drive target declares must exist above.
  #
  #      This is the one invariant nothing else can catch. Sibling lanes carry
  #      it as a comment ("change both together"), and a rename on one side
  #      alone does not fail anything: the drive still passes, the shell still
  #      finds no marker, and the oracle reports a product defect that is
  #      really a typo. Checking BOTH directions matters — a marker added to
  #      the target and not here is evidence the oracle silently ignores.
  local target_file mirror_rc=0 m
  target_file="${SCRIPT_DIR}/../../../haven/integration_test/kp_rotation_wire_test.dart"
  local -a all_marks=(
    "${MARK_REQ_CLOCK}" "${MARK_BASELINE_MINTED}"
    "${MARK_BASELINE_MINT_FAILED}" "${MARK_CLOCK_RESTORED}"
    "${MARK_CLOCK_RESTORE_TIMEOUT}" "${MARK_BASELINE_FETCHED}"
    "${MARK_BASELINE_UNFETCHABLE}" "${MARK_ROTATED}"
    "${MARK_ROTATION_DECLINED}" "${MARK_SUPERSEDED}"
    "${MARK_SUPERSEDE_FAILED}" "${MARK_WELCOME_ACCEPTED}"
    "${MARK_WELCOME_FAILED}" "${MARK_PEER_DECRYPT_MATCH}"
    "${MARK_PEER_DECRYPT_DEAD}" "${MARK_HEAL_TARGET_ADDED}"
    "${MARK_HEALED}" "${MARK_HEAL_DECLINED}"
    "${MARK_HEAL_MATERIAL_STABLE}" "${MARK_HEAL_MATERIAL_ROTATED}"
    "${MARK_COMPLETE}"
  )
  if [[ ! -f "${target_file}" ]]; then
    printf '  \033[1;31mFAIL\033[0m drive target not found at %s\n' \
      "${target_file}" >&2
    mirror_rc=1
  else
    for m in "${all_marks[@]}"; do
      if ! grep -qF -- "'${m}'" "${target_file}"; then
        printf '  \033[1;31mFAIL\033[0m the shell matches "%s" but the drive target never declares it\n' \
          "${m}" >&2
        mirror_rc=1
      fi
    done
    while IFS= read -r m; do
      [[ -n "${m}" ]] || continue
      if [[ " ${all_marks[*]} " != *" ${m} "* ]]; then
        printf '  \033[1;31mFAIL\033[0m the drive target declares "%s" and this oracle never reads it\n' \
          "${m}" >&2
        mirror_rc=1
      fi
    done < <(grep -oE "'\[kpr\] [A-Z_]+'" "${target_file}" | tr -d "'" \
               | sort -u)
  fi
  _case "markers mirror the drive target in BOTH directions" 0 "${mirror_rc}"

  # (36) The drive-log failure predicate this lane leans on is exercised by its
  #      own self-test; assert only that sourcing worked, so a refactor that
  #      drops the `source` fails here rather than at 3am.
  rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
  _case "drive-log failure predicate is in scope" 0 "${rc}"

  if (( fails )); then
    echo "run-kp-rotation.sh --self-test: FAILURES (see above)" >&2
    return 1
  fi
  echo "run-kp-rotation.sh --self-test: all 36 fixture groups passed"
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
readonly LOG_DIR="/tmp/kpr-logs"
readonly APK="${1:-/tmp/integration-apks/kp_rotation_wire_test.apk}"
readonly TARGET="${2:-integration_test/kp_rotation_wire_test.dart}"

# Bounds the drive only. The step's `run-with-deadline.sh` wrapper bounds
# install + the clock pin + the oracle on top; see
# scripts/ci/check_e2e_step_timeout_ordering.sh for the ordering invariant.
#
# Sizing: the drive's own budget is bootstrap + first mint (~60s) + the clock
# rendezvous (bounded at 180s inside the drive) + a peer bootstrap and two
# discovery-cascade fetches (~60s) + circle creation and the Welcome round trip
# (~90s) + up to 120s for the peer decrypt + the heal phase (~60s) — roughly
# 10 min worst case against a 20-minute in-test `Timeout`. 24m stays ABOVE that
# Timeout so a genuine overrun fails with a named test rather than an anonymous
# kill, and BELOW the step deadline so the attributable message is reachable.
readonly DRIVE_TIMEOUT="${KPR_DRIVE_TIMEOUT:-24m}"

# How often the servo re-reads logcat for a new request.
readonly SERVO_POLL_SECS="${KPR_SERVO_POLL_SECS:-1}"

# Fail closed on an undeclared receive path. `liveSyncEnabled` is
# `bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue: true)`, so an omitted
# flag does not produce an "unset" build — it produces a LIVE build nobody
# chose (CI_HARDENING_BACKLOG.md A7). The value is baked into the APK by
# build-kp-rotation-apk.sh; this check is here so a job that forgot it fails
# with a name rather than in an unrelated assertion 20 minutes later.
if [[ -z "${HAVEN_LIVE_SYNC:-}" ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC is not set. Set it to 'true' or 'false' in" >&2
  echo "       the calling job's env — it decides which receive path the" >&2
  echo "       APK this script drives was compiled with." >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false'" \
       "(got '${HAVEN_LIVE_SYNC}')." >&2
  exit 2
fi

# The backdate is interpolated into an arithmetic expansion and a `date -d`
# argument; validate it rather than trust it, and re-assert the two protocol
# bounds --self-test pins so an env override cannot quietly de-fang the lane.
if [[ ! "${BACKDATE_SECS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: KPR_BACKDATE_SECS='${BACKDATE_SECS}' is not a whole number" \
       "of seconds." >&2
  exit 2
fi
if (( BACKDATE_SECS <= MLS_KP_ROTATE_AT_SECS )); then
  echo "ERROR: KPR_BACKDATE_SECS=${BACKDATE_SECS} does not reach the 0.75" \
       "rotation point (${MLS_KP_ROTATE_AT_SECS}s). No rotation would be due," \
       "so the lane would prove nothing." >&2
  exit 2
fi
if (( BACKDATE_SECS >= MLS_KP_EXPIRES_AFTER_SECS )); then
  echo "ERROR: KPR_BACKDATE_SECS=${BACKDATE_SECS} is past the package's own" \
       "expiry (${MLS_KP_EXPIRES_AFTER_SECS}s). The tick would re-mint through" \
       "the not-current branch, which is NOT the 0.75 threshold this lane" \
       "exists to prove." >&2
  exit 2
fi

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

# R2's distinct identity. start-strfry.sh manages exactly ONE relay keyed by
# these three variables and `docker rm -f`s its own container name on start, so
# R2 must differ in all three or starting it would destroy R1.
readonly R2_CONTAINER="strfry2"
readonly R2_PORT="7778"
readonly R2_DATA_DIR="/tmp/strfry2-data"

LOGCAT_PID=""
SERVO_PID=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.kpr.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
# `.log` (not `.txt`) so the EXIT trap's directory walk scans it too.
readonly JUMP_LOG="${LOG_DIR}/clock-jumps.log"
readonly SERVO_STOP="${LOG_DIR}/.servo-stop"

# ---------------------------------------------------------------------------
# Clock control
# ---------------------------------------------------------------------------

# Sets the device wall clock to `host_now + <offset seconds>` and records what
# the device reported back.
#
# The read-back is the whole point. `date` on Android exits 0 in situations
# where it changed nothing (no root, a re-enabled auto_time, a read-only
# clock), and this repo has been bitten before by trusting an exit code over an
# authoritative read (`pm grant`). So the servo records `expected`, `device`
# and `drift`, and the oracle keys on `status=ok`, which only an in-tolerance
# read-back produces.
apply_clock_offset() {
  local seq="$1" offset="$2"
  local host_now expected stamp device drift status

  host_now="$(date -u +%s)"
  expected=$(( host_now + offset ))
  # toybox `date` takes the SET value positionally as MMDDhhmm[[CC]YY][.ss];
  # it has no coreutils `-s`. Rendered on the host so the format is produced by
  # a parser this script can reason about.
  stamp="$(date -u -d "@${expected}" +%m%d%H%M%Y.%S)"

  status="ok"
  if ! adb -s "${DEVICE}" shell "date -u ${stamp}" >/dev/null 2>&1; then
    status="error"
  fi
  # Tell the framework the wall clock moved. Harmless if nothing listens; a few
  # services cache "now" and would otherwise keep the old value.
  adb -s "${DEVICE}" shell "am broadcast -a android.intent.action.TIME_SET" \
    >/dev/null 2>&1 || true

  device="$(adb -s "${DEVICE}" shell date -u +%s 2>/dev/null | tr -dc '0-9')"
  if [[ -z "${device}" ]]; then
    device=0
    status="error"
  fi
  # Recompute `expected` against a FRESH host reading: the adb round trips
  # above take real time, and comparing against the pre-command host clock
  # would charge that latency to the drift budget.
  expected=$(( $(date -u +%s) + offset ))
  drift=$(( device - expected ))
  # `if`, not `(( … )) && …`: under `set -e` a false arithmetic test is a
  # non-zero status, and this function also runs inside the background servo —
  # the short-circuit form would silently kill the servo on every healthy jump.
  if (( drift < 0 )); then
    drift=$(( -drift ))
  fi
  if [[ "${status}" == "ok" ]] && (( drift > JUMP_DRIFT_TOLERANCE_SECS )); then
    status="drift"
  fi

  echo "seq=${seq} offset=${offset} expected=${expected} device=${device}" \
       "drift=${drift} status=${status}" >> "${JUMP_LOG}"
  echo "  [servo] seq=${seq} offset=${offset}s -> status=${status} (drift ${drift}s)"
}

# Re-enables the automatic time sync phase 2 pinned off.
#
# Best-effort by design (`|| true`): this runs from the EXIT trap, which is also
# reached when the device was never ready, and a restore that killed the trap
# would skip the secret scan below it (Security Rule 6). Idempotent — 1 is the
# stock value on every AVD this repo boots — so it is safe on the paths where
# no pin was ever applied.
restore_auto_time_pin() {
  local cmd
  while IFS= read -r cmd; do
    [[ -n "${cmd}" ]] || continue
    adb -s "${DEVICE}" shell "${cmd}" >/dev/null 2>&1 || true
  done < <(auto_time_restore_cmds)
}

# Background servo: fulfils `REQ_CLOCK` requests as the drive emits them.
#
# Polls the growing logcat capture rather than consuming a pipe, so a servo
# restart or a slow reader can never lose a request, and the same file the
# oracle later reads is the one the servo acted on.
clock_servo() {
  local handled=" " seq
  local -a pending
  while [[ ! -f "${SERVO_STOP}" ]]; do
    # Snapshot into an ARRAY rather than iterating a `read` loop fed by a
    # process substitution. `apply_clock_offset` shells out to `adb shell`,
    # which reads stdin — inside a read loop it would swallow the rest of the
    # request list and the servo would silently fulfil only the first request.
    pending=()
    mapfile -t pending < <(kpr_req_clock_seqs "${LOGCAT_FILE}")
    for seq in "${pending[@]}"; do
      [[ -z "${seq}" ]] && continue
      [[ "${handled}" == *" ${seq} "* ]] && continue
      handled+="${seq} "
      # The drive only ever asks for offset 0 — "put the clock back to host
      # time" — so the offset is NOT read out of the log. A request that could
      # name an arbitrary offset would let a corrupted logcat line move the
      # device clock anywhere.
      apply_clock_offset "${seq}" 0 </dev/null
    done
    sleep "${SERVO_POLL_SECS}"
  done
}

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the helpers, RESTORE the device clock AND the
# automatic-time pin, run the MANDATORY secret scan over every captured log
# (Security Rule 6 — must run even on a phase failure), snapshot + tear down
# both relays. Escalates on a leak; never masks a phase rc. Mirrors
# run-b8-clock-skew.sh's containment posture, including the deliberate
# asymmetry between rc 1 (leak -> destroy) and rc 3 (unscannable -> keep,
# because there is no leak and the truncated artefacts ARE the evidence).
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  local scan_rc=0
  trap - EXIT
  touch "${SERVO_STOP}" 2>/dev/null || true
  if [[ -n "${SERVO_PID}" ]] && kill -0 "${SERVO_PID}" 2>/dev/null; then
    kill "${SERVO_PID}" 2>/dev/null || true
  fi
  # Put the clock back before anything else runs against this device. The
  # workflow's `if: failure()` diagnostics, the artifact upload and any later
  # lane on the same runner all assume a sane clock; leaving it 70 days behind
  # would turn this lane's failure into someone else's mystery.
  apply_clock_offset "restore" 0 >/dev/null 2>&1 || true
  # …and un-pin the automatic sync. NOT gated on the servo: the pin is applied
  # in phase 2, long before the servo exists.
  restore_auto_time_pin
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  docker logs strfry > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  docker logs "${R2_CONTAINER}" > "${LOG_DIR}/strfry2.final.log" 2>&1 || true
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  bash "${SECRET_SCAN}" "${LOG_DIR}" || scan_rc=$?
  if (( scan_rc == 1 )); then
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    {
      echo "Logs withheld: the secret-leak guard tripped (Security Rule 6)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped on KPR logs — logs deleted," \
         "not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    echo "ERROR: secret-leak guard could not scan the KPR logs" \
         "(rc=${scan_rc}) — see the UNUSABLE line(s) above. Logs kept for" \
         "triage." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  STRFRY_CONTAINER="${R2_CONTAINER}" STRFRY_DATA_DIR="${R2_DATA_DIR}" \
    bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "KPR-LANE-FAIL: $*" >&2
  echo "---- [kpr] checkpoints seen ----" >&2
  grep -aF '[kpr] ' "${DRIVE_LOG}" "${LOGCAT_FILE}" 2>/dev/null | tail -40 >&2 \
    || echo "(none — the drive target reached no checkpoint at all)" >&2
  echo "---- clock servo records ----" >&2
  cat "${JUMP_LOG}" 2>/dev/null >&2 || echo "(no servo records)" >&2
  echo "---- device clock now ----" >&2
  adb -s "${DEVICE}" shell date -u 2>/dev/null >&2 || true
  exit 1
}

# ---------------------------------------------------------------------------
# Phase 0 — two hermetic relays + device readiness.
#
# R1 carries the whole scenario. R2 exists only for the final phase: it is a
# responder that does not serve Alice's slot, which is what makes the tick take
# the heal branch.
# ---------------------------------------------------------------------------
echo "Phase 0/4 — starting hermetic relays R1 and R2..."
bash "${START_STRFRY}"
STRFRY_CONTAINER="${R2_CONTAINER}" \
  STRFRY_PORT="${R2_PORT}" \
  STRFRY_DATA_DIR="${R2_DATA_DIR}" \
  bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device
echo "Phase 0/4 — relays up, device ready."

# ---------------------------------------------------------------------------
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky state from
# a prior target survives into this run — a stale SQLCipher DB would carry a
# tracked KeyPackage row minted at true time and the backdate would prove
# nothing.
# ---------------------------------------------------------------------------
echo "Phase 1/4 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — a WRITABLE clock, pinned, then BACKDATED before the first mint.
#
# `adb root` is required to set the clock and is available on the `google_apis`
# (userdebug) AVD every Android lane in this repo uses; it is NOT available on
# `google_apis_playstore` (user build). Failing here rather than limping on is
# deliberate: without a writable clock the KeyPackage is minted seconds before
# it is asked whether it needs rotating, and a vacuous green is the outcome
# this whole lane exists to prevent.
# ---------------------------------------------------------------------------
echo "Phase 2/4 — acquiring root and disabling automatic time..."
adb -s "${DEVICE}" root >/dev/null 2>&1 || true
# `adb root` restarts adbd; without this the next command races the restart.
adb -s "${DEVICE}" wait-for-device
if ! adb -s "${DEVICE}" shell id 2>/dev/null | grep -q 'uid=0'; then
  fail "adb shell is not running as root, so the device clock cannot be set. \
This lane needs a userdebug image (target: google_apis). Without a writable \
clock the KeyPackage under test is seconds old, no rotation is due, and a \
GREEN result would prove nothing."
fi
# NITZ / NTP would silently undo the backdate. Turn both off BEFORE applying
# it, and verify: `settings put` exits 0 whether or not it took effect.
adb -s "${DEVICE}" shell settings put global auto_time 0 >/dev/null 2>&1 || true
adb -s "${DEVICE}" shell settings put global auto_time_zone 0 >/dev/null 2>&1 || true
auto_time="$(adb -s "${DEVICE}" shell settings get global auto_time 2>/dev/null | tr -dc '0-9')"
if [[ "${auto_time}" != "0" ]]; then
  fail "could not disable global auto_time (reads '${auto_time:-<empty>}'). \
Android would re-synchronise the clock mid-run and silently undo the backdate, \
which turns the whole lane vacuous."
fi

: > "${JUMP_LOG}"
echo "Phase 2/4 — backdating the device clock by ${BACKDATE_SECS}s" \
     "($(( BACKDATE_SECS / 86400 )) days)..."
apply_clock_offset "${BACKDATE_SEQ}" "-${BACKDATE_SECS}"
if [[ " $(kpr_jump_ok_seqs "${JUMP_LOG}" | tr '\n' ' ') " \
      != *" ${BACKDATE_SEQ} "* ]]; then
  fail "the backdate did not take: \
'$(kpr_jump_record "${JUMP_LOG}" "${BACKDATE_SEQ}")'. \`date\` exits 0 on \
Android in several situations where it changes nothing, so this read-back is \
the only place a silent refusal is visible at all."
fi
echo "Phase 2/4 — device clock is $(( BACKDATE_SECS / 86400 )) days in the past."

# ---------------------------------------------------------------------------
# Phase 3 — capture, arm the servo, drive.
#
# The servo must be running BEFORE the drive, or the request could be emitted
# into a log nobody is watching and the drive would time out waiting for a jump
# that was never going to come.
# ---------------------------------------------------------------------------
echo "Phase 3/4 — capturing logcat and arming the clock servo..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!
rm -f "${SERVO_STOP}"
# `trap - EXIT` inside the subshell: a background job inherits the EXIT trap,
# and this one exits normally when the drive finishes. Without the disarm the
# servo's own exit would run `cleanup` — tearing down the relays and the clock
# underneath a live drive.
( trap - EXIT; clock_servo ) &
SERVO_PID=$!

echo "Phase 3/4 — driving ${TARGET}..."
drc=0
( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}" ) > "${DRIVE_LOG}" 2>&1 || drc=$?

touch "${SERVO_STOP}"

# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect the
# STEP log, which has no retention control and cannot be redacted after the
# fact — a wider, more permanent sink than the artifact upload.
if bash "${SECRET_SCAN}" "${DRIVE_LOG}"; then
  cat "${DRIVE_LOG}" || true
else
  echo "drive log withheld from the step log — secret-leak guard tripped." >&2
fi

# ---------------------------------------------------------------------------
# Phase 4 — the oracle.
# ---------------------------------------------------------------------------
echo "Phase 4/4 — asserting the rotation chain..."

# Step 1: the drive itself. `drc == 0` is NOT sufficient — `flutter drive`
# exits 0 when the on-device suite failed outside a testWidgets body, and when
# nothing ran at all (drive-log-lib.sh).
if (( drc != 0 )); then
  fail "flutter drive exited ${drc} for ${TARGET}."
fi
if drive_log_reports_test_failure "${DRIVE_LOG}"; then
  echo "---- app-side failure evidence ----" >&2
  drive_log_failure_evidence "${DRIVE_LOG}" >&2
  fail "flutter drive exited 0 but the ON-DEVICE suite reported a failure (or \
ran nothing). The package comparisons live in the drive target, so this is \
where a mismatch surfaces."
fi

# Step 2: the checkpoint oracle. Run over the drive log first, then over
# logcat, and require only that ONE of them yields a clean verdict: both carry
# the same `debugPrint` output, but a drive killed mid-write truncates its own
# log while the logcat capture keeps going. A marker present in either is a
# marker the app really printed. The servo record is the same file for both, so
# the clock checks cannot differ between the two runs.
oracle_rc=0
if ! kpr_run_oracle "${DRIVE_LOG}" "${JUMP_LOG}"; then
  if kpr_run_oracle "${LOGCAT_FILE}" "${JUMP_LOG}"; then
    echo "  (the drive log was incomplete; the logcat capture carries the" \
         "full sequence)"
  else
    oracle_rc=1
  fi
fi

if (( oracle_rc != 0 )); then
  echo >&2
  echo "==== KPR FINDINGS ====" >&2
  for f in ${KPR_FINDINGS[@]+"${KPR_FINDINGS[@]}"}; do
    echo "  - ${f}" >&2
  done
  fail "the KeyPackage-rotation chain did not hold end to end (see the \
findings above)."
fi

echo
echo "KPR lane PASSED — a KeyPackage minted 70 days ago rotated through the"
echo "production maintenance decision, superseded itself in the same \`d\` slot"
echo "from a fetcher's point of view, was used by a SEPARATE participant to add"
echo "its owner to a circle, and that owner then DECRYPTED a message in the"
echo "resulting group. A subsequent heal re-served identical material under a"
echo "newer \`created_at\`, so the rotation clock lives in the package and not"
echo "in any event timestamp."
