#!/usr/bin/env bash
#
# B8 runtime-proof orchestrator for the `e2e-clock-skew` CI lane
# (docs/CI_HARDENING_BACKLOG.md Workstream B, item B8 — "Clock jump +/-6h").
#
# ## What this lane GATES
#
# That a wrong device clock is DETECTED and SURFACED rather than failing
# silently. Seven properties, each emitted by the drive as a `[b8] OK <name>`
# line and each required by this script:
#
#   rejection-classified        a fast clock's relay refusal reaches Dart as a
#                               typed device-clock fault, not as a generic
#                               publish failure;
#   rejection-verdict           …and reaches a consumer that raises a verdict;
#   peer-single-source-silent   ONE member reporting a future time does NOT
#                               accuse this device's clock;
#   peer-corroborated           TWO distinct MLS-authenticated members
#                               agreeing DOES;
#   surface-rejected            the fast-clock fault reaches the user;
#   surface-behind              the slow-clock fault reaches the user;
#   surface-distinct            …and the two say different things (one means
#                               nothing is shared, the other means the send
#                               succeeded and the data was then discarded).
#
# ## What this lane RECORDS but does not gate
#
# A +/-6 h jump still costs a device real delivery, and the drive measures
# that cost and prints it as `[b8] EVIDENCE`. It is recorded rather than
# asserted because every one of those measurements bottoms out in the device
# signing a `created_at` its own clock does not hold — clock correction —
# which moves the 228 s TTL, the `since` cursor floor and the MDK peeler's
# inner/outer timestamp binding with it, and is deferred to its own security
# analysis:
#
#   * the MDK peeler stamps the inner app event with `now_unix_seconds()`
#     (transport-nostr-peeler/src/event.rs:180,217) and BINDS the outer
#     kind-445 `created_at` to it (peeler.rs:169);
#   * the engine derives the outer NIP-40 `expiration` as
#     `inner_created_at + message-retention.v1`, and Haven stamps every circle
#     with `LOCATION_MESSAGE_RETENTION_SECS = 228`
#     (haven-core/src/location/ttl.rs:80) — so the TTL rides the SAME skewed
#     clock as `created_at`, and a backdated event is born already expired;
#   * `SessionManager::process_event` (haven-core/src/nostr/mls/manager.rs:594)
#     drops any event whose expiration is more than
#     `RECEIVER_EXPIRATION_GRACE_SECS = 60` s in the receiver's past, before
#     decryption. Making it keep such an event means widening a REPLAY
#     defence, which is not a trade this lane may make;
#   * `run_catchup_all_circles` advances the persisted cursor to the SENDER's
#     `created_at` (haven-core/src/relay/catchup.rs:336-348) and
#     `since_for_stream` re-derives the next REQ floor as
#     `cursor - GROUP_RESUBSCRIBE_BUFFER_SECS` (60 s)
#     (haven-core/src/relay/cursor.rs:114-130) — a window property no
#     detection change moves.
#
# Same evidence-vs-finding split B1, B5, B6 and B9 use. EVIDENCE is printed on
# every run, green or red; it is a standing record of a live residual defect.
#
# CAVEAT (2026-08-05) on the last two bullets above. They describe RECEIVER-side
# costs, and a NIP-40-enforcing relay refuses a born-expired event at INGEST —
# so on this hermetic relay there is no accepted event for the receiver gate or
# the cursor window to act on, and those two measurements do not run. The drive
# says so explicitly via `[b8] EVIDENCE backward-skew-readside` rather than
# skipping them in silence, which would leave the lane's output looking as
# though they had been checked and found clean. Both remain covered by unit
# tests; re-homing them somewhere they can execute end-to-end is open work
# tracked in docs/CI_HARDENING_BACKLOG.md.
#
# ## Why the clock is moved from HERE and not from Dart
#
# The app process cannot set the system clock, and a Dart-side fake would test
# a fake. So the drive target ASKS (`[b8] REQ_CLOCK <seq> <offset>` on logcat)
# and this script answers with a real `adb shell date` against a rooted
# emulator. The drive then polls its OWN wall clock against a monotonic
# `Stopwatch` until it observes the discontinuity, so the rendezvous is an
# observation rather than a blind sleep.
#
# ## The oracle
#
#   1. ASSERT the drive ran to the end (`[b8] ALL_PHASES_COMPLETE`). Without
#      it every negative below it could be "the body died early" instead.
#   2. ASSERT every requested jump was FULFILLED — each `REQ_CLOCK` has a
#      servo record with an in-tolerance adb read-back. This is the
#      anti-vacuity check and the most important line in the file: if the
#      clock never moved, the drive's phases all ran at true time and a GREEN
#      run would prove nothing at all.
#   3. ASSERT every requested jump was OBSERVED by the app process
#      (`CLOCK_OBSERVED`), so the skew demonstrably reached the code under
#      test and not merely the shell.
#   4. ASSERT every `[b8] OK <name>` above is PRESENT. A positive check, not
#      an absence check: an oracle that never ran leaves no FINDING either,
#      so check 5 alone would bless a drive whose gating half was deleted.
#   5. ASSERT no `[b8] FINDING` line. Each one names a detection or surfacing
#      property that regressed; they are printed in full on failure.
#   6. ASSERT the drive itself passed (`flutter drive` exits 0 on a FAILED
#      test — see drive-log-lib.sh).
#
# Checks 2 and 3 are deliberately separate. A servo that set the clock while
# the app somehow did not see it, and an app that reported seeing a jump the
# servo never made, are different failures with different fixes, and folding
# them into one check would report either as the other.
#
# This lane is expected GREEN on a healthy tree. Do not "fix" a red by
# relaxing an assertion, and do not convert a FINDING into EVIDENCE to quiet
# it — see CLAUDE.md, Testing Requirements #5.
#
# Usage:
#   run-b8-clock-skew.sh <apk> <target.dart>   run the lane (needs emulator-5554)
#   run-b8-clock-skew.sh --self-test           hermetic parser self-test
#
set -Eeuo pipefail

# Shared app-side failure predicate — `flutter drive` can exit 0 on a failed
# test. Sourced before the --self-test dispatch so the hermetic self-test runs
# against a fully-wired script.
# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drive-log-lib.sh"

# ---------------------------------------------------------------------------
# VERBATIM markers (haven/integration_test/b8_clock_skew_test.dart).
# Kept as fixed literals matched with `grep -aF` / awk `index()`: logcat is
# binary-tainted and these strings contain regex metacharacters.
# ---------------------------------------------------------------------------
readonly MARK_REQ_CLOCK='[b8] REQ_CLOCK'
readonly MARK_CLOCK_OBSERVED='[b8] CLOCK_OBSERVED'
readonly MARK_CLOCK_TIMEOUT='[b8] CLOCK_TIMEOUT'
readonly MARK_FINDING='[b8] FINDING'
readonly MARK_EVIDENCE='[b8] EVIDENCE'
readonly MARK_ALL_PHASES='[b8] ALL_PHASES_COMPLETE'

# The gating oracles, by name. Every one must appear as `[b8] OK <name>`.
#
# A LIST rather than a chain of inline greps so --self-test can assert two
# things a chain cannot express: that a reverted fix is reported by NAME, and
# that every name here is really declared by the drive target (fixture group
# 14). Adding an oracle to the Dart target without adding it here would leave
# it ungated; adding it here without the target would fail every run.
required_ok_markers() {
  printf '%s\n' \
    'rejection-classified' \
    'rejection-verdict' \
    'peer-single-source-silent' \
    'peer-corroborated' \
    'surface-rejected' \
    'surface-behind' \
    'surface-distinct'
}

# Largest |device - expected| the read-back may show and still count as a
# fulfilled jump. `date` sets whole seconds and adb round-trips add a beat, so
# some slop is normal; 60 s is two orders of magnitude below the 21600 s
# signal, so it can never launder a jump that did not happen.
readonly JUMP_DRIFT_TOLERANCE_SECS=60

# ---------------------------------------------------------------------------
# Parsers. Each is exercised by --self-test against synthetic fixtures, so the
# oracle cannot silently rot into one that accepts the failing case.
# ---------------------------------------------------------------------------

# Print the seq number of every `REQ_CLOCK` line, in order, deduplicated.
#
# Deduplicated because logcat can legitimately repeat a line (the ring buffer
# is read live and `debugPrint` re-emits on throttle flush); a duplicate
# request is not a second request, and counting it as one would make check 2
# demand a servo record that was never supposed to exist.
req_clock_seqs() {
  local logfile="$1"
  { grep -aoE '\[b8\] REQ_CLOCK [0-9]+ -?[0-9]+' "${logfile}" 2>/dev/null \
      | awk '{ print $3 }' | awk '!seen[$0]++'; } || true
}

# Print the requested OFFSET for a given seq (first occurrence wins).
req_clock_offset() {
  local logfile="$1" seq="$2"
  { grep -aoE "\\[b8\\] REQ_CLOCK ${seq} -?[0-9]+" "${logfile}" 2>/dev/null \
      | awk '{ print $4; exit }'; } || true
}

# Print the seq number of every `CLOCK_OBSERVED` line, deduplicated.
observed_clock_seqs() {
  local logfile="$1"
  { grep -aoE '\[b8\] CLOCK_OBSERVED [0-9]+ -?[0-9]+' "${logfile}" 2>/dev/null \
      | awk '{ print $3 }' | awk '!seen[$0]++'; } || true
}

# Print every FINDING line, with the logcat prefix stripped so the message is
# readable in a step log. Deduplicated for the same reason as above.
finding_lines() {
  local logfile="$1"
  { sed -n 's/.*\(\[b8\] FINDING \)/\1/p' "${logfile}" 2>/dev/null \
      | awk '!seen[$0]++'; } || true
}

# Print every EVIDENCE line, prefix-stripped and deduplicated.
#
# Same shape as finding_lines() and deliberately a SEPARATE parser: the two
# must never be able to leak into each other. An EVIDENCE line read as a
# finding would fail the lane for a defect that is out of scope; a FINDING
# read as evidence would silently un-gate the fix. Fixture group 15 pins both
# directions.
evidence_lines() {
  local logfile="$1"
  { sed -n 's/.*\(\[b8\] EVIDENCE \)/\1/p' "${logfile}" 2>/dev/null \
      | awk '!seen[$0]++'; } || true
}

# Whether the drive emitted `[b8] OK <name>`.
#
# Matched as a fixed string with a trailing boundary so `surface-behind`
# cannot be satisfied by a hypothetical `surface-behind-partial`, and so a
# FINDING that happens to quote a marker name in its prose cannot satisfy it
# either (a FINDING line's prefix is `[b8] FINDING `, never `[b8] OK `).
has_ok_marker() {
  local logfile="$1" name="$2"
  grep -aqE "\\[b8\\] OK ${name}([^A-Za-z0-9_-]|\$)" "${logfile}" 2>/dev/null
}

# Print the name of every required OK marker the log does NOT carry.
#
# Fail-closed by construction: a missing, empty or unreadable log makes
# has_ok_marker false for every name, so the whole list comes back as missing
# rather than an empty "nothing wrong here".
missing_ok_markers() {
  local logfile="$1" name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if ! has_ok_marker "${logfile}" "${name}"; then
      printf '%s\n' "${name}"
    fi
  done < <(required_ok_markers)
}

# Print the seq numbers the servo recorded as successfully applied.
#
# The servo log is written by THIS script (one line per attempt,
# `seq=<n> offset=<o> expected=<e> device=<d> drift=<x> status=<ok|drift|error>`),
# so the oracle reads a record of what actually happened on the device rather
# than trusting that a command that exited 0 had the intended effect. `pm
# grant` taught this repo that lesson (CI_HARDENING_BACKLOG.md, B-spike).
jump_ok_seqs() {
  local jumpfile="$1"
  { grep -aoE 'seq=[0-9]+ .*status=ok' "${jumpfile}" 2>/dev/null \
      | awk '{ print $1 }' | sed 's/^seq=//' | awk '!seen[$0]++'; } || true
}

# Print the full servo record for one seq (for failure messages).
jump_record() {
  local jumpfile="$1" seq="$2"
  { grep -aE "^seq=${seq} " "${jumpfile}" 2>/dev/null | tail -1; } || true
}

# The `settings put` commands that UNDO phase 0's clock pin, one per line.
#
# A list rather than two inline `adb` calls so --self-test can assert (a) that
# every global this script pins to 0 has a matching restore to 1, and (b) that
# the EXIT trap actually issues them. The pin is the one mutation this lane
# makes that the clock restore does NOT cover: `apply_clock_offset restore 0`
# puts the VALUE back but leaves `auto_time`/`auto_time_zone` disabled, so the
# AVD would keep an un-synchronised clock for good. That matters beyond this
# runner — every Android lane in this repo shares ONE actions/cache key over
# `~/.android/avd/*`, so a pinned-clock AVD can in principle be published to all
# of them. B5, B6 and B9 all restore their own device mutations; this closes the
# only gap.
#
# Defined ABOVE the --self-test dispatch on purpose: `exit` there means anything
# declared further down does not exist yet when the fixtures run.
auto_time_restore_cmds() {
  printf '%s\n' \
    'settings put global auto_time 1' \
    'settings put global auto_time_zone 1'
}

# ---------------------------------------------------------------------------
# --self-test — hermetic parser validation, no device.
#
# Runs BEFORE the EXIT trap is installed: the trap tears down docker/strfry
# and restores the device clock, neither of which a hermetic self-test may
# touch.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fail=0 got
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # THE HEALTHY RUN: every jump landed, every gating oracle held, and the
  # residual delivery costs were recorded as EVIDENCE. Both skew directions
  # bottom out the same way against a NIP-40-enforcing relay — the fast clock's
  # event is too far in the future, the slow clock's is born already expired —
  # so both are refused at ingest and neither is gated. This is what the lane
  # must read as green.
  printf '%s\n' \
    '08-03 04:41:02.001  1234  1300 I flutter : [b8] phase 0/5 complete' \
    '08-03 04:41:03.001  1234  1300 I flutter : [b8] REQ_CLOCK 1 21600' \
    '08-03 04:41:33.001  1234  1300 I flutter : [b8] CLOCK_OBSERVED 1 21601' \
    '08-03 04:41:40.001  1234  1300 I flutter : [b8] EVIDENCE forward-skew-publish: the relay refuses a +6h kind-445' \
    '08-03 04:41:41.001  1234  1300 I flutter : [b8] OK rejection-classified' \
    '08-03 04:41:42.001  1234  1300 I flutter : [b8] OK rejection-verdict' \
    '08-03 04:41:43.001  1234  1300 I flutter : [b8] OK surface-rejected' \
    '08-03 04:42:03.001  1234  1300 I flutter : [b8] REQ_CLOCK 2 0' \
    '08-03 04:42:33.001  1234  1300 I flutter : [b8] CLOCK_OBSERVED 2 -21599' \
    '08-03 04:43:03.001  1234  1300 I flutter : [b8] REQ_CLOCK 3 -21600' \
    '08-03 04:43:33.001  1234  1300 I flutter : [b8] CLOCK_OBSERVED 3 -21600' \
    '08-03 04:43:34.001  1234  1300 I flutter : [b8] OK peer-single-source-silent' \
    '08-03 04:43:35.001  1234  1300 I flutter : [b8] OK peer-corroborated' \
    '08-03 04:43:36.001  1234  1300 I flutter : [b8] OK surface-behind' \
    '08-03 04:43:50.001  1234  1300 I flutter : [b8] EVIDENCE backward-skew-publish: born already expired, refused at ingest' \
    '08-03 04:43:51.001  1234  1300 I flutter : [b8] EVIDENCE backward-skew-readside: retention/receive/catch-up not measurable' \
    '08-03 04:44:03.001  1234  1300 I flutter : [b8] REQ_CLOCK 4 0' \
    '08-03 04:44:33.001  1234  1300 I flutter : [b8] CLOCK_OBSERVED 4 21600' \
    '08-03 04:44:50.001  1234  1300 I flutter : [b8] OK surface-distinct' \
    '08-03 04:45:00.001  1234  1300 I flutter : [b8] ALL_PHASES_COMPLETE findings=0 evidence=3' \
    > "${tmp}/green.log"

  # (1) All four requests are seen, in order, exactly once.
  got="$(req_clock_seqs "${tmp}/green.log" | tr '\n' ',')"
  if [[ "${got}" != "1,2,3,4," ]]; then
    echo "SELF-TEST FAIL (1): expected '1,2,3,4,', got '${got}'" >&2
    fail=1
  fi

  # (2) Offsets are read back per seq, INCLUDING the negative one. A parser
  #     that dropped the sign would make the backward-skew phase silently run
  #     forward, i.e. the lane would test one direction twice.
  got="$(req_clock_offset "${tmp}/green.log" 3)"
  if [[ "${got}" != "-21600" ]]; then
    echo "SELF-TEST FAIL (2): expected offset -21600 for seq 3, got '${got}'" >&2
    fail=1
  fi

  # (3) Observations pair up with requests.
  got="$(observed_clock_seqs "${tmp}/green.log" | tr '\n' ',')"
  if [[ "${got}" != "1,2,3,4," ]]; then
    echo "SELF-TEST FAIL (3): expected observations '1,2,3,4,', got '${got}'" >&2
    fail=1
  fi

  # (4) A clean run yields no findings — and the EVIDENCE lines on the SAME
  #     log must not be mistaken for any. This is the whole risk of the
  #     evidence convention: an evidence line read as a finding would fail the
  #     lane for a defect that is deliberately out of scope.
  got="$(finding_lines "${tmp}/green.log" | wc -l | tr -d ' ')"
  if [[ "${got}" != "0" ]]; then
    echo "SELF-TEST FAIL (4): a clean log must yield 0 findings, got ${got}" >&2
    fail=1
  fi
  got="$(evidence_lines "${tmp}/green.log" | wc -l | tr -d ' ')"
  if [[ "${got}" != "3" ]]; then
    echo "SELF-TEST FAIL (4b): expected 3 evidence lines on the healthy log," \
         "got ${got} — the delivery cost this lane RECORDS is not being read" >&2
    fail=1
  fi

  # (4c) …and the healthy log satisfies every gating oracle. Without this the
  #      "reverted fix" fixtures below could pass against a list that nothing
  #      can ever satisfy, i.e. a lane that is red on a healthy tree.
  got="$(missing_ok_markers "${tmp}/green.log" | tr '\n' ',')"
  if [[ -n "${got}" ]]; then
    echo "SELF-TEST FAIL (4c): the HEALTHY fixture is missing OK marker(s)" \
         "'${got}' — the lane would be red on a healthy tree" >&2
    fail=1
  fi

  # --- THE CRITICAL FIXTURES: a red run must be READ as red. --------------
  printf '%s\n' \
    '08-03 04:41:03.001  1234  1300 I flutter : [b8] REQ_CLOCK 1 21600' \
    '08-03 04:41:33.001  1234  1300 I flutter : [b8] CLOCK_OBSERVED 1 21600' \
    '08-03 04:41:40.001  1234  1300 I flutter : [b8] FINDING forward-skew-publish: the relay refused it' \
    '08-03 04:43:40.001  1234  1300 I flutter : [b8] FINDING backward-skew-catchup: window skipped backlog' \
    '08-03 04:45:00.001  1234  1300 I flutter : [b8] ALL_PHASES_COMPLETE findings=2' \
    > "${tmp}/red.log"

  # (5) Both findings are extracted, and the logcat prefix is stripped so the
  #     step log shows the message rather than the timestamp columns.
  got="$(finding_lines "${tmp}/red.log" | wc -l | tr -d ' ')"
  if [[ "${got}" != "2" ]]; then
    echo "SELF-TEST FAIL (5): expected 2 findings, got ${got}" >&2
    fail=1
  fi
  if ! finding_lines "${tmp}/red.log" | grep -qF -- '[b8] FINDING forward-skew-publish:'; then
    echo "SELF-TEST FAIL (5b): the finding text was not preserved" >&2
    fail=1
  fi
  if finding_lines "${tmp}/red.log" | grep -q '1234  1300'; then
    echo "SELF-TEST FAIL (5c): the logcat column prefix leaked into the finding" >&2
    fail=1
  fi

  # (6) A request with NO observation must be detectable — the drive never saw
  #     the jump. Without this the lane could pass while the clock stayed put
  #     inside the app process.
  printf '%s\n' \
    '08-03 04:41:03.001  1234  1300 I flutter : [b8] REQ_CLOCK 1 21600' \
    '08-03 04:43:33.001  1234  1300 I flutter : [b8] CLOCK_TIMEOUT 1' \
    > "${tmp}/unobserved.log"
  if [[ -n "$(observed_clock_seqs "${tmp}/unobserved.log")" ]]; then
    echo "SELF-TEST FAIL (6): a timed-out jump was reported as observed" >&2
    fail=1
  fi
  if ! grep -aqF -- "${MARK_CLOCK_TIMEOUT}" "${tmp}/unobserved.log"; then
    echo "SELF-TEST FAIL (6b): the timeout marker was not matchable" >&2
    fail=1
  fi

  # (7) A truncated run (no terminal marker) must be distinguishable from a
  #     clean one. This is what stops "the body died at phase 2" from reading
  #     as "phases 3 and 4 found nothing".
  if grep -aqF -- "${MARK_ALL_PHASES}" "${tmp}/unobserved.log"; then
    echo "SELF-TEST FAIL (7): a truncated log claimed all phases completed" >&2
    fail=1
  fi

  # --- servo-record parsing ------------------------------------------------
  printf '%s\n' \
    'seq=1 offset=21600 expected=1785000000 device=1785000001 drift=1 status=ok' \
    'seq=2 offset=0 expected=1784978400 device=1784978400 drift=0 status=ok' \
    'seq=3 offset=-21600 expected=1784956800 device=1784978400 drift=21600 status=drift' \
    > "${tmp}/jumps.log"

  # (8) Only the jumps that actually LANDED count. seq 3's device clock never
  #     moved (drift == the full requested magnitude), which is exactly the
  #     vacuity mode this lane must never pass on.
  got="$(jump_ok_seqs "${tmp}/jumps.log" | tr '\n' ',')"
  if [[ "${got}" != "1,2," ]]; then
    echo "SELF-TEST FAIL (8): expected ok seqs '1,2,', got '${got}'" >&2
    fail=1
  fi

  # (9) The failing record is retrievable for the failure message — a bare
  #     "seq 3 did not apply" with no read-back is untriageable.
  got="$(jump_record "${tmp}/jumps.log" 3)"
  if [[ "${got}" != *"status=drift"* || "${got}" != *"drift=21600"* ]]; then
    echo "SELF-TEST FAIL (9): expected seq 3's drift record, got '${got}'" >&2
    fail=1
  fi

  # (10) An empty / absent servo log must yield NO ok seqs, never a silent
  #      pass. `set -e` plus a grep that matches nothing is the classic way a
  #      guard turns into a no-op.
  : > "${tmp}/empty.log"
  if [[ -n "$(jump_ok_seqs "${tmp}/empty.log")" ]]; then
    echo "SELF-TEST FAIL (10): an empty servo log reported applied jumps" >&2
    fail=1
  fi
  if [[ -n "$(jump_ok_seqs "${tmp}/does-not-exist.log")" ]]; then
    echo "SELF-TEST FAIL (10b): a MISSING servo log reported applied jumps" >&2
    fail=1
  fi

  # (11) The drift gate itself, as arithmetic rather than as a grep: the
  #       tolerance must reject a jump that did not move the clock and accept
  #       one that did.
  if (( 21600 <= JUMP_DRIFT_TOLERANCE_SECS )); then
    echo "SELF-TEST FAIL (11): the tolerance is wide enough to accept a" \
         "clock that never moved" >&2
    fail=1
  fi
  if (( 2 > JUMP_DRIFT_TOLERANCE_SECS )); then
    echo "SELF-TEST FAIL (11b): the tolerance rejects normal adb slop" >&2
    fail=1
  fi

  # (12) The date format this script feeds toybox `date` must round-trip
  #       through the host's own parser, or every jump silently no-ops.
  #       Rendered and re-read here so a format typo fails hermetically
  #       instead of on an emulator 20 minutes into a lane.
  local stamp back
  stamp="$(date -u -d "@1785000000" +%m%d%H%M%Y.%S)"
  if [[ ! "${stamp}" =~ ^[0-9]{12}\.[0-9]{2}$ ]]; then
    echo "SELF-TEST FAIL (12): 'MMDDhhmmCCYY.ss' render is malformed:" \
         "'${stamp}'" >&2
    fail=1
  fi
  back="$(date -u -d "$(date -u -d "@1785000000" '+%Y-%m-%d %H:%M:%S')" +%s)"
  if [[ "${back}" != "1785000000" ]]; then
    echo "SELF-TEST FAIL (12b): epoch did not round-trip (got '${back}')" >&2
    fail=1
  fi

  # --- (13) THE STATE-RESTORE FIXTURE. Phase 0 pins `auto_time` /
  #       `auto_time_zone` to 0 so NITZ/NTP cannot undo a jump. That pin
  #       OUTLIVES the run — the clock restore does not touch it — and the AVD
  #       is cached across every Android lane, so an unrestored pin is a
  #       mutation this lane hands to its neighbours. Asserted structurally
  #       (each pin has a matching restore, and the trap issues them) rather
  #       than by re-running adb, which a hermetic self-test cannot do.
  local self="${BASH_SOURCE[0]}" restore_list key
  restore_list="$(auto_time_restore_cmds)"

  # (13a) Every global this script actually PINS has a restore. Scanned from
  #       the real invocation lines (anchored at `^adb -s`), never from prose:
  #       a comment mentioning a setting must not be able to satisfy — or to
  #       trip — this check.
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    if ! grep -qxF -- "settings put global ${key} 1" <<<"${restore_list}"; then
      echo "SELF-TEST FAIL (13a): phase 0 pins global '${key}' to 0 but" \
           "auto_time_restore_cmds never puts it back to 1 — the AVD would" \
           "be cached with that pin still in force" >&2
      fail=1
    fi
  done < <(grep -oE '^adb -s .*settings put global [a-z_]+ 0' "${self}" \
             | grep -oE 'global [a-z_]+ 0$' | awk '{ print $2 }' | sort -u)

  # (13b) …and the pin is real: a scan that matched nothing would make (13a)
  #       vacuously true, which is this repo's signature failure.
  if ! grep -qE '^adb -s .*settings put global auto_time 0' "${self}"; then
    echo "SELF-TEST FAIL (13b): found no 'settings put global auto_time 0'" \
         "invocation, so fixture 13a scanned nothing and proved nothing" >&2
    fail=1
  fi

  # (13c) The restore is WIRED. An unreferenced restore helper restores
  #       nothing, and the EXIT trap is the only path that runs on every exit
  #       route (phase-0 failure, a `fail`, a leak, or success).
  if ! awk '/^cleanup\(\) \{/,/^\}/' "${self}" \
       | grep -qE '^[[:space:]]+restore_auto_time_pin$'; then
    echo "SELF-TEST FAIL (13c): cleanup() does not call restore_auto_time_pin," \
         "so the pin survives the lane on every exit route" >&2
    fail=1
  fi

  # --- (14) Every gated NAME is really declared by the drive target. -------
  #
  # The two files carry the marker literals independently (logcat is the only
  # channel between them), so a rename on one side silently disarms the
  # oracle: the drive stops emitting a line nobody requires, or this script
  # requires a line nobody emits. Scanned from the CONST DECLARATION shape,
  # never from prose — a comment quoting a marker name must not be able to
  # satisfy this check (this repo has shipped a guard that matched its own
  # documentation before).
  local target repo dart_missing=""
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  target="${repo}/haven/integration_test/b8_clock_skew_test.dart"
  if [[ ! -f "${target}" ]]; then
    echo "SELF-TEST FAIL (14): drive target not found at ${target}, so the" \
         "marker-parity check scanned nothing" >&2
    fail=1
  else
    while IFS= read -r key; do
      [[ -n "${key}" ]] || continue
      if ! grep -qE "^const String k[A-Za-z0-9]+ = '\\[b8\\] OK ${key}';\$" \
             "${target}"; then
        dart_missing+="${key} "
      fi
    done < <(required_ok_markers)
    if [[ -n "${dart_missing}" ]]; then
      echo "SELF-TEST FAIL (14): this script requires OK marker(s)" \
           "'${dart_missing% }' that b8_clock_skew_test.dart does not declare." \
           "The lane would be red on a healthy tree." >&2
      fail=1
    fi

    # (14b) …and the SIX line markers this script parses are declared too.
    #       MARK_EVIDENCE is the one that most needs saying: a literal the
    #       drive spells differently would make the recorded evidence vanish
    #       from every artifact without failing anything.
    local mark esc
    for mark in "${MARK_REQ_CLOCK}" "${MARK_CLOCK_OBSERVED}" \
                "${MARK_CLOCK_TIMEOUT}" "${MARK_FINDING}" \
                "${MARK_EVIDENCE}" "${MARK_ALL_PHASES}"; do
      esc="$(sed 's/[][\\.*^$/]/\\&/g' <<<"${mark}")"
      if ! grep -qE "^const String k[A-Za-z0-9]+ = '${esc}';\$" "${target}"; then
        echo "SELF-TEST FAIL (14b): this script parses '${mark}' but" \
             "b8_clock_skew_test.dart declares no such marker constant —" \
             "the two files have drifted and that channel is dead" >&2
        fail=1
      fi
    done
  fi

  # --- (15) EVIDENCE and FINDING must not leak into each other. ------------
  #
  # Both directions, because both are silent. An EVIDENCE line read as a
  # finding fails the lane for a defect that is out of scope; a FINDING read
  # as evidence un-gates the fix and the lane goes permanently green.
  printf '%s\n' \
    '08-03 04:41:40.001  1234  1300 I flutter : [b8] EVIDENCE backward-skew-catchup: the window skipped backlog' \
    '08-03 04:41:41.001  1234  1300 I flutter : [b8] EVIDENCE backward-skew-retention: the relay dropped it' \
    > "${tmp}/evidence-only.log"
  if [[ -n "$(finding_lines "${tmp}/evidence-only.log")" ]]; then
    echo "SELF-TEST FAIL (15): an EVIDENCE line was read as a FINDING — the" \
         "lane would fail on the delivery cost it only means to record" >&2
    fail=1
  fi
  if [[ "$(evidence_lines "${tmp}/evidence-only.log" | wc -l | tr -d ' ')" != "2" ]]; then
    echo "SELF-TEST FAIL (15b): the EVIDENCE parser did not read both lines" >&2
    fail=1
  fi
  if [[ -n "$(evidence_lines "${tmp}/red.log")" ]]; then
    echo "SELF-TEST FAIL (15c): a FINDING line was read as EVIDENCE — the" \
         "lane would report a regression as a recorded measurement" >&2
    fail=1
  fi

  # --- (16) THE REVERTED-FIX FIXTURES. --------------------------------------
  #
  # One per load-bearing piece of the clock-skew fix. Each is a log the drive
  # would emit if that piece were reverted, and each must be reported BY NAME.
  # These are what make "the lane fails if the fix is reverted" a tested claim
  # rather than an assertion in a comment.

  # (16a) `publish_with_retry` collapses a fully-unacknowledged publish back
  #       into `RelayError::AllRelaysFailed` (the pre-fix behaviour). The
  #       refusal reaches Dart untyped, so the classification, the verdict and
  #       the surface all fall over together.
  printf '%s\n' \
    '08-03 04:41:03.001  1234  1300 I flutter : [b8] REQ_CLOCK 1 21600' \
    '08-03 04:41:33.001  1234  1300 I flutter : [b8] CLOCK_OBSERVED 1 21600' \
    '08-03 04:41:41.001  1234  1300 I flutter : [b8] FINDING clock-fault-classification: the refusal reached Dart as RelayServiceException with NO device-clock classification' \
    '08-03 04:41:42.001  1234  1300 I flutter : [b8] FINDING clock-fault-verdict: the detector verdict is still none' \
    '08-03 04:41:43.001  1234  1300 I flutter : [b8] FINDING clock-fault-surface-rejected: the banner painted NOTHING' \
    '08-03 04:43:34.001  1234  1300 I flutter : [b8] OK peer-single-source-silent' \
    '08-03 04:43:35.001  1234  1300 I flutter : [b8] OK peer-corroborated' \
    '08-03 04:43:36.001  1234  1300 I flutter : [b8] OK surface-behind' \
    '08-03 04:44:50.001  1234  1300 I flutter : [b8] OK surface-distinct' \
    '08-03 04:45:00.001  1234  1300 I flutter : [b8] ALL_PHASES_COMPLETE findings=3 evidence=1' \
    > "${tmp}/reverted-classification.log"
  got="$(missing_ok_markers "${tmp}/reverted-classification.log" | tr '\n' ',')"
  if [[ "${got}" != "rejection-classified,rejection-verdict,surface-rejected," ]]; then
    echo "SELF-TEST FAIL (16a): a reverted publish_with_retry must be reported" \
         "as missing 'rejection-classified,rejection-verdict,surface-rejected,'," \
         "got '${got}'" >&2
    fail=1
  fi
  if [[ "$(finding_lines "${tmp}/reverted-classification.log" | wc -l | tr -d ' ')" != "3" ]]; then
    echo "SELF-TEST FAIL (16b): the reverted-classification run must also" \
         "report its three FINDINGs" >&2
    fail=1
  fi

  # (16c) `minCorroboratingSources` reverted to 1. Everything else still
  #       works, so exactly ONE name goes missing — the near-miss a
  #       coarse "any OK line present" check would bless.
  printf '%s\n' \
    '08-03 04:41:41.001  1234  1300 I flutter : [b8] OK rejection-classified' \
    '08-03 04:41:42.001  1234  1300 I flutter : [b8] OK rejection-verdict' \
    '08-03 04:41:43.001  1234  1300 I flutter : [b8] OK surface-rejected' \
    '08-03 04:43:34.001  1234  1300 I flutter : [b8] FINDING slow-clock-single-source: ONE member reporting a future time already raised peersAheadOfDevice' \
    '08-03 04:43:35.001  1234  1300 I flutter : [b8] OK peer-corroborated' \
    '08-03 04:43:36.001  1234  1300 I flutter : [b8] OK surface-behind' \
    '08-03 04:44:50.001  1234  1300 I flutter : [b8] OK surface-distinct' \
    '08-03 04:45:00.001  1234  1300 I flutter : [b8] ALL_PHASES_COMPLETE findings=1 evidence=2' \
    > "${tmp}/reverted-corroboration.log"
  got="$(missing_ok_markers "${tmp}/reverted-corroboration.log" | tr '\n' ',')"
  if [[ "${got}" != "peer-single-source-silent," ]]; then
    echo "SELF-TEST FAIL (16c): a corroboration rule reverted to one source" \
         "must be reported as missing exactly 'peer-single-source-silent,'," \
         "got '${got}'" >&2
    fail=1
  fi

  # (16d) The two faults collapsed into one sentence. Only the distinctness
  #       oracle falls, and it must not be rescued by the two per-fault
  #       surface markers that are still there.
  printf '%s\n' \
    '08-03 04:41:41.001  1234  1300 I flutter : [b8] OK rejection-classified' \
    '08-03 04:41:42.001  1234  1300 I flutter : [b8] OK rejection-verdict' \
    '08-03 04:41:43.001  1234  1300 I flutter : [b8] OK surface-rejected' \
    '08-03 04:43:34.001  1234  1300 I flutter : [b8] OK peer-single-source-silent' \
    '08-03 04:43:35.001  1234  1300 I flutter : [b8] OK peer-corroborated' \
    '08-03 04:43:36.001  1234  1300 I flutter : [b8] OK surface-behind' \
    '08-03 04:44:50.001  1234  1300 I flutter : [b8] FINDING clock-fault-copy: both faults render the SAME body' \
    '08-03 04:45:00.001  1234  1300 I flutter : [b8] ALL_PHASES_COMPLETE findings=1 evidence=2' \
    > "${tmp}/reverted-copy.log"
  got="$(missing_ok_markers "${tmp}/reverted-copy.log" | tr '\n' ',')"
  if [[ "${got}" != "surface-distinct," ]]; then
    echo "SELF-TEST FAIL (16d): collapsing the two fault bodies must be" \
         "reported as missing exactly 'surface-distinct,', got '${got}'" >&2
    fail=1
  fi

  # (16e) A prefix must not satisfy a longer name, and a FINDING that quotes a
  #       marker name in its prose must not satisfy it either. Both are ways a
  #       naive substring grep turns a red run green.
  printf '%s\n' \
    '08-03 04:43:36.001  1234  1300 I flutter : [b8] OK surface-behind-partial' \
    '08-03 04:43:37.001  1234  1300 I flutter : [b8] FINDING clock-fault-copy: surface-distinct did not hold' \
    > "${tmp}/lookalike.log"
  if has_ok_marker "${tmp}/lookalike.log" 'surface-distinct'; then
    echo "SELF-TEST FAIL (16e): a FINDING quoting a marker name satisfied it" >&2
    fail=1
  fi
  if ! has_ok_marker "${tmp}/lookalike.log" 'surface-behind-partial'; then
    echo "SELF-TEST FAIL (16f): the boundary match rejects a legitimate" \
         "end-of-line marker, so fixture 16e proved nothing" >&2
    fail=1
  fi

  # --- (17) FAIL CLOSED on a log that says nothing. -------------------------
  #
  # A drive that never started, a logcat capture that never attached, or a
  # marker rename all produce a log with no OK lines at all. That must read as
  # "every oracle missing", never as "nothing wrong here".
  local expected_all
  expected_all="$(required_ok_markers | tr '\n' ',')"
  got="$(missing_ok_markers "${tmp}/empty.log" | tr '\n' ',')"
  if [[ "${got}" != "${expected_all}" ]]; then
    echo "SELF-TEST FAIL (17): an EMPTY log must report every oracle missing" \
         "('${expected_all}'), got '${got}'" >&2
    fail=1
  fi
  got="$(missing_ok_markers "${tmp}/does-not-exist.log" | tr '\n' ',')"
  if [[ "${got}" != "${expected_all}" ]]; then
    echo "SELF-TEST FAIL (17b): a MISSING log must report every oracle" \
         "missing, got '${got}'" >&2
    fail=1
  fi

  if (( fail != 0 )); then
    echo "run-b8-clock-skew.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-b8-clock-skew.sh --self-test: all 17 fixture groups passed"
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
readonly LOG_DIR="/tmp/b8-logs"
readonly APK="${1:-/tmp/integration-apks/b8_clock_skew_test.apk}"
readonly TARGET="${2:-integration_test/b8_clock_skew_test.dart}"

# The drive owns the whole timeline: a 3-member circle setup, seven publishes
# (four measured, one through the production publish path, two peer samples),
# four catch-up sweeps, two banner pumps, and four clock rendezvous (each
# bounded at 150 s inside the drive). Its own in-test Timeout is 17 min; this
# is the outer per-drive bound and stays ABOVE it and BELOW the workflow's step
# deadline, so the attributable message ("flutter drive ... exceeded") is
# reachable (backlog A8 / guard C4) and an in-test overrun fails with a named
# test rather than an anonymous kill.
readonly DRIVE_TIMEOUT="${B8_DRIVE_TIMEOUT:-20m}"

# How often the servo re-reads logcat for a new request.
readonly SERVO_POLL_SECS="${B8_SERVO_POLL_SECS:-1}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
SERVO_PID=""

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b8.log"
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
# clock), and this repo has been bitten before by trusting an exit code over
# an authoritative read (`pm grant` — CI_HARDENING_BACKLOG.md). So the servo
# records `expected`, `device` and `drift`, and the oracle keys on `status=ok`,
# which only an in-tolerance read-back produces.
apply_clock_offset() {
  local seq="$1" offset="$2"
  local host_now expected stamp device drift status

  host_now="$(date -u +%s)"
  expected=$(( host_now + offset ))
  # toybox `date` takes the SET value positionally as MMDDhhmm[[CC]YY][.ss];
  # it has no coreutils `-s`. Rendered on the host so the format is produced
  # by a parser we can self-test (fixture group 12).
  stamp="$(date -u -d "@${expected}" +%m%d%H%M%Y.%S)"

  status="ok"
  if ! adb -s "${DEVICE}" shell "date -u ${stamp}" >/dev/null 2>&1; then
    status="error"
  fi
  # Tell the framework the wall clock moved. Harmless if nothing listens; a
  # few services cache "now" and would otherwise keep the old value.
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
  # non-zero status, and this function runs inside the background servo — the
  # short-circuit form would silently kill the servo on every non-negative
  # drift, i.e. on every healthy jump.
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

# Re-enables the automatic time sync phase 0 pinned off.
#
# Best-effort by design (`|| true`): this runs from the EXIT trap, which is also
# reached when the device was never ready, and a restore that killed the trap
# would skip the secret scan below it (Security Rule 6). Idempotent — 1 is the
# stock value on every AVD this repo boots — so it is safe on the paths where no
# pin was ever applied.
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
  local handled=" " seq offset
  local -a pending
  while [[ ! -f "${SERVO_STOP}" ]]; do
    # Snapshot into an ARRAY rather than iterating a `read` loop fed by a
    # process substitution. `apply_clock_offset` shells out to `adb shell`,
    # which reads stdin — inside a read loop it would swallow the rest of the
    # request list and the servo would silently fulfil only the first jump.
    pending=()
    mapfile -t pending < <(req_clock_seqs "${LOGCAT_FILE}")
    for seq in "${pending[@]}"; do
      [[ -z "${seq}" ]] && continue
      [[ "${handled}" == *" ${seq} "* ]] && continue
      offset="$(req_clock_offset "${LOGCAT_FILE}" "${seq}")"
      if [[ -z "${offset}" ]]; then
        continue
      fi
      handled+="${seq} "
      apply_clock_offset "${seq}" "${offset}" </dev/null
    done
    sleep "${SERVO_POLL_SECS}"
  done
}

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the helpers, RESTORE the device clock AND the
# automatic-time pin phase 0 disabled, run the MANDATORY secret scan over every
# captured log (Security Rule 6 — must run even on a phase failure), snapshot +
# tear down strfry.
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
  # workflow's `if: failure()` diagnostics step, the artifact upload and any
  # later lane on the same runner all assume a sane clock; leaving it 6 h off
  # would turn this lane's failure into someone else's mystery.
  if [[ -n "${SERVO_PID}" ]]; then
    apply_clock_offset "restore" 0 || true
  fi
  # …and un-pin the automatic sync phase 0 disabled. NOT gated on SERVO_PID:
  # the pin is applied in phase 0, long before the servo exists, and phase 0's
  # own `fail` paths exit through here. Restoring the VALUE while leaving
  # `auto_time 0` in place would still hand the next lane an AVD that can never
  # re-synchronise its clock — and the AVD image is shared through one
  # actions/cache key across every Android lane in this repo.
  restore_auto_time_pin
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  docker logs strfry > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  rm -f "${SERVO_STOP}" 2>/dev/null || true
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  bash "${SECRET_SCAN}" "${LOG_DIR}" || scan_rc=$?
  if (( scan_rc == 1 )); then
    # CONTAINMENT, not just detection. The workflow uploads ${LOG_DIR} with
    # `if: always()` and a 14-day retention, so merely going red here would
    # publish the leaking log for a fortnight. Destroy the logs and leave a
    # marker; the scanner has already printed file + label + line numbers
    # (never the matched content), which is all triage needs.
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    {
      echo "Logs withheld: the secret-leak guard tripped (Security Rule 6)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped on B8 logs — logs deleted, not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    # rc 3 = a log was absent / unreadable / EMPTY, i.e. this lane died before
    # it finished writing its evidence. Go red — a run that scanned nothing
    # has proved nothing — but do NOT take the containment branch: deletion
    # exists to stop a LEAK being published, and there is no leak here, only
    # the truncated crash artefacts triage needs most.
    echo "ERROR: secret-leak guard could not scan the B8 logs (rc=${scan_rc}) —" \
         "see the UNUSABLE line(s) above. Logs kept for triage." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "B8-LANE-FAIL: $*" >&2
  if (( ${drive_failed:-0} == 1 )); then
    echo "NOTE: the drive ALSO did not complete cleanly (${drive_reason:-unknown})." \
         "The finding above may be a CONSEQUENCE of that rather than a product" \
         "defect — rule the drive failure out first." >&2
  fi
  echo "---- [b8] lines seen ----" >&2
  grep -aoF -e "${MARK_REQ_CLOCK}" -e "${MARK_CLOCK_OBSERVED}" \
    -e "${MARK_CLOCK_TIMEOUT}" -e "${MARK_ALL_PHASES}" "${LOGCAT_FILE}" \
    2>/dev/null | tail -20 >&2 || true
  sed -n 's/.*\(\[b8\] \)/\1/p' "${LOGCAT_FILE}" 2>/dev/null | tail -40 >&2 \
    || echo "(none — the drive logged no [b8] lines at all)" >&2
  echo "---- clock servo records ----" >&2
  cat "${JUMP_LOG}" 2>/dev/null >&2 || echo "(no servo records)" >&2
  echo "---- device vs host clock right now ----" >&2
  echo "  host   $(date -u +%s)" >&2
  echo "  device $(adb -s "${DEVICE}" shell date -u +%s 2>/dev/null | tr -dc '0-9')" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Phase 0 — hermetic relay + device readiness + a WRITABLE clock.
#
# `adb root` is required to set the clock and is available on the `google_apis`
# (userdebug) AVD every Android lane in this repo uses; it is NOT available on
# `google_apis_playstore` (user build). Failing here rather than limping on is
# deliberate: without a writable clock the whole lane is vacuous, and a vacuous
# green is the outcome this backlog exists to prevent.
# ---------------------------------------------------------------------------
echo "Phase 0/5 — starting hermetic strfry..."
bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device

echo "Phase 0/5 — acquiring root and disabling automatic time..."
adb -s "${DEVICE}" root >/dev/null 2>&1 || true
# `adb root` restarts adbd; without this the next command races the restart.
adb -s "${DEVICE}" wait-for-device
if ! adb -s "${DEVICE}" shell id 2>/dev/null | grep -q 'uid=0'; then
  fail "adb shell is not running as root, so the device clock cannot be set. \
This lane needs a userdebug image (target: google_apis). Without a writable clock every \
phase below runs at true time and a GREEN result would prove nothing."
fi
# NITZ / NTP would silently undo every jump. Turn both off BEFORE the first
# one, and verify: `settings put` exits 0 whether or not it took effect.
adb -s "${DEVICE}" shell settings put global auto_time 0 >/dev/null 2>&1 || true
adb -s "${DEVICE}" shell settings put global auto_time_zone 0 >/dev/null 2>&1 || true
auto_time="$(adb -s "${DEVICE}" shell settings get global auto_time 2>/dev/null | tr -dc '0-9')"
if [[ "${auto_time}" != "0" ]]; then
  fail "could not disable global auto_time (reads '${auto_time:-<empty>}'). Android \
would re-synchronise the clock from the network mid-run and silently undo every jump, \
which turns the whole lane vacuous."
fi
echo "Phase 0/5 — device ready, clock is writable and pinned."

# ---------------------------------------------------------------------------
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky state
# from a prior target survives into this run.
#
# No runtime permissions are granted, deliberately: this target drives the FFI
# and the relay directly and never touches the platform location plugin, so a
# grant here would be decoration. B3 is the lane that needs (and verifies) it.
# ---------------------------------------------------------------------------
echo "Phase 1/5 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — start the capture and the clock servo.
#
# The servo must be running BEFORE the drive, or the first request could be
# emitted into a log nobody is watching and the drive would time out on a jump
# that was never going to come.
# ---------------------------------------------------------------------------
echo "Phase 2/5 — capturing logcat and arming the clock servo..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!
: > "${JUMP_LOG}"
rm -f "${SERVO_STOP}"
# `trap - EXIT` inside the subshell: a background job can inherit the EXIT
# trap, and this one exits normally when the drive finishes. Without the
# disarm the servo's own exit would run `cleanup` — tearing down strfry and
# scanning half-written logs while the oracle still needs both.
( trap - EXIT; clock_servo ) &
SERVO_PID=$!

# ---------------------------------------------------------------------------
# Phase 3 — drive the target. Everything the oracle reads happens inside.
# ---------------------------------------------------------------------------
echo "Phase 3/5 — driving ${TARGET}..."
drc=0
( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}" ) > "${DRIVE_LOG}" 2>&1 || drc=$?

touch "${SERVO_STOP}"

# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect this:
# GitHub Actions step logs have no retention control and cannot be redacted
# after the fact, so an unscanned `cat` of the drive log is a wider and more
# permanent sink than the artifact upload the trap does guard.
drive_log_clean=1
if bash "${SECRET_SCAN}" "${DRIVE_LOG}"; then
  cat "${DRIVE_LOG}" || true
else
  drive_log_clean=0
  echo "drive log withheld from the step log — secret-leak guard tripped." >&2
fi

# Record the drive's verdict WITHOUT exiting on it yet: the oracle's logcat
# findings are this lane's deliverable and stay valid as long as check 1
# confirms the body ran to the end. Re-raised at the foot of the file so a bad
# drive still fails the lane.
#
# `drc == 0` alone is not trustworthy: `flutter drive` exits 0 when the
# failure happened outside a `testWidgets` body (drive-log-lib.sh).
drive_failed=0
drive_reason=""
if (( drc != 0 )); then
  drive_failed=1
  drive_reason="flutter drive exited ${drc}"
elif drive_log_reports_test_failure "${DRIVE_LOG}"; then
  drive_failed=1
  drive_reason="flutter drive exited 0 but the on-device suite reported failures"
fi
if (( drive_failed == 1 )); then
  echo "WARN: ${drive_reason} for ${TARGET}. Continuing to the oracle anyway —" \
       "its logcat findings are this lane's deliverable. Re-raised as a failure" \
       "at the end regardless of the oracle's verdict." >&2
  # Gated on the SAME containment decision as above: echoing raw drive-log
  # lines after the guard tripped would defeat the withholding by the back
  # door, into a step log that cannot be redacted afterwards.
  if (( drive_log_clean == 1 )); then
    drive_log_failure_evidence "${DRIVE_LOG}" >&2
  else
    echo "  (evidence withheld — secret-leak guard tripped on this log)" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Phase 4 — restore the clock before reading anything.
# ---------------------------------------------------------------------------
echo "Phase 4/5 — restoring the device clock..."
apply_clock_offset "final" 0

# ---------------------------------------------------------------------------
# Phase 5 — the oracle. Reads over a complete capture, not live polls.
# ---------------------------------------------------------------------------
echo "Phase 5/5 — asserting clock-skew behaviour..."

# (1) The body ran to the end. Every negative below is only meaningful against
#     a run that reached phase 4 of the drive; a truncated one is silent about
#     the phases it never executed.
if ! grep -aqF -- "${MARK_ALL_PHASES}" "${LOGCAT_FILE}" 2>/dev/null; then
  fail "the drive never printed '${MARK_ALL_PHASES}', so it died before completing its \
four phases. Nothing below can be read as a product verdict — the absent phases simply \
did not run. Check the drive log above for the throw."
fi
echo "  [1/6] Drive ran all five phases to completion."

# (2) THE ANTI-VACUITY CHECK. Every requested jump must have LANDED on the
#     device, proven by an adb read-back, not by an exit code.
#
#     Without this the lane has a live false-green path: if `date` silently
#     no-ops (auto_time re-enabled, a read-only clock, a lost root shell) then
#     every drive phase runs at TRUE time, every oracle in the drive passes,
#     and the lane goes green having tested nothing. That is the exact shape
#     of failure this backlog keeps finding.
requested="$(req_clock_seqs "${LOGCAT_FILE}")"
if [[ -z "${requested}" ]]; then
  fail "the drive requested no clock jumps at all (no '${MARK_REQ_CLOCK}' lines). Either \
the marker literals drifted apart from b8_clock_skew_test.dart, or the body never reached \
its first jump — either way NO SKEW WAS EVER APPLIED and this run proves nothing."
fi
applied="$(jump_ok_seqs "${JUMP_LOG}")"
missing=""
for seq in ${requested}; do
  # shellcheck disable=SC2086  # deliberate word-split of a newline-separated list
  if ! printf '%s\n' ${applied} | grep -qx -- "${seq}"; then
    record="$(jump_record "${JUMP_LOG}" "${seq}")"
    missing+="    seq ${seq}: ${record:-(no servo record at all — the request was never fulfilled)}"$'\n'
  fi
done
if [[ -n "${missing}" ]]; then
  fail "the clock servo did not land every requested jump, so part of this run executed \
at TRUE time while the drive believed it was skewed. HARNESS failure, not a product \
finding — do not read the drive's verdicts below it. Unfulfilled:
${missing}"
fi
echo "  [2/6] All $(printf '%s\n' ${requested} | wc -l | tr -d ' ') requested jump(s) \
landed on the device (adb read-back within ${JUMP_DRIFT_TOLERANCE_SECS}s)."

# (3) …and the APP PROCESS saw them. Separate from (2) on purpose: a jump the
#     servo made but the process never observed would mean the skew never
#     reached the code under test, which is a different failure with a
#     different fix.
if grep -aqF -- "${MARK_CLOCK_TIMEOUT}" "${LOGCAT_FILE}" 2>/dev/null; then
  fail "the drive reported '${MARK_CLOCK_TIMEOUT}': it waited for a jump it never \
observed on its own wall clock, even though the servo recorded applying it. HARNESS \
failure — the process is not seeing CLOCK_REALTIME move."
fi
observed="$(observed_clock_seqs "${LOGCAT_FILE}")"
for seq in ${requested}; do
  # shellcheck disable=SC2086  # deliberate word-split of a newline-separated list
  if ! printf '%s\n' ${observed} | grep -qx -- "${seq}"; then
    fail "the drive never observed jump seq ${seq} on its own clock (servo record: \
$(jump_record "${JUMP_LOG}" "${seq}")). The skew did not reach the process under test."
  fi
done
echo "  [3/6] Every jump was observed inside the app process."

# The RECORDED EVIDENCE. Printed before the verdict, on every run, green or
# red: it is this lane's standing measurement of what a +/-6h jump still costs
# a device, and it is deliberately not a gate (see the header).
evidence="$(evidence_lines "${LOGCAT_FILE}")"
if [[ -n "${evidence}" ]]; then
  echo "---- recorded evidence (measured, NOT gating) ----"
  printf '%s\n' "${evidence}"
  echo "---- end evidence ----"
else
  echo "  (no evidence lines recorded this run)"
fi

# (4) EVERY gating oracle ran and held. A positive check on purpose: an
#     oracle that was deleted, renamed, or never reached leaves no FINDING
#     either, so check 5 alone would read a gutted drive as a clean one.
missing_ok="$(missing_ok_markers "${LOGCAT_FILE}")"
if [[ -n "${missing_ok}" ]]; then
  echo "---- gating oracles with no OK line ----" >&2
  printf '  %s\n' ${missing_ok} >&2
  fail "the drive did not report every gating oracle as held. Each name above is a \
device-clock DETECTION property that either regressed or was never evaluated: a fast \
clock's refusal must reach Dart classified rather than collapsed, a corroborated slow \
clock must raise a verdict a single peer cannot, and each fault must reach the user in \
its own words. If a name is missing with no matching FINDING, the oracle never ran at \
all — check the drive log for a throw, and check that the marker literals still agree \
between b8_clock_skew_test.dart and this script."
fi
echo "  [4/6] All $(required_ok_markers | wc -l | tr -d ' ') gating oracles reported \
held."

# (5) …and nothing was recorded as broken.
findings="$(finding_lines "${LOGCAT_FILE}")"
if [[ -n "${findings}" ]]; then
  echo "---- clock-skew findings ----" >&2
  printf '%s\n' "${findings}" >&2
  fail "a device-clock fault stopped being detected or surfaced. Each FINDING above \
names one property of the clock-skew detection that regressed. NOTE these are not the \
lane's delivery measurements — those are printed above as EVIDENCE and are not gated, \
because closing them needs clock correction, which is deferred."
fi
echo "  [5/6] No detection findings recorded."

# (6) The drive's own verdict, re-raised last so the oracle's attribution is
#     printed first.
if (( drive_failed == 1 )); then
  fail "the oracle passed, but ${drive_reason}. Treat the lane as RED until that is \
fixed: a drive that dies early can truncate the very window the oracle measures."
fi
echo "  [6/6] Drive completed cleanly."

echo "B8 PASS — across $(printf '%s\n' ${requested} | wc -l | tr -d ' ') device clock \
jump(s) of +/-6h, both fault directions were detected, corroborated where corroboration \
is required, and surfaced to the user in their own distinct words."
