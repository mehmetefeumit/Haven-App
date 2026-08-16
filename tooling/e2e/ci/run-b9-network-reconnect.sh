#!/usr/bin/env bash
#
# B9 network-loss/reconnect lane orchestrator —
# docs/CI_HARDENING_BACKLOG.md Workstream B, item B9: "Network loss/reconnect
# | `adb emu network disable/enable`".
#
# # THE ITEM'S MECHANISM DOES NOT EXIST
#
# There is no `network disable` / `network enable` in the Android emulator
# console. The console's `network` command takes exactly four subcommands —
# `status`, `speed`, `delay`, `capture` — confirmed by reading the help
# strings compiled into the shipped `qemu-system-x86_64` binary. The only
# connectivity kill switch the console offers is `gsm data <state>`, which
# reaches the CELLULAR path only, while an API-34 `google_apis` AVD routes
# over its emulated Wi-Fi, so `gsm data off` on its own is close to a no-op.
#
# This lane therefore drops the network with two layers, and does NOT trust
# either one:
#
#   L1 (the lane's subject) `cmd connectivity airplane-mode enable`, VERIFIED
#      through `settings get global airplane_mode_on`. This is genuine,
#      device-wide network loss across every transport — the thing item B9
#      names. The read-back is a HARD gate: a lane that silently degraded to
#      L2 alone would still be called "network loss" while testing only relay
#      unreachability.
#   L2 (immediacy)          an iptables REJECT of the strfry port on the
#      RUNNER HOST, in a dedicated `HAVEN_B9_OUTAGE` chain. The emulator uses
#      QEMU SLIRP userspace networking, so guest TCP is proxied through host
#      sockets and IS subject to the host OUTPUT chain (the same empirical
#      property `setup-network-guard.sh` documents and relies on). This turns
#      a blackout that Android might otherwise leave to a 55 s WebSocket
#      `PING_INTERVAL` into an immediate RST. Best-effort: skipped with a
#      warning where sudo/iptables are unavailable.
#
# The AUTHORITY on whether an outage happened is neither of them: the drive
# target probes the relay over a real WebSocket from inside the app process
# and prints `[b9] OUTAGE_OBSERVED` / `[b9] OUTAGE_NOT_OBSERVED`. That probe
# validates itself — it must succeed before the drop and after the restore —
# so it cannot rot into an always-fails oracle that reports a permanent
# outage.
#
# # What this lane proves that no other lane does
#
# Nothing in CI has ever disconnected a running Haven from the network. The
# live-sync engine's recovery story has three independent mechanisms and all
# three were unexercised at runtime:
#
#   1. the relay pool's own reconnect + `resubscribe()` replay of the stored
#      filters (nostr-relay-pool: 10 s retry adapting to 60 s);
#   2. Haven's M8 subscription-health tick re-anchoring at the persisted
#      cursor when a relay is `Disconnected` (+90 s, then every 15 min);
#   3. `MapShell._healLiveSyncIfStopped` -> `LiveSyncResubscriber
#      .ensureRunning()`, the ONLY thing that restarts an engine that
#      `NostrSubscriptionService._onStreamClosed` tore down, on a jittered
#      90-150 s timer that doubles per consecutive failure.
#
# (3) landed precisely because nothing restarted a dead engine. A network
# drop is its realistic trigger, and this lane is its runtime proof.
#
# # The BACKLOG import — the one publisher that survives the blackout
#
# A reconnect proof is only half the story: the other half is whether an
# event a PEER put on the relay WHILE THE RECEIVER WAS PARTITIONED is
# replayed and decrypted afterwards. Bob and Alice share one emulator, so
# Bob cannot publish across the outage — but he can ENCRYPT across it
# (purely local MLS work), and the host can put the result on the relay for
# him.
#
# So, inside the blackout and in this order:
#
#   1. the drive encrypts Bob's backlog kind-445, writes it to the app's
#      private data dir, re-probes the relay to confirm it is STILL
#      unreachable, and prints `[b9] BACKLOG_STAGED offline=true path=…`;
#   2. this script reads the file with `adb exec-out run-as` — adb rides the
#      emulator's control channel, not the guest IP stack, so airplane mode
#      does not touch it — and imports it with `strfry import` INSIDE the
#      relay container;
#   3. only then is connectivity restored.
#
# The ordering is enforced by this script's control flow, never by comparing
# a guest clock to a host clock.
#
# A host-side WebSocket publisher was rejected twice over. The host cannot
# mint a genuine kind-445 (that needs the circle's MLS exporter secret, which
# must never leave the device), and layer L2 REJECTs tcp/<strfry> in the host
# OUTPUT chain, which applies to locally-generated packets too — during the
# blackout the host cannot reach the relay's published port either. A writer
# inside the container is the only one that survives, and `strfry import` is
# that writer.
#
# ## The route held; its FRAMING was wrong (CI run 31868809387, resolved)
#
# The first real run failed at `stage=postscan` — the one outcome recorded in
# advance as the load-bearing unknown, on the theory that an external writer's
# LMDB commit might be invisible to the running daemon, which would have forced
# the route to change to a WebSocket client inside the container's namespace.
# It was not that. strfry's own log said so and was read: `Unable to parse JSON
# on line 1`, `Processed 0 lines`, exit 0. `strfry import` reads NDJSON and
# needs every event NEWLINE-TERMINATED; the staged file is
# `serde_json::to_string` written by Dart's `writeAsString`, and neither
# appends one.
#
# Verified against the pinned image rather than argued: the same bytes plus one
# `\n` import cleanly, and a live `REQ` on the RUNNING daemon's websocket
# serves the event an external `strfry import` process wrote. Multi-process
# LMDB visibility is therefore not a problem this lane has, and the WS-client
# replacement is NOT needed. `b9_ndjson_payload` supplies the framing and
# `b9_import_counts` reads strfry's own accounting, so an import that writes
# nothing now names WHICH way it failed instead of leaving the post-scan to
# report only that it did.
#
# # The oracle
#
#   1. SEQUENCE_COMPLETE                the drive finished (checked FIRST, so
#                                       later absences are not misread as
#                                       product defects)
#   2. BASELINE_RECEIVED ms=<N>         live receive worked BEFORE the drop
#   3. ENGINE_BASELINE running=true     anti-vacuity: something was connected
#   4. OUTAGE_OBSERVED                  the drop reached the app process
#   5. NETWORK_RESTORED                 connectivity came back
#   6. BACKLOG_STAGED offline=true      + [b9-host] BACKLOG_IMPORTED
#      airplane_before/after=1 prescan=0 postscan=1, + BACKLOG_ON_RELAY
#      served=true                      the event really did reach the relay
#                                       DURING a real partition, and the
#                                       RUNNING relay really does serve it
#   7. PEER_PUBLISHED_POST_OUTAGE       something was sent to receive
#   8. RECEIVE_RESUMED ms=<N>           a PEER event decrypted after the
#                                       reconnect
#   9. BACKLOG_REPLAYED ms=<N>          THE HEADLINE: the event imported
#                                       while the device was in airplane mode
#                                       was decrypted after the reconnect
#
# Steps 8 and 9 are the point. A socket that reopened proves nothing a user
# cares about, so the drive asserts on DECRYPTED COORDINATES reaching
# `memberLocationsProvider` — the pre-outage entry survives the blackout, so
# a presence check would pass on an app whose receive path never came back.
# The two use different SENDERS (Bob backlogs, Carol publishes live) because
# the cache keeps one latest entry per sender and a post-restore event from
# Bob would overwrite his own backlog entry before a poll could see it.
#
# Steps 2, 3, 4, 6 and 7 all exist to stop 8 and 9 passing or failing
# vacuously: without a baseline, "it did not arrive" is unattributable;
# without a running engine there was no subscription to drop; without an
# observed outage nothing was disconnected; without step 6 the "backlog" was
# never on the relay, or was never out of the device's reach, or was put
# there by the device itself; and without a published peer event there was
# nothing to receive.
#
# # What one emulator still cannot prove, stated so nobody over-reads a green
#
# Bob's process is Alice's process. This proves that an event which reached
# the relay while the receiver was partitioned is replayed and decrypted
# after reconnect. It does NOT prove a second physical device kept publishing
# across the blackout, and it cannot: the publisher and the receiver share
# one network stack. Everything except the transport of that one event is
# real — genuine MLS ciphertext from the production FFI, signed, and accepted
# by strfry's ordinary ingest validation.
#
# Separately, `BACKLOG_MISSED reason=expired` is a run on which the backlog
# claim went UNPROVEN rather than one on which it passed: see step (9) in
# b9_run_oracle for why that is not scored as a defect and why it cannot be
# reached by an import that quietly did nothing.
#
# Usage:
#   run-b9-network-reconnect.sh [<apk> [<target.dart>]]
#   run-b9-network-reconnect.sh --self-test   # hermetic, no device
#
# Optional env:
#   B9_DRIVE_TIMEOUT        per-drive bound. Default 20m.
#   B9_STRFRY_PORT          host port strfry is published on. Default 7777.
#   B9_SKIP_HOST_BLOCK      set to 1 to skip layer L2 (local dev).
#   STRFRY_CONTAINER        relay container name. Default 'strfry'.

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# Shared app-side failure predicate — `flutter drive` can exit 0 on a failed
# suite (drive-log-lib.sh). Sourced before the --self-test dispatch so the
# hermetic self-test runs against a fully-wired script.
# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "${SCRIPT_DIR}/drive-log-lib.sh"

# Shared `detect_strfry_bin`. The candidate path list is a property of the
# pinned relay IMAGE, not of this lane, and B5 probes the same one — sourced
# rather than copied so the two cannot drift.
# shellcheck source=tooling/e2e/ci/strfry-lib.sh
source "${SCRIPT_DIR}/strfry-lib.sh"

# ---------------------------------------------------------------------------
# VERBATIM markers. MUST match the `k*Marker` constants in
# haven/integration_test/b9_network_reconnect_test.dart — change both
# together or the lane silently stops finding them.
#
# Fixed literals matched with `grep -aF`: logcat is binary-tainted and these
# strings contain regex metacharacters.
#
# Every negative twin is a DISTINCT string rather than a suffix of its
# positive, so a substring match can never read one as the other
# (`NETWORK_RESTORED` is not a substring of `NETWORK_NOT_RESTORED`).
# ---------------------------------------------------------------------------
readonly MARK_ARMED='[b9] ARMED'
readonly MARK_BASELINE='[b9] BASELINE_RECEIVED'
readonly MARK_BASELINE_DEAD='[b9] BASELINE_DEAD'
readonly MARK_ENGINE_BASE='[b9] ENGINE_BASELINE'
readonly MARK_AWAIT_DOWN='[b9] AWAITING_NETWORK_DOWN'
readonly MARK_OUTAGE='[b9] OUTAGE_OBSERVED'
readonly MARK_NO_OUTAGE='[b9] OUTAGE_NOT_OBSERVED'
readonly MARK_ENGINE_OUTAGE='[b9] ENGINE_DURING_OUTAGE'
readonly MARK_AWAIT_UP='[b9] AWAITING_NETWORK_UP'
readonly MARK_RESTORED='[b9] NETWORK_RESTORED'
readonly MARK_NOT_RESTORED='[b9] NETWORK_NOT_RESTORED'
readonly MARK_PEER_PUB='[b9] PEER_PUBLISHED_POST_OUTAGE'
readonly MARK_PEER_PUB_FAIL='[b9] PEER_PUBLISH_FAILED'
readonly MARK_RESUMED='[b9] RECEIVE_RESUMED'
readonly MARK_RECEIVE_DEAD='[b9] RECEIVE_DEAD'
readonly MARK_ENGINE_RECOVERED='[b9] ENGINE_AFTER_RECOVERY'
readonly MARK_BACKLOG_STAGED='[b9] BACKLOG_STAGED'
readonly MARK_BACKLOG_STAGE_FAIL='[b9] BACKLOG_STAGE_FAILED'
readonly MARK_BACKLOG_ON_RELAY='[b9] BACKLOG_ON_RELAY'
readonly MARK_BACKLOG_REPLAYED='[b9] BACKLOG_REPLAYED'
readonly MARK_BACKLOG_MISSED='[b9] BACKLOG_MISSED'
readonly MARK_COMPLETE='[b9] SEQUENCE_COMPLETE'

# HOST-side markers, written by THIS script to its own log rather than by the
# drive. They record facts only the host can know — that the import ran while
# the guest was in airplane mode, and that the relay's store changed because
# of it — and the oracle reads them alongside the drive's capture.
readonly MARK_HOST_IMPORTED='[b9-host] BACKLOG_IMPORTED'
readonly MARK_HOST_IMPORT_FAIL='[b9-host] BACKLOG_IMPORT_FAILED'

# Declared HERE rather than in the Config block below because the hermetic
# --self-test needs it too: the device path the drive prints is anchored to
# this package, and a self-test with its own copy of the string would keep
# passing after a rename that broke the real export.
readonly PKG="com.oblivioustech.haven"

# ---------------------------------------------------------------------------
# Oracle predicates — pure text, no device. Everything the lane's verdict
# rests on lives here so `--self-test` can exercise it hermetically.
# ---------------------------------------------------------------------------

# b9_has_marker <logfile> <marker> — 0 (true) when the marker appears.
#
# Substring match, not anchored: the same line reaches us either as raw
# `debugPrint` output in the drive log or wrapped by logcat's
# `I/flutter ( 1234): ` prefix, and both must count.
b9_has_marker() {
  local logfile="${1:-}" marker="${2:-}"
  [[ -f "${logfile}" ]] || return 1
  grep -aqF -- "${marker}" "${logfile}"
}

# b9_marker_number <logfile> <marker> <key> — echoes the LARGEST integer
# following `<key>=` on any line carrying <marker>, or nothing.
#
# PARSED, never grepped for presence: the numbers here are evidence
# (recovery latency, re-publish count) and a `sort -n` is required because
# '9' outranks '12' lexically.
b9_marker_number() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[0-9]+" \
      | grep -aoE '[0-9]+' | sort -n | tail -1; } || true
}

# b9_marker_flag <logfile> <marker> <key> — echoes the LAST `<key>=<word>`
# value on any line carrying <marker>, or nothing.
#
# Used for the `running=true|false` engine readings, where the VALUE is the
# verdict and the marker's presence means only that the drive got there.
b9_marker_flag() {
  local logfile="${1:-}" marker="${2:-}" key="${3:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE "${key}=[A-Za-z0-9_.-]+" \
      | sed "s/^${key}=//" | tail -1 | tr -d '\r'; } || true
}

# b9_marker_path <logfile> <marker> — echoes the LAST `path=<value>` on any
# line carrying <marker>.
#
# Separate from b9_marker_flag because that helper's value charset
# deliberately excludes `/`: reusing it here would silently truncate
# `/data/user/0/...` to the empty string and the lane would report "the drive
# printed no path" for a drive that printed a perfectly good one.
b9_marker_path() {
  local logfile="${1:-}" marker="${2:-}"
  [[ -f "${logfile}" ]] || return 0
  { grep -aF -- "${marker}" "${logfile}" 2>/dev/null \
      | grep -aoE 'path=[A-Za-z0-9._/-]+' \
      | sed 's/^path=//' | tail -1 | tr -d '\r'; } || true
}

# b9_event_id <file> — echoes the 64-hex `id` of the Nostr event in <file>.
#
# Anchored on the `"id"` KEY, never on the shape: a kind-445 carries a 64-hex
# `pubkey` and a 128-hex `sig` too, and a bare hex match would return
# whichever came first in the serialization.
b9_event_id() {
  local f="${1:-}"
  [[ -f "${f}" ]] || return 0
  { grep -aoE '"id"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' "${f}" 2>/dev/null \
      | grep -aoE '[0-9a-f]{64}' | head -1; } || true
}

# b9_ndjson_payload <file> — echoes the ONE JSON line in <file>, or nothing
# when <file> does not hold exactly one.
#
# THE DEFECT THIS EXISTS FOR (CI run 31868809387). `strfry import` reads NDJSON
# and needs every event NEWLINE-TERMINATED. The drive stages the event with
# Dart's `writeAsString` over `serde_json::to_string`, and neither appends one,
# so the export was a single unterminated line: strfry logged `Unable to parse
# JSON on line 1`, `Processed 0 lines`, and EXITED 0 — the silent no-op the
# post-scan then caught with no way to say why. Reproduced against the pinned
# image: identical bytes plus one `\n` import cleanly and are served over a
# live REQ, so the route was sound and only its framing was wrong.
#
# `tr -d '\r'` cannot corrupt the event: serde_json escapes control characters,
# so a raw CR byte is never part of a serialized event and can only come from a
# transport that mangled it (`adb shell`'s LF->CRLF, which is why the export
# uses `exec-out`). `$(…)` strips every trailing newline; the caller puts back
# exactly one.
#
# An interior newline is REFUSED rather than joined or partially imported: a
# pretty-printed or multi-event file is not the single event this lane's whole
# claim is about, and importing its first line would put an unrelated — or
# truncated — event on the relay under the backlog event's name.
b9_ndjson_payload() {
  local f="${1:-}" payload
  [[ -f "${f}" ]] || return 0
  payload="$(tr -d '\r' < "${f}")" || return 0
  [[ -n "${payload}" ]] || return 0
  [[ "${payload}" != *$'\n'* ]] || return 0
  printf '%s' "${payload}"
}

# b9_import_counts <file> — echoes "<processed> <added> <rejected>" read off
# `strfry import`'s own summary line in <file>, or nothing when it printed none.
#
# The exit status is NOT evidence that anything was written: strfry exits 0
# after discarding a line it could not parse. Its accounting is, and it also
# separates the two ways an import can write nothing — `processed=0` is a
# malformed payload, `rejected>0` is strfry's ingest validation refusing the
# event itself (a bad signature, an out-of-window `created_at`).
b9_import_counts() {
  local f="${1:-}" line
  [[ -f "${f}" ]] || return 0
  line="$(grep -aoE 'Done\. Processed [0-9]+ lines\. [0-9]+ added, [0-9]+ rejected' \
          "${f}" 2>/dev/null | tail -1)" || true
  [[ -n "${line}" ]] || return 0
  grep -aoE '[0-9]+' <<<"${line}" | tr '\n' ' ' | sed 's/ $//'
}

# b9_prune_empty_export_stderr <path> — delete <path> when it is 0 bytes.
#
# THE LANE-CANNOT-BE-GREEN GUARD. `adb exec-out run-as … cat 2>FILE` creates
# FILE at redirection time, so a SUCCESSFUL export leaves it empty — and the
# mandatory secret scan treats a 0-byte `*.log` as UNUSABLE (rc=3), which
# `cleanup` turns into rc=1. Keeping it would make B9 red on exactly the runs
# where everything worked, which is what the relay-poll log did to B5 in CI
# runs 30925179141 and 30964250098.
#
# Deliberately narrow: ONLY this capture is legitimately empty on a healthy
# run. Every other file the lane writes (logcat, the drive log, the toggle
# log, the host import record, the exported event) is non-empty whenever its
# phase ran, so an empty one there IS the evidence the scanner says it is and
# must never be pruned. A non-empty stderr is kept — it is the diagnosis for a
# refused `run-as`.
#
# Extracted above the `--self-test` dispatch so the property is pinned by a
# fixture; it belongs to `cleanup`, which no fixture can reach.
b9_prune_empty_export_stderr() {
  local f="${1:-}"
  [[ -e "${f}" ]] || return 0
  [[ -s "${f}" ]] || rm -f -- "${f}"
}

# b9_device_path_ok <path> <package> — 0 when <path> is a file inside
# <package>'s own private data dir.
#
# The path comes out of a log line, and it is about to become an argument to
# `adb exec-out run-as`. Constraining it to the app's own data dir keeps a
# corrupted capture from pointing the export at something else, and rejecting
# `..` keeps the anchor from being walked out of.
b9_device_path_ok() {
  local p="${1:-}" pkg="${2:-}" pkg_re
  [[ -n "${pkg}" ]] || return 1
  [[ "${p}" != *".."* ]] || return 1
  pkg_re="${pkg//./\\.}"
  [[ "${p}" =~ ^/data/(data|user/0)/${pkg_re}/[A-Za-z0-9._/-]+$ ]]
}

# ---------------------------------------------------------------------------
# The oracle itself, as a testable function over a capture file.
#
# Findings accumulate rather than exiting on the first one: the lane's value
# is the WHOLE picture (was it live, did it really disconnect, did it come
# back, did a PEER EVENT arrive), and stopping early would hide the rest.
# Returns 1 when any finding was recorded. NOTES (never failures) go to
# stdout as evidence.
# ---------------------------------------------------------------------------
B9_FINDINGS=()

b9_note() { printf '  NOTE: %s\n' "$*"; }
b9_finding() { B9_FINDINGS+=("$*"); }

b9_run_oracle() {
  local log="${1:-}" hostlog="${2:-}"
  B9_FINDINGS=()

  if [[ ! -f "${log}" ]]; then
    b9_finding "no capture file at '${log}' — the lane recorded nothing."
    return 1
  fi

  # (1) The drive reached the end of its own sequence. Checked FIRST because
  #     every later "marker absent" finding would otherwise be reported as a
  #     product defect when the true cause is a drive that died early.
  if ! b9_has_marker "${log}" "${MARK_COMPLETE}"; then
    b9_finding "the drive never printed '${MARK_COMPLETE}' — it did not \
reach the end of its sequence, so every absent marker below may be a \
consequence of that rather than a product defect. Rule the drive out first."
  fi

  # (2) BASELINE — live receive worked BEFORE anything was broken.
  if b9_has_marker "${log}" "${MARK_BASELINE_DEAD}"; then
    b9_finding "the peer's BASELINE location never reached \
memberLocationsProvider ('${MARK_BASELINE_DEAD}'). Live receive was already \
broken BEFORE the network was touched, so nothing this lane observed \
afterwards can be attributed to the drop. Suspect the engine start, the \
staged-create confirm, or circle selection — not reconnect."
  elif ! b9_has_marker "${log}" "${MARK_BASELINE}"; then
    b9_finding "no '${MARK_BASELINE}' line — the drive never established \
that live receive worked before the outage, so the recovery verdict below \
has no baseline to be measured against."
  else
    b9_note "baseline: peer location decrypted in \
$(b9_marker_number "${log}" "${MARK_BASELINE}" 'ms')ms over the live engine."
  fi

  # (3) ANTI-VACUITY — something was actually connected to disconnect.
  local engine_base
  engine_base="$(b9_marker_flag "${log}" "${MARK_ENGINE_BASE}" 'running')"
  if [[ -z "${engine_base}" ]]; then
    b9_finding "no '${MARK_ENGINE_BASE} running=<bool>' line — without it, a \
run in which the live-sync engine was never up is indistinguishable from one \
whose engine was dropped and recovered."
  elif [[ "${engine_base}" != "true" ]]; then
    b9_finding "the live-sync engine was NOT running before the drop \
(${MARK_ENGINE_BASE} running=${engine_base}). There was no standing \
subscription to disconnect, so the reconnect verdict on this run is VACUOUS \
— fix the harness before reading anything into it."
  fi

  # (4) The drop reached the app under test, not merely adb.
  if b9_has_marker "${log}" "${MARK_NO_OUTAGE}"; then
    b9_finding "the relay stayed reachable from inside the app process after \
the network was dropped ('${MARK_NO_OUTAGE}'). HARNESS failure: neither \
\`cmd connectivity airplane-mode enable\` nor the host-side port REJECT \
disconnected the process under test, so this run exercised nothing."
  elif ! b9_has_marker "${log}" "${MARK_OUTAGE}"; then
    b9_finding "no '${MARK_OUTAGE}' line — the drive never confirmed an \
outage at all, so nothing below is a reconnect observation."
  else
    b9_note "outage observed by the app process after \
$(b9_marker_number "${log}" "${MARK_OUTAGE}" 'ms')ms."
  fi

  # (5) Connectivity came back.
  if b9_has_marker "${log}" "${MARK_NOT_RESTORED}"; then
    b9_finding "connectivity never returned to the app process \
('${MARK_NOT_RESTORED}'). HARNESS failure — recovery could not be tested. \
Check the restore half of the airplane-mode toggle and the \
HAVEN_B9_OUTAGE chain teardown."
  elif ! b9_has_marker "${log}" "${MARK_RESTORED}"; then
    b9_finding "no '${MARK_RESTORED}' line — the drive never confirmed that \
the network came back."
  fi

  # (6) THE BACKLOG PRECONDITIONS. Every one of these is a HARNESS statement:
  #     a failure here says the lane never created the situation it claims,
  #     and NONE of them may ever be read as a product defect. They are the
  #     reason a no-op import cannot reach a green run — the route by which
  #     this whole addition would otherwise be silently vacuous.
  if b9_has_marker "${log}" "${MARK_BACKLOG_STAGE_FAIL}"; then
    b9_finding "the drive could not produce the backlog event at all \
('${MARK_BACKLOG_STAGE_FAIL}'), so there was nothing for the host to import \
and the backlog-replay proof did not run. HARNESS failure — look at the \
encrypt/write step, not at the receive path."
  elif ! b9_has_marker "${log}" "${MARK_BACKLOG_STAGED}"; then
    b9_finding "no '${MARK_BACKLOG_STAGED}' line — the drive never staged a \
backlog event, so nothing below is a backlog observation."
  else
    local staged_offline
    staged_offline="$(b9_marker_flag "${log}" "${MARK_BACKLOG_STAGED}" \
      'offline')"
    if [[ "${staged_offline}" != "true" ]]; then
      b9_finding "the app process could still reach the relay when the \
backlog event was staged (${MARK_BACKLOG_STAGED} offline=${staged_offline:-\
<unreadable>}). The event the host then imported was NOT out of this \
device's reach, so 'it could only have arrived by replay' does not hold."
    fi
  fi

  if [[ -z "${hostlog}" || ! -f "${hostlog}" ]]; then
    b9_finding "no host-side backlog-import record at \
'${hostlog:-<none>}' — without it there is no evidence the event ever \
reached the relay DURING the partition, which is the entire claim."
  elif b9_has_marker "${hostlog}" "${MARK_HOST_IMPORT_FAIL}"; then
    b9_finding "the host could not import the backlog event \
(${MARK_HOST_IMPORT_FAIL} stage=$(b9_marker_flag "${hostlog}" \
"${MARK_HOST_IMPORT_FAIL}" 'stage')). HARNESS failure — see the detail= line \
in ${hostlog}. Any backlog verdict below is a CONSEQUENCE of this."
  elif ! b9_has_marker "${hostlog}" "${MARK_HOST_IMPORTED}"; then
    b9_finding "no '${MARK_HOST_IMPORTED}' line — the import phase never \
reported either way, so the relay's contents during the blackout are unknown."
  else
    # Each field is a separate claim, and each is asserted, because each has
    # its own way of going quietly wrong: a toggle that did not take, an
    # event the DEVICE had already published, and an import that returned 0
    # while writing nothing.
    local air_before air_after prescan postscan
    air_before="$(b9_marker_flag "${hostlog}" "${MARK_HOST_IMPORTED}" \
      'airplane_before')"
    air_after="$(b9_marker_flag "${hostlog}" "${MARK_HOST_IMPORTED}" \
      'airplane_after')"
    prescan="$(b9_marker_flag "${hostlog}" "${MARK_HOST_IMPORTED}" 'prescan')"
    postscan="$(b9_marker_flag "${hostlog}" "${MARK_HOST_IMPORTED}" 'postscan')"
    if [[ "${air_before}" != "1" || "${air_after}" != "1" ]]; then
      b9_finding "the backlog event was imported while the guest was NOT \
verifiably in airplane mode (airplane_before=${air_before:-<unreadable>} \
airplane_after=${air_after:-<unreadable>}). The device may have been able to \
receive it live, so a later decrypt proves nothing about backlog replay."
    fi
    if [[ "${prescan}" != "0" ]]; then
      b9_finding "the relay ALREADY held the staged event before the import \
(prescan=${prescan}). It reached the relay from the DEVICE, not from the \
host, so it is not backlog and the partition is not what delivered it."
    fi
    if [[ "${postscan}" == "0" ]]; then
      b9_finding "the import reported success but the relay did not hold the \
event afterwards (postscan=0) — a SILENT NO-OP import. Everything downstream \
would have failed for a reason that has nothing to do with the app."
    elif [[ -z "${postscan}" ]]; then
      b9_finding "the host import line carries no postscan= reading, so \
there is no evidence the relay's store actually changed."
    fi
  fi

  local backlog_served
  backlog_served="$(b9_marker_flag "${log}" "${MARK_BACKLOG_ON_RELAY}" \
    'served')"
  if [[ -z "${backlog_served}" ]]; then
    b9_finding "no '${MARK_BACKLOG_ON_RELAY} served=<bool>' line — the drive \
never asked the RUNNING relay for the imported event, so an import that \
landed in LMDB but was never served is indistinguishable from one that was."
  elif [[ "${backlog_served}" != "true" ]]; then
    b9_finding "the running relay did NOT serve the imported backlog event \
over a real subscription (${MARK_BACKLOG_ON_RELAY} \
served=${backlog_served}). HARNESS failure: \`strfry import\` writes straight \
to LMDB, and this is the check that the relay's query path sees it. Alice \
could not have received what the relay would not send."
  fi

  # (7) Something was sent to receive.
  if b9_has_marker "${log}" "${MARK_PEER_PUB_FAIL}"; then
    b9_finding "the peer could not publish after connectivity returned \
('${MARK_PEER_PUB_FAIL}'). The receive verdict below is UNREADABLE: a silent \
receive path and a silent send path are indistinguishable when nothing was \
sent."
  elif ! b9_has_marker "${log}" "${MARK_PEER_PUB}"; then
    b9_finding "no '${MARK_PEER_PUB}' line — no post-outage peer event was \
confirmed onto the relay, so 'the location never arrived' says nothing about \
the receive path."
  fi

  # (8) THE HEADLINE — a PEER EVENT DECRYPTED AFTER THE RECONNECT.
  if ! b9_has_marker "${log}" "${MARK_RESUMED}"; then
    if b9_has_marker "${log}" "${MARK_RECEIVE_DEAD}"; then
      b9_finding "live location receive did NOT recover after the network \
came back ('${MARK_RECEIVE_DEAD}'). The peer's post-outage location was \
OK-acked by the relay and Alice never decrypted it, so a transient network \
drop permanently ended live receive for the session. The drive's budget \
covers ALL THREE recovery paths — the relay pool's own reconnect + \
resubscribe (<=60s), the M8 subscription-health re-anchor, and MapShell's \
90-150s self-heal including one doubled retry — so this is not a budget \
that was too tight."
    else
      b9_finding "neither '${MARK_RESUMED}' nor '${MARK_RECEIVE_DEAD}' was \
recorded — the drive never reached the recovery check."
    fi
  else
    b9_note "recovery: a PEER location was decrypted \
$(b9_marker_number "${log}" "${MARK_RESUMED}" 'ms')ms after connectivity \
returned, with \
$(b9_marker_number "${log}" "${MARK_RESUMED}" 'republishes') re-publish(es)."
  fi

  # (9) THE BACKLOG HEADLINE — an event that reached the relay while this
  #     device was in airplane mode, decrypted after the reconnect.
  #
  #     `reason=expired` is deliberately NOT a finding. The kind-445 wire TTL
  #     is a fixed created_at + 228 s and strfry deletes on its own cron, so a
  #     recovery that legitimately took the slow MapShell heal path can outlive
  #     the event — and scoring that as a defect is exactly the "report a
  #     product defect every time the slow path ran" mistake the recovery
  #     budget above exists to avoid. It cannot be abused into a silent green,
  #     and now for two independent reasons: the precondition block above
  #     hard-fails without `${MARK_BACKLOG_ON_RELAY} served=true`, and the
  #     drive no longer PRINTS `expired` when the relay never served the event
  #     — that case is its own `reason=unserved`, so an import that reached
  #     LMDB and nothing else can no longer borrow the TTL's excuse.
  if b9_has_marker "${log}" "${MARK_BACKLOG_REPLAYED}"; then
    b9_note "BACKLOG PROVEN: an event imported to the relay while the guest \
was in airplane mode was decrypted \
$(b9_marker_number "${log}" "${MARK_BACKLOG_REPLAYED}" 'ms')ms after \
connectivity returned."
  else
    case "$(b9_marker_flag "${log}" "${MARK_BACKLOG_MISSED}" 'reason')" in
      live)
        b9_finding "THE BACKLOG WAS DROPPED. The relay was STILL SERVING the \
imported event when the post-restore peer location arrived, so live receive \
was demonstrably back while the event was demonstrably there, and Alice never \
decrypted it (${MARK_BACKLOG_MISSED} reason=live). The reconnect replayed the \
gap and the app discarded what came back. This is a receive-path defect, not \
a timing artefact — do NOT widen a window to make it pass."
        ;;
      expired)
        b9_note "the backlog proof did NOT run on this run: the relay had \
already GC'd the imported event by the time live receive came back, which the \
228 s kind-445 TTL permits when recovery takes the slow heal path. Read \
'${MARK_ENGINE_OUTAGE}' below for which path ran. The lane is green on its \
other assertions; the backlog claim is simply unproven here."
        ;;
      none)
        b9_note "the backlog proof did not run because live receive never \
came back at all — the finding is the ${MARK_RECEIVE_DEAD} one above."
        ;;
      unserved)
        b9_note "the backlog proof did not run because the RUNNING relay \
never served the imported event in the first place — the finding is the \
${MARK_BACKLOG_ON_RELAY} served=false one above. Reported separately from \
'expired' on purpose: an event the relay never served was not GC'd by the \
228 s TTL, and saying so would send the next reader to the wrong half."
        ;;
      *)
        b9_finding "neither '${MARK_BACKLOG_REPLAYED}' nor a readable \
'${MARK_BACKLOG_MISSED} reason=<live|expired|none|unserved>' was recorded — \
the drive never reached the backlog verdict, so this run says nothing about \
backlog replay either way."
        ;;
    esac
  fi

  # (10) EVIDENCE ONLY — which recovery mechanism this run exercised. An
  #     engine that survived the outage recovered through the relay pool's
  #     own reconnect; one that died needed MapShell's self-heal, which is
  #     an order of magnitude slower and is the path that had no runtime
  #     proof before this lane. Recorded, never asserted: both are correct
  #     outcomes and the lane must not pin an implementation detail.
  local engine_outage engine_recovered
  engine_outage="$(b9_marker_flag "${log}" "${MARK_ENGINE_OUTAGE}" 'running')"
  engine_recovered="$(b9_marker_flag "${log}" "${MARK_ENGINE_RECOVERED}" \
    'running')"
  if [[ -n "${engine_outage}" ]]; then
    if [[ "${engine_outage}" == "true" ]]; then
      b9_note "the live-sync engine SURVIVED the outage — recovery went \
through the relay pool's reconnect/resubscribe, not MapShell's self-heal."
    else
      b9_note "the live-sync engine was torn down during the outage \
(NostrSubscriptionService._onStreamClosed), so recovery required MapShell's \
90-150s self-heal (LiveSyncResubscriber.ensureRunning) — the slow path, and \
the one this lane exists to prove."
    fi
  fi
  if [[ -n "${engine_recovered}" ]]; then
    b9_note "engine running after the recovery window: ${engine_recovered}."
  fi

  (( ${#B9_FINDINGS[@]} == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no device, no relay.
#
# Chosen so a predicate that has rotted into always-passing cannot survive:
# (11) is the REAL FINDING case (everything green except the recovery) and
# must be reported, (12) is the healthy app and must PASS — without it an
# oracle hard-coded to red would look correct in (11) — and (13)-(16) are the
# four distinct vacuity routes, each of which would otherwise let step 7 pass
# or fail for a reason that is not about reconnect at all.
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

  # The device path the drive really prints, reused by every fixture so a
  # change to b9_device_path_ok cannot pass here while failing in the lane.
  local dev_path="/data/user/0/${PKG}/app_flutter/b9_backlog_event.json"

  # A complete, PASSING capture: live before, genuinely disconnected,
  # reconnected, a PEER EVENT decrypted afterwards, and the imported backlog
  # event decrypted too. Written as a function so each negative fixture
  # mutates exactly one line and nothing else.
  _fixture_full() { # _fixture_full <outfile> [recovery-line] [backlog-line]
    local out="$1"
    local rec="${2:-I/flutter ( 40): ${MARK_RESUMED} ms=41210 republishes=1}"
    local back="${3:-I/flutter ( 40): ${MARK_BACKLOG_REPLAYED} ms=18400}"
    printf '%s\n' \
      "I/flutter ( 40): ${MARK_ARMED}" \
      "I/flutter ( 40): ${MARK_BASELINE} ms=1840" \
      "I/flutter ( 40): ${MARK_ENGINE_BASE} running=true" \
      "I/flutter ( 40): ${MARK_AWAIT_DOWN}" \
      "I/flutter ( 40): ${MARK_OUTAGE} ms=9120" \
      "I/flutter ( 40): ${MARK_ENGINE_OUTAGE} running=false" \
      "I/flutter ( 40): ${MARK_BACKLOG_STAGED} offline=true path=${dev_path}" \
      "I/flutter ( 40): ${MARK_AWAIT_UP}" \
      "I/flutter ( 40): ${MARK_RESTORED} ms=6030" \
      "I/flutter ( 40): ${MARK_BACKLOG_ON_RELAY} served=true" \
      "I/flutter ( 40): ${MARK_PEER_PUB}" \
      "${rec}" \
      "${back}" \
      "I/flutter ( 40): ${MARK_ENGINE_RECOVERED} running=true" \
      "I/flutter ( 40): ${MARK_COMPLETE}" \
      > "${out}"
  }

  # The host-side import record. Its default is the only combination that
  # means "a genuine event reached the relay during a genuine partition".
  _fixture_host() { # _fixture_host <outfile> [line]
    local out="$1"
    local line="${2:-${MARK_HOST_IMPORTED} airplane_before=1 airplane_after=1 \
prescan=0 postscan=1}"
    printf '12:00:00 %s\n' "${line}" > "${out}"
  }

  echo "run-b9-network-reconnect.sh --self-test"
  _fixture_host "${tmp}/host.log"

  # --- b9_has_marker ------------------------------------------------------
  # (1) A raw drive-log line (no logcat prefix).
  printf '%s\n' "${MARK_OUTAGE} ms=1" > "${tmp}/raw.log"
  local rc=0; b9_has_marker "${tmp}/raw.log" "${MARK_OUTAGE}" || rc=1
  _case "marker found in a raw drive log" 0 "${rc}"

  # (2) THE SHAPE THAT ACTUALLY SHIPS — the same line via logcat, prefixed.
  printf '%s\n' "I/flutter ( 4021): ${MARK_OUTAGE} ms=1" > "${tmp}/lc.log"
  rc=0; b9_has_marker "${tmp}/lc.log" "${MARK_OUTAGE}" || rc=1
  _case "marker found behind a logcat prefix" 0 "${rc}"

  # (3) A missing file is not evidence of success.
  rc=0; b9_has_marker "${tmp}/nope.log" "${MARK_OUTAGE}" || rc=1
  _case "missing log reports absent" 1 "${rc}"

  # (4) THE NEGATIVE-TWIN TRAP. `OUTAGE_NOT_OBSERVED` must never satisfy a
  #     search for `OUTAGE_OBSERVED`, or a lane that never disconnected
  #     would read as one that did — the single most dangerous false green
  #     available here.
  printf '%s\n' "I/flutter ( 40): ${MARK_NO_OUTAGE}" > "${tmp}/twin.log"
  rc=0; b9_has_marker "${tmp}/twin.log" "${MARK_OUTAGE}" || rc=1
  _case "negative twin does not satisfy its positive (outage)" 1 "${rc}"

  # (5) Same trap on the restore pair.
  printf '%s\n' "I/flutter ( 40): ${MARK_NOT_RESTORED}" > "${tmp}/twin2.log"
  rc=0; b9_has_marker "${tmp}/twin2.log" "${MARK_RESTORED}" || rc=1
  _case "negative twin does not satisfy its positive (restore)" 1 "${rc}"

  # (6) …and on the publish pair.
  printf '%s\n' "I/flutter ( 40): ${MARK_PEER_PUB_FAIL} reason=StateError" \
    > "${tmp}/twin3.log"
  rc=0; b9_has_marker "${tmp}/twin3.log" "${MARK_PEER_PUB}" || rc=1
  _case "negative twin does not satisfy its positive (publish)" 1 "${rc}"

  # --- b9_marker_number ---------------------------------------------------
  # (7) Double digits must not lose to a lexical sort ('9' > '12').
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_RESUMED} ms=9 republishes=0" \
    "I/flutter ( 40): ${MARK_RESUMED} ms=124000 republishes=2" \
    > "${tmp}/wide.log"
  _eq_case "numeric (not lexical) max" "124000" \
    "$(b9_marker_number "${tmp}/wide.log" "${MARK_RESUMED}" 'ms')"

  # (8) A key on an UNRELATED marker must not answer for ours — several
  #     markers carry `ms=`.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_BASELINE} ms=1840" \
    "I/flutter ( 40): ${MARK_RESTORED} ms=99999" \
    > "${tmp}/mixed.log"
  _eq_case "key scoped to its own marker" "1840" \
    "$(b9_marker_number "${tmp}/mixed.log" "${MARK_BASELINE}" 'ms')"

  # (9) Absent marker -> empty, which is DISTINCT from "0".
  printf '%s\n' 'I/flutter ( 40): nothing here' > "${tmp}/none.log"
  _eq_case "absent marker yields empty (not 0)" "" \
    "$(b9_marker_number "${tmp}/none.log" "${MARK_RESUMED}" 'ms')"

  # --- b9_marker_flag -----------------------------------------------------
  # (10) The vacuity reading, with the CRLF adb actually emits.
  printf "I/flutter ( 40): ${MARK_ENGINE_BASE} running=false\r\n" \
    > "${tmp}/flag.log"
  _eq_case "flag parsed (false, CRLF)" "false" \
    "$(b9_marker_flag "${tmp}/flag.log" "${MARK_ENGINE_BASE}" 'running')"

  # --- b9_run_oracle ------------------------------------------------------
  # (11) THE REAL FINDING: everything worked until the reconnect, and live
  #      receive never came back. MUST be reported, or the lane blesses the
  #      defect it exists to find.
  _fixture_full "${tmp}/dead.log" \
    "I/flutter ( 40): ${MARK_RECEIVE_DEAD} republishes=7" \
    "I/flutter ( 40): ${MARK_BACKLOG_MISSED} reason=none"
  rc=0; b9_run_oracle "${tmp}/dead.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "never-recovered capture is REPORTED" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"did NOT recover"* ]]; then
    printf '  \033[1;31mFAIL\033[0m never-recovered finding does not name the recovery defect\n' >&2
    fails=1
  fi

  # (12) THE HEALTHY APP — identical except that the peer event arrived.
  #      Must PASS, or an oracle hard-coded to red would look correct above.
  _fixture_full "${tmp}/ok.log"
  rc=0; b9_run_oracle "${tmp}/ok.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "fully-recovered capture PASSES" 0 "${rc}"

  # (13) VACUITY ROUTE A — the engine was never running, so there was no
  #      subscription to drop. Every other marker is present.
  _fixture_full "${tmp}/noengine.log"
  sed -i 's/ENGINE_BASELINE running=true/ENGINE_BASELINE running=false/' \
    "${tmp}/noengine.log"
  rc=0; b9_run_oracle "${tmp}/noengine.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "engine never running fails as vacuous" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"VACUOUS"* ]]; then
    printf '  \033[1;31mFAIL\033[0m non-running engine is not reported as vacuous\n' >&2
    fails=1
  fi

  # (14) VACUITY ROUTE B — the network never actually went away. This is the
  #      one the item's own (non-existent) `adb emu network disable` would
  #      have produced silently.
  _fixture_full "${tmp}/nodrop.log"
  sed -i "s/OUTAGE_OBSERVED ms=9120/OUTAGE_NOT_OBSERVED/" "${tmp}/nodrop.log"
  rc=0; b9_run_oracle "${tmp}/nodrop.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "outage that never happened fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"HARNESS failure"* ]]; then
    printf '  \033[1;31mFAIL\033[0m missing outage is not attributed to the harness\n' >&2
    fails=1
  fi

  # (15) VACUITY ROUTE C — receive was already broken before the drop, so
  #      "it did not come back" is unattributable.
  _fixture_full "${tmp}/nobase.log"
  sed -i "s/BASELINE_RECEIVED ms=1840/BASELINE_DEAD/" "${tmp}/nobase.log"
  rc=0; b9_run_oracle "${tmp}/nobase.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "dead baseline fails the lane" 1 "${rc}"

  # (16) VACUITY ROUTE D — nothing was published after the outage, so a
  #      silent receive path and a silent send path are indistinguishable.
  _fixture_full "${tmp}/nopub.log" \
    "I/flutter ( 40): ${MARK_RECEIVE_DEAD} republishes=0" \
    "I/flutter ( 40): ${MARK_BACKLOG_MISSED} reason=none"
  sed -i "s/PEER_PUBLISHED_POST_OUTAGE/PEER_PUBLISH_FAILED reason=StateError/" \
    "${tmp}/nopub.log"
  rc=0; b9_run_oracle "${tmp}/nopub.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "unsent peer event fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"UNREADABLE"* ]]; then
    printf '  \033[1;31mFAIL\033[0m unsent peer event is not reported as unreadable\n' >&2
    fails=1
  fi

  # (17) A truncated capture (the drive died) must say so FIRST, so its
  #      downstream absences are not misread as product defects.
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_ARMED}" \
    "I/flutter ( 40): ${MARK_BASELINE} ms=1840" \
    "I/flutter ( 40): ${MARK_ENGINE_BASE} running=true" \
    "I/flutter ( 40): ${MARK_AWAIT_DOWN}" \
    > "${tmp}/truncated.log"
  rc=0; b9_run_oracle "${tmp}/truncated.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "truncated capture fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[0]}" != *"${MARK_COMPLETE}"* ]]; then
    printf '  \033[1;31mFAIL\033[0m truncated capture does not report the drive first\n' >&2
    fails=1
  fi

  # (18) A missing capture proves nothing and must never pass.
  rc=0; b9_run_oracle "${tmp}/absent.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "missing capture fails the lane" 1 "${rc}"

  # (19) The drive-log failure predicate this lane leans on is exercised by
  #      its own self-test; assert only that sourcing worked, so a refactor
  #      that drops the `source` fails here rather than at 3am.
  rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
  _case "drive-log failure predicate is in scope" 0 "${rc}"

  # (19b) Same for the shared strfry reader. Its real probe needs docker, so
  #      what is checkable here is that the `source` is still wired — a lane
  #      that lost it would fail at the import, twenty minutes in.
  rc=0; declare -F detect_strfry_bin >/dev/null || rc=1
  _case "shared strfry reader is in scope" 0 "${rc}"

  # --- b9_prune_empty_export_stderr ---------------------------------------
  #
  # THE LANE-CANNOT-BE-GREEN FIXTURE. `adb exec-out … 2>FILE` creates FILE at
  # redirection time, so a SUCCESSFUL export leaves 0 bytes — and the mandatory
  # secret scan calls a 0-byte `*.log` UNUSABLE (rc=3), which `cleanup` turns
  # into rc=1. Without the prune, B9 was red on exactly the runs where the
  # export worked, the same way the relay-poll log made B5 unpassable in CI
  # runs 30925179141 and 30964250098.
  local prunedir="${tmp}/prune"
  mkdir -p "${prunedir}"
  printf 'logcat content\n' > "${prunedir}/logcat.b9.log"
  printf '{"id":"aa"}\n' > "${prunedir}/backlog-event.b9.log"
  : > "${prunedir}/backlog-export-stderr.b9.log"   # a SUCCESSFUL export
  b9_prune_empty_export_stderr "${prunedir}/backlog-export-stderr.b9.log"
  # (19c) The empty capture is gone…
  _eq_case "an empty export stderr is dropped, not asserted" "0" \
    "$(find "${prunedir}" -name 'backlog-export-stderr.b9.log' \
       | grep -ac . || true)"
  # (19d) …so the scan a PASSING lane runs comes back clean.
  _case "…so a PASSING lane's log dir still scans clean" 0 \
    "$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan-logs-for-secrets.sh" \
       "${prunedir}" >/dev/null 2>&1; echo $?)"
  # (19e) A NON-empty one is the diagnosis for a refused `run-as` and is KEPT —
  #      pruning by name rather than by emptiness would delete the evidence.
  printf 'run-as: package not debuggable\n' \
    > "${prunedir}/backlog-export-stderr.b9.log"
  b9_prune_empty_export_stderr "${prunedir}/backlog-export-stderr.b9.log"
  _eq_case "a non-empty export stderr is kept" "1" \
    "$(find "${prunedir}" -name 'backlog-export-stderr.b9.log' \
       | grep -ac . || true)"

  # --- b9_event_id --------------------------------------------------------
  # A realistic kind-445 line: `id`, `pubkey` and `sig` are all hex, and the
  # first two are the same width. Only the `id` may ever be returned.
  printf '%s\n' \
    '{"id":"aa11bb22cc33dd44ee55ff6607788990aa11bb22cc33dd44ee55ff6607788990","pubkey":"11111111111111111111111111111111111111111111111111111111111111111","kind":445,"sig":"ff00"}' \
    > "${tmp}/evt.json"
  # (20) THE FIELD, NOT THE SHAPE.
  _eq_case "event id is read from the \"id\" key" \
    "aa11bb22cc33dd44ee55ff6607788990aa11bb22cc33dd44ee55ff6607788990" \
    "$(b9_event_id "${tmp}/evt.json")"

  # (21) A pubkey-first serialization must not answer for the id — this is
  #      the exact way a bare `[0-9a-f]{64}` match would import the wrong id
  #      and then "prove" the relay never received it.
  printf '%s\n' \
    '{"pubkey":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","id":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}' \
    > "${tmp}/evt2.json"
  _eq_case "pubkey does not answer for the id" \
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
    "$(b9_event_id "${tmp}/evt2.json")"

  # (22) An empty export yields nothing, never a stale or partial id.
  : > "${tmp}/evt3.json"
  _eq_case "an empty export yields no id" "" "$(b9_event_id "${tmp}/evt3.json")"

  # --- b9_ndjson_payload --------------------------------------------------
  #
  # THE RUN-31868809387 FIXTURES. `strfry import` reads NDJSON; the drive
  # stages a `serde_json::to_string` line through `writeAsString`, so the
  # export has NO terminating newline and strfry discarded it while exiting 0.
  local one_line='{"id":"aa","kind":445,"sig":"ff"}'

  # (22b) THE SHAPE THAT ACTUALLY SHIPS — and the one that was broken.
  printf '%s' "${one_line}" > "${tmp}/nonl.json"
  _eq_case "an export with NO trailing newline still yields its line" \
    "${one_line}" "$(b9_ndjson_payload "${tmp}/nonl.json")"

  # (22c) The already-terminated case must be idempotent, not double-spaced:
  #      the caller appends exactly one newline to whatever comes back.
  printf '%s\n' "${one_line}" > "${tmp}/nl.json"
  _eq_case "an already-terminated export yields the same line" \
    "${one_line}" "$(b9_ndjson_payload "${tmp}/nl.json")"

  # (22d) CRLF is stripped, because that is precisely the corruption
  #      `exec-out` exists to avoid and a silent one if it ever returns.
  printf '%s\r\n' "${one_line}" > "${tmp}/crlf.json"
  _eq_case "a CRLF export is normalised to one clean line" \
    "${one_line}" "$(b9_ndjson_payload "${tmp}/crlf.json")"

  # (22e) A pretty-printed export is REFUSED, never partially imported: its
  #      first line is not an event, and importing it would put something
  #      other than the backlog event on the relay under that event's name.
  printf '{\n  "id": "aa"\n}\n' > "${tmp}/pretty.json"
  _eq_case "a multi-line export is refused, not truncated to line 1" "" \
    "$(b9_ndjson_payload "${tmp}/pretty.json")"

  # (22f) Two events are not the one event this lane's claim is about.
  printf '%s\n%s\n' "${one_line}" "${one_line}" > "${tmp}/two.json"
  _eq_case "a two-event export is refused" "" \
    "$(b9_ndjson_payload "${tmp}/two.json")"

  # (22g) An empty export is nothing to import, and must not read as one.
  : > "${tmp}/empty.json"
  _eq_case "an empty export yields no payload" "" \
    "$(b9_ndjson_payload "${tmp}/empty.json")"

  # --- b9_import_counts ---------------------------------------------------
  # (22h) THE VERBATIM NO-OP SUMMARY from run 31868809387. A zero exit over
  #      this line is the false green the accounting gate exists to stop.
  printf '%s\n' \
    '2026-08-15 06:33:36.312 (0.052s) [main thread]WARN| Unable to parse JSON on line 1' \
    '2026-08-15 06:33:36.312 (0.052s) [main thread]INFO| Done. Processed 0 lines. 0 added, 0 rejected, 0 dups' \
    > "${tmp}/imp-noop.log"
  _eq_case "the no-op import summary reads as 0 added" "0 0 0" \
    "$(b9_import_counts "${tmp}/imp-noop.log")"

  # (22i) The healthy summary, so the gate is not simply always-failing.
  printf '%s\n' \
    '2026-08-15 06:33:36.312 (0.050s) [main thread]INFO| Done. Processed 1 lines. 1 added, 0 rejected, 0 dups' \
    > "${tmp}/imp-ok.log"
  _eq_case "a successful import summary reads as 1 added" "1 1 0" \
    "$(b9_import_counts "${tmp}/imp-ok.log")"

  # (22j) strfry's ingest validation refusing the event is its OWN reading —
  #      a bad signature must not be reported as a framing fault.
  printf '%s\n' \
    '2026-08-15 06:33:36.312 (0.050s) [main thread]INFO| Done. Processed 1 lines. 0 added, 1 rejected, 0 dups' \
    > "${tmp}/imp-rej.log"
  _eq_case "a rejected event is distinguishable from an unparsed one" \
    "1 0 1" "$(b9_import_counts "${tmp}/imp-rej.log")"

  # (22k) No summary at all is not "it worked": the exit status alone is
  #      never evidence, so an absent line must yield nothing to read.
  printf 'CONFIG: successfully installed\n' > "${tmp}/imp-none.log"
  _eq_case "an import with no summary yields no counts" "" \
    "$(b9_import_counts "${tmp}/imp-none.log")"

  # (22l-n) THE CALL SITE, not just the helpers. Every fixture above is over a
  #      PURE function, and a refactor can leave all of them perfect while
  #      handing strfry the raw file again — the run-31868809387 defect
  #      restored under a green self-test.
  #
  #      Scoped to `backlog_import`'s OWN body, never the whole file: a
  #      whole-file scan matches the fixture's own grep pattern and passes
  #      over a deleted call site, which is how the first draft of these three
  #      survived their mutants. Comment lines are stripped for the same
  #      reason at one remove — prose that merely mentions the call must not
  #      satisfy it.
  local import_body
  import_body="$(awk '/^backlog_import\(\) \{/,/^\}/' "${BASH_SOURCE[0]}" \
                 | grep -v '^[[:space:]]*#')"

  _src_case() { # _src_case <label> <literal> <what-breaks>
    local label="$1" needle="$2" broken="$3"
    checks=$(( checks + 1 ))
    if grep -qF -- "${needle}" <<<"${import_body}"; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s — %s\n' "${label}" "${broken}" >&2
      fails=1
    fi
  }

  _src_case "the export is framed before it is imported" \
    'b9_ndjson_payload "${BACKLOG_FILE}"' \
    'an unterminated or multi-line export would reach strfry unchecked'
  _src_case "strfry is fed the newline-terminated payload" \
    "printf '%s\\n' \"\${payload}\"" \
    'strfry discards an unterminated line and still exits 0'
  _src_case "strfry own accounting is read" \
    'b9_import_counts "${HOST_LOG}"' \
    'a no-op import is again reported only as an unexplained empty post-scan'

  # --- b9_marker_path -----------------------------------------------------
  printf '%s\n' \
    "I/flutter ( 40): ${MARK_BACKLOG_STAGED} offline=true path=${dev_path}" \
    > "${tmp}/path.log"
  # (23) THE REASON THIS HELPER EXISTS: b9_marker_flag's value charset stops
  #      at the first `/`, so reusing it here would silently yield "" and the
  #      lane would blame the drive for a path it printed correctly.
  _eq_case "device path survives its slashes" "${dev_path}" \
    "$(b9_marker_path "${tmp}/path.log" "${MARK_BACKLOG_STAGED}")"

  # --- b9_device_path_ok --------------------------------------------------
  # (24) The real shape the drive prints.
  rc=0; b9_device_path_ok "${dev_path}" "${PKG}" || rc=1
  _case "the app's own data path is accepted" 0 "${rc}"

  # (25) Another app's data dir is not ours to read.
  rc=0; b9_device_path_ok "/data/user/0/com.example.other/f.json" "${PKG}" \
    || rc=1
  _case "another package's path is rejected" 1 "${rc}"

  # (26) The anchor must not be walkable.
  rc=0; b9_device_path_ok "/data/user/0/${PKG}/../../x" "${PKG}" || rc=1
  _case "a traversal out of the anchor is rejected" 1 "${rc}"

  # (27) A path outside /data entirely.
  rc=0; b9_device_path_ok "/sdcard/b9.json" "${PKG}" || rc=1
  _case "an external-storage path is rejected" 1 "${rc}"

  # (28) THE DOT TRAP. `.` is a regex wildcard, so an unescaped package would
  #      accept a look-alike package name from a hostile-ish capture.
  rc=0; b9_device_path_ok "/data/user/0/comXoblivioustechXhaven/f" "${PKG}" \
    || rc=1
  _case "package dots are matched literally" 1 "${rc}"

  # --- the backlog branches of the oracle ---------------------------------
  # (29) THE BACKLOG DEFECT: the relay was still serving the imported event
  #      when live receive demonstrably came back, and it was never
  #      decrypted. This is the whole reason the addition exists and MUST be
  #      reported.
  _fixture_full "${tmp}/blive.log" \
    "I/flutter ( 40): ${MARK_RESUMED} ms=41210 republishes=1" \
    "I/flutter ( 40): ${MARK_BACKLOG_MISSED} reason=live"
  rc=0; b9_run_oracle "${tmp}/blive.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "a dropped backlog event is REPORTED" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"BACKLOG WAS DROPPED"* ]]; then
    printf '  \033[1;31mFAIL\033[0m dropped backlog is not named as the defect\n' >&2
    fails=1
  fi

  # (30) THE HONEST NON-PROOF. A recovery slower than the 228 s kind-445 TTL
  #      is correct behaviour on both sides, so it must NOT fail the lane —
  #      and it must not be reachable without served=true, which (33) pins.
  _fixture_full "${tmp}/bexp.log" \
    "I/flutter ( 40): ${MARK_RESUMED} ms=280400 republishes=6" \
    "I/flutter ( 40): ${MARK_BACKLOG_MISSED} reason=expired"
  rc=0; b9_run_oracle "${tmp}/bexp.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "an expired backlog event does NOT fail the lane" 0 "${rc}"

  # (30b) THE EXCUSE THAT MAY NOT BE BORROWED. An import that landed in LMDB
  #      and was never SERVED is not an event the 228 s TTL removed, and the
  #      drive must not label it `expired` — the note would send the next
  #      reader to the TTL when the fault is the import. The run is red on the
  #      served= finding; what this pins is that the verdict says why.
  _fixture_full "${tmp}/bunserved.log" \
    "I/flutter ( 40): ${MARK_RESUMED} ms=41210 republishes=1" \
    "I/flutter ( 40): ${MARK_BACKLOG_MISSED} reason=unserved"
  sed -i "s/BACKLOG_ON_RELAY served=true/BACKLOG_ON_RELAY served=false/" \
    "${tmp}/bunserved.log"
  rc=0
  local unserved_notes
  unserved_notes="$(b9_run_oracle "${tmp}/bunserved.log" "${tmp}/host.log")" \
    || rc=1
  _case "an unserved backlog verdict fails the lane" 1 "${rc}"
  if [[ "${unserved_notes}" == *"228 s kind-445 TTL"* ]]; then
    printf '  \033[1;31mFAIL\033[0m an unserved import is excused by the TTL\n' >&2
    fails=1
  fi
  if [[ "${unserved_notes}" != *"never served the imported event"* ]]; then
    printf '  \033[1;31mFAIL\033[0m an unserved import is not named as such\n' >&2
    fails=1
  fi

  # (31) A drive that never reached the verdict proved nothing either way.
  _fixture_full "${tmp}/bnone.log" \
    "I/flutter ( 40): ${MARK_RESUMED} ms=41210 republishes=1" \
    "I/flutter ( 40): (no backlog verdict was printed)"
  rc=0; b9_run_oracle "${tmp}/bnone.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "a missing backlog verdict fails the lane" 1 "${rc}"

  # (32) The drive could not produce a backlog event at all. The MESSAGE is
  #      pinned for the same reason as (37): the neighbouring "no
  #      BACKLOG_STAGED line" branch fails this fixture too, so only naming
  #      the diagnosis keeps this from passing over a deleted one.
  _fixture_full "${tmp}/bstage.log"
  sed -i "s/BACKLOG_STAGED offline=true/BACKLOG_STAGE_FAILED reason=StateError/" \
    "${tmp}/bstage.log"
  rc=0; b9_run_oracle "${tmp}/bstage.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "an unstaged backlog event fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"could not produce the backlog event"* ]]; then
    printf '  \033[1;31mFAIL\033[0m an unstaged backlog event is not named as such\n' >&2
    fails=1
  fi

  # (33) THE IMPORT THAT WROTE NOTHING. `strfry import` exiting 0 over a
  #      rejected event is the single most dangerous silent green available
  #      here: every app-side marker below it would still read green.
  _fixture_full "${tmp}/bnoop.log"
  _fixture_host "${tmp}/hostnoop.log" \
    "${MARK_HOST_IMPORTED} airplane_before=1 airplane_after=1 prescan=0 postscan=0"
  rc=0; b9_run_oracle "${tmp}/bnoop.log" "${tmp}/hostnoop.log" >/dev/null || rc=1
  _case "a no-op import fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"SILENT NO-OP"* ]]; then
    printf '  \033[1;31mFAIL\033[0m a no-op import is not named as such\n' >&2
    fails=1
  fi

  # (34) THE PARTITION THAT WAS NOT ONE. An import made while the guest still
  #      had connectivity proves nothing about backlog replay.
  _fixture_host "${tmp}/hostair.log" \
    "${MARK_HOST_IMPORTED} airplane_before=0 airplane_after=1 prescan=0 postscan=1"
  rc=0; b9_run_oracle "${tmp}/ok.log" "${tmp}/hostair.log" >/dev/null || rc=1
  _case "an import outside airplane mode fails the lane" 1 "${rc}"

  # (35) THE EVENT THE DEVICE PUBLISHED ITSELF. If the relay already held it,
  #      the partition is not what delivered it.
  _fixture_host "${tmp}/hostpre.log" \
    "${MARK_HOST_IMPORTED} airplane_before=1 airplane_after=1 prescan=1 postscan=1"
  rc=0; b9_run_oracle "${tmp}/ok.log" "${tmp}/hostpre.log" >/dev/null || rc=1
  _case "an event already on the relay fails the lane" 1 "${rc}"

  # (36) A recorded import failure must be reported with its stage, so the
  #      next reader debugs the export/import and not the receive path.
  _fixture_host "${tmp}/hostfail.log" \
    "${MARK_HOST_IMPORT_FAIL} stage=export detail=run-as refused"
  rc=0; b9_run_oracle "${tmp}/ok.log" "${tmp}/hostfail.log" >/dev/null || rc=1
  _case "a failed import fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"stage=export"* ]]; then
    printf '  \033[1;31mFAIL\033[0m import failure does not name its stage\n' >&2
    fails=1
  fi

  # (37) No host record at all — the lane cannot claim a partition it never
  #      documented. The MESSAGE is pinned too: without that, deleting this
  #      branch leaves the neighbouring "no BACKLOG_IMPORTED line" one to fail
  #      the fixture for a different reason, and the self-test stays green over
  #      a diagnosis that no longer exists (found by mutation).
  rc=0; b9_run_oracle "${tmp}/ok.log" "${tmp}/absent-host.log" >/dev/null \
    || rc=1
  _case "a missing host import record fails the lane" 1 "${rc}"
  if (( rc == 1 )) && [[ "${B9_FINDINGS[*]}" != *"no host-side backlog-import record"* ]]; then
    printf '  \033[1;31mFAIL\033[0m absent host record is not named as such\n' >&2
    fails=1
  fi

  # (38) THE LMDB-ONLY IMPORT. The bytes are in the database and the running
  #      relay will not serve them — every app-side assertion would then fail
  #      for a reason that is not about the app.
  _fixture_full "${tmp}/bserved.log"
  sed -i "s/BACKLOG_ON_RELAY served=true/BACKLOG_ON_RELAY served=false/" \
    "${tmp}/bserved.log"
  rc=0; b9_run_oracle "${tmp}/bserved.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "an unserved backlog event fails the lane" 1 "${rc}"

  # (39) THE STAGING THAT WAS NOT OFFLINE — the drive could still reach the
  #      relay when it staged, so the event was never out of its reach.
  _fixture_full "${tmp}/bonline.log"
  sed -i "s/BACKLOG_STAGED offline=true/BACKLOG_STAGED offline=false/" \
    "${tmp}/bonline.log"
  rc=0; b9_run_oracle "${tmp}/bonline.log" "${tmp}/host.log" >/dev/null || rc=1
  _case "staging while still online fails the lane" 1 "${rc}"

  if (( fails )); then
    echo "run-b9-network-reconnect.sh --self-test: FAILURES" >&2
    return 1
  fi
  # COUNTED, never restated: a hardcoded total goes stale the moment a
  # fixture is added, and a self-test that misreports its own size is the
  # first thing a reader stops trusting.
  echo "run-b9-network-reconnect.sh --self-test: all ${checks} checks passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
readonly DEVICE="emulator-5554"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly LOG_DIR="/tmp/b9-logs"
readonly APK="${1:-/tmp/integration-apks/b9_network_reconnect_test.apk}"
readonly TARGET="${2:-integration_test/b9_network_reconnect_test.dart}"

# Bounds the drive only; the step's run-with-deadline.sh wrapper bounds
# install + grants + both network toggles + the oracle on top (see
# scripts/ci/check_e2e_step_timeout_ordering.sh for the ordering invariant).
#
# Sizing: the drive target's own budget is arming (~90s under emulator mlock
# pressure) + up to 75s for the baseline receive + up to 120s waiting for the
# drop + the 75s outage hold + up to 120s waiting for the restore + up to
# 330s for recovery = ~13 min worst case, against a 16-minute in-test
# `Timeout`. 20m leaves headroom for a slow cold start without letting a
# wedge run anonymously to the outer deadline.
readonly DRIVE_TIMEOUT="${B9_DRIVE_TIMEOUT:-20m}"

# Host port strfry is published on — the port layer L2 rejects.
readonly STRFRY_PORT="${B9_STRFRY_PORT:-7777}"
if [[ ! "${STRFRY_PORT}" =~ ^[0-9]{1,5}$ ]]; then
  echo "ERROR: B9_STRFRY_PORT must be a plain port number (got" \
       "'${STRFRY_PORT}')." >&2
  exit 2
fi

# The dedicated iptables chain for layer L2. Named, created and destroyed by
# THIS script only, so it can never collide with setup-network-guard.sh's
# HAVEN_E2E_GUARD (which the hermetic lanes install for a different purpose
# and leave up for the whole job).
readonly HOST_CHAIN="HAVEN_B9_OUTAGE"

# The relay container the backlog event is imported into. Same default as
# start-strfry.sh's own STRFRY_CONTAINER, and read from the same variable so
# a job that renames the container does not have to rename it twice.
readonly STRFRY_CONTAINER="${STRFRY_CONTAINER:-strfry}"

# Resolved by detect_strfry_bin at import time — the dockurr/strfry image has
# moved the binary between paths, so it is probed rather than assumed.
STRFRY_BIN=""

# How long to wait for each of the drive's cue markers. Generous relative to
# the drive's own internal budgets: a late marker is still usable evidence,
# while a marker wait that fires early destroys the run.
readonly ARM_MARKER_TIMEOUT="${B9_ARM_MARKER_TIMEOUT:-420}"
readonly OUTAGE_MARKER_TIMEOUT="${B9_OUTAGE_MARKER_TIMEOUT:-360}"

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""
DRIVE_PID=""
HOST_BLOCK_INSTALLED=0

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.b9.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
readonly NET_LOG="${LOG_DIR}/network-toggles.b9.log"

# Host-side backlog evidence. Both named `.log` on purpose: the secret-leak
# scanner's directory walk only picks up `*.log`, and an artifact this lane
# uploads unscanned is exactly what the workflow's own diag step warns about.
# The exported event is MLS ciphertext plus public keys and a signature, so
# no pattern can fire on it — being scanned anyway is the correct default,
# not an exception to argue for.
readonly HOST_LOG="${LOG_DIR}/backlog-import.b9.log"
readonly BACKLOG_FILE="${LOG_DIR}/backlog-event.b9.log"
# `.b9.log`, not `.log.err` — the scanner's walk globs `*.log`, and a suffix
# it does not match is an artifact this lane would upload unscanned.
readonly BACKLOG_ERR="${LOG_DIR}/backlog-export-stderr.b9.log"

# ---------------------------------------------------------------------------
# Layer L2 — host-side REJECT of the relay port.
#
# The emulator proxies guest TCP through host sockets (QEMU SLIRP), so a host
# OUTPUT rule reaches the guest's relay connection. `--reject-with tcp-reset`
# rather than DROP: an RST kills the established socket immediately, where a
# black hole would leave the pool waiting out its 55 s PING_INTERVAL before
# noticing — turning a 75 s outage into one the app barely registers.
#
# Entirely best-effort. The drive is the authority on whether an outage
# happened, so a runner without passwordless sudo degrades to layer L1 alone
# (slower detection) rather than failing the lane.
# ---------------------------------------------------------------------------
host_block_install() {
  if [[ "${B9_SKIP_HOST_BLOCK:-}" == "1" ]]; then
    echo "  L2 skipped (B9_SKIP_HOST_BLOCK=1)"
    return 0
  fi
  if ! command -v iptables >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    echo "  L2 unavailable (no iptables or no passwordless sudo) — relying" \
         "on airplane mode alone; socket death may take up to one 55s" \
         "WebSocket ping interval." >&2
    return 0
  fi
  sudo iptables -N "${HOST_CHAIN}" 2>/dev/null \
    || sudo iptables -F "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -A "${HOST_CHAIN}" -p tcp --dport "${STRFRY_PORT}" \
    -j REJECT --reject-with tcp-reset 2>/dev/null || true
  sudo iptables -D OUTPUT -j "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -I OUTPUT 1 -j "${HOST_CHAIN}" 2>/dev/null || true
  HOST_BLOCK_INSTALLED=1
  echo "  L2 installed: OUTPUT -> ${HOST_CHAIN} rejects tcp/${STRFRY_PORT}"
}

host_block_remove() {
  (( HOST_BLOCK_INSTALLED == 1 )) || return 0
  sudo iptables -D OUTPUT -j "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -F "${HOST_CHAIN}" 2>/dev/null || true
  sudo iptables -X "${HOST_CHAIN}" 2>/dev/null || true
  HOST_BLOCK_INSTALLED=0
  echo "  L2 removed"
}

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the background helpers, RESTORE connectivity in
# BOTH layers (a lane that left airplane mode on, or an iptables REJECT
# installed, would silently poison every later step in this job — including
# its own artifact upload), run the MANDATORY secret scan over every captured
# log (Security Rule 6 — must run even on a phase failure), snapshot + tear
# down strfry. Escalates on a leak; never masks a phase rc.
#
# Mirrors run-b6-location-provider-toggle.sh containment, including the
# deliberate asymmetry between rc 1 (leak -> destroy the logs) and rc 3
# (unscannable -> keep them, because there is no leak and the truncated
# artefacts ARE the evidence of the failure that tripped the guard).
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  local scan_rc=0
  trap - EXIT
  if [[ -n "${DRIVE_PID}" ]] && kill -0 "${DRIVE_PID}" 2>/dev/null; then
    kill "${DRIVE_PID}" 2>/dev/null || true
  fi
  # Restore BEFORE logcat is stopped so the restore itself is captured.
  host_block_remove || true
  adb -s "${DEVICE}" shell cmd connectivity airplane-mode disable \
    >/dev/null 2>&1 || true
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  docker logs "${STRFRY_CONTAINER}" > "${LOG_DIR}/strfry.final.log" 2>&1 \
    || true
  # See b9_prune_empty_export_stderr: a SUCCESSFUL export leaves this file at
  # 0 bytes, and a 0-byte `*.log` is fatal to the scan below.
  b9_prune_empty_export_stderr "${BACKLOG_ERR}"
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  bash "${SECRET_SCAN}" "${LOG_DIR}" || scan_rc=$?
  if (( scan_rc == 1 )); then
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    {
      echo "Logs withheld: the secret-leak guard tripped (Security Rule 6)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped on B9 logs — logs deleted," \
         "not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 )); then
    # An unscannable log is only NEWS on a lane that otherwise succeeded. When
    # the lane has already failed, the abort is WHY the capture is short or
    # missing, and re-reporting it as a second, differently-worded ERROR buries
    # the real cause under a downstream symptom (run-b5-permission-revocation.sh
    # carries the same asymmetry, and the CI runs that taught it).
    #
    # The guard is NOT relaxed: the scan still runs unconditionally, a leak
    # (rc=1) still escalates in the branch above, and an unscannable log on a
    # PASSING lane is still fatal. Only the reporting changes, and only in the
    # direction of not overwriting a more specific rc with a less specific one.
    if (( rc == 0 )); then
      echo "ERROR: secret-leak guard could not scan the B9 logs" \
           "(rc=${scan_rc}) — see the UNUSABLE line(s) above. The lane" \
           "otherwise PASSED, so this is a real capture failure: an expected" \
           "log was never written and the privacy scan therefore proved" \
           "nothing. Logs kept for triage." >&2
      rc=1
    else
      echo "NOTE: the secret-leak guard could not scan every B9 log" \
           "(rc=${scan_rc}) because the lane aborted before those captures" \
           "were written — see the UNUSABLE line(s) above and the" \
           "B9-LANE-FAIL line for the actual failure. Preserving the original" \
           "exit code ${rc}. Logs kept for triage." >&2
    fi
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "B9-LANE-FAIL: $*" >&2
  if (( ${drive_failed:-0} == 1 )); then
    echo "NOTE: the drive ALSO did not complete cleanly" \
         "(${drive_reason:-unknown}). The finding above may be a CONSEQUENCE" \
         "of that rather than a product defect — rule the drive failure out" \
         "first." >&2
  fi
  echo "---- [b9] markers seen ----" >&2
  grep -ahF '[b9] ' "${LOGCAT_FILE}" "${DRIVE_LOG}" 2>/dev/null | tail -40 >&2 \
    || echo "(none — the drive target reached no checkpoint at all)" >&2
  echo "---- network toggle log ----" >&2
  cat "${NET_LOG}" >&2 2>/dev/null || echo "(no toggles recorded)" >&2
  echo "---- backlog import log ----" >&2
  cat "${HOST_LOG}" >&2 2>/dev/null || echo "(no import attempted)" >&2
  echo "---- guest connectivity state ----" >&2
  {
    echo "airplane_mode_on=$(airplane_state)"
    adb -s "${DEVICE}" shell dumpsys connectivity 2>/dev/null \
      | grep -aiE 'Active default network|NetworkAgentInfo.*CONNECTED' \
      | head -10
  } >&2 2>/dev/null || echo "(connectivity state unavailable)" >&2
  exit 1
}

# airplane_state — echoes `1` / `0` as the platform records it, or empty.
#
# `settings get global airplane_mode_on` is the AUTHORITATIVE read-back:
# `cmd connectivity airplane-mode enable` returns 0 whether or not the
# caller was permitted to change it, exactly like `pm grant` does for a
# hard-restricted permission (the trap B3/B6 document).
airplane_state() {
  adb -s "${DEVICE}" shell settings get global airplane_mode_on 2>/dev/null \
    | tr -d '\r' | tr -d '[:space:]' || true
}

# set_airplane <1|0> — toggles airplane mode and VERIFIES the read-back.
#
# The verification is a HARD gate on the DOWN direction: a toggle that
# silently did not take would leave layer L2 producing the outage on its own,
# and the lane would keep calling itself "network loss" while proving only
# that an unreachable relay is survivable. Naming that difference is the
# whole reason the read-back exists.
set_airplane() {
  local want="$1" verb="disable" got=""
  [[ "${want}" == "1" ]] && verb="enable"
  adb -s "${DEVICE}" shell cmd connectivity airplane-mode "${verb}" \
    >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    got="$(airplane_state)"
    [[ "${got}" == "${want}" ]] && break
    sleep 1
  done
  printf '%s airplane-mode %s -> airplane_mode_on=%s\n' \
    "$(date -u +%H:%M:%S)" "${verb}" "${got:-<unreadable>}" >> "${NET_LOG}"
  echo "  airplane_mode_on now: ${got:-<unreadable>}"
  [[ "${got}" == "${want}" ]]
}

# wait_for_marker <marker> <timeout-secs> — 0 when the marker appears in the
# logcat capture, 1 on timeout or on the drive dying first.
#
# Watching the drive's liveness matters: a target that crashed will never
# print its next cue, and burning the full marker timeout on a corpse turns a
# clear "the drive died" into an anonymous lane-level timeout.
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

# ---------------------------------------------------------------------------
# The backlog import. See the header for WHY this, and not a host-side relay
# client, is the publisher that survives the blackout.
#
# Every step is a hard gate that records WHICH one failed, because each has a
# distinct diagnosis and lumping them together is how a lane ends up being
# "fixed" by widening the wrong window.
# ---------------------------------------------------------------------------

# backlog_host_fail <stage> <detail...> — records a host-side import failure
# and returns 1. Never fatal here: the drive must still be drained and
# connectivity must still be restored, so the oracle turns this into the
# finding at the end.
backlog_host_fail() {
  local stage="$1"
  shift
  printf '%s %s stage=%s detail=%s\n' \
    "$(date -u +%H:%M:%S)" "${MARK_HOST_IMPORT_FAIL}" "${stage}" "$*" \
    >> "${HOST_LOG}"
  echo "  BACKLOG IMPORT FAILED (stage=${stage}): $*" >&2
  return 1
}

# backlog_scan_count <event-id> — echoes how many lines the relay's store
# returns for that id. Non-zero rc only when the scan itself could not run,
# so "the relay would not answer" is never mistaken for "the event is absent".
backlog_scan_count() {
  local id="$1" out
  out="$(docker exec "${STRFRY_CONTAINER}" "${STRFRY_BIN}" scan \
        "{\"ids\":[\"${id}\"]}" 2>/dev/null)" || return 1
  grep -acF -- "${id}" <<<"${out}" || true
}

# backlog_import — export the staged event off the device and put it on the
# relay, with the guest still partitioned. 0 on success.
backlog_import() {
  local device_path id payload air_before air_after prescan postscan
  local processed='' added='' rejected=''

  # Read the toggle state FIRST. An import that ran outside the blackout
  # proves nothing, and finding that out afterwards would mean discovering it
  # only once the whole recovery window had already been spent.
  air_before="$(airplane_state)"
  if [[ "${air_before}" != "1" ]]; then
    backlog_host_fail airplane "the guest was NOT in airplane mode when the \
import was about to run (airplane_mode_on=${air_before:-<unreadable>}), so \
the event would not have been out of this device's reach"
    return 1
  fi

  device_path="$(b9_marker_path "${LOGCAT_FILE}" "${MARK_BACKLOG_STAGED}")"
  if ! b9_device_path_ok "${device_path}" "${PKG}"; then
    backlog_host_fail path "no usable device path on the \
'${MARK_BACKLOG_STAGED}' line (got '${device_path:-<none>}'); the drive \
either never staged the event or printed a path outside ${PKG}'s data dir"
    return 1
  fi

  # `exec-out`, never `shell`: `adb shell` translates LF to CRLF, which would
  # corrupt the signed event and turn this into an unattributable "the relay
  # rejected it". `run-as` needs a DEBUG build — which is what
  # build-integration-apks.sh produces.
  if ! adb -s "${DEVICE}" exec-out run-as "${PKG}" cat "${device_path}" \
       > "${BACKLOG_FILE}" 2>"${BACKLOG_ERR}"; then
    backlog_host_fail export "\`adb exec-out run-as ${PKG} cat\` failed: \
$(tr -d '\r' < "${BACKLOG_ERR}" 2>/dev/null | head -c 200). run-as \
requires a debuggable APK."
    return 1
  fi

  id="$(b9_event_id "${BACKLOG_FILE}")"
  if [[ -z "${id}" ]]; then
    backlog_host_fail parse "the exported file carries no 64-hex \"id\" \
($(wc -c < "${BACKLOG_FILE}" 2>/dev/null || echo 0) bytes exported)"
    return 1
  fi

  # NDJSON framing, which `strfry import` requires and neither the drive's
  # `writeAsString` nor `serde_json::to_string` provides (b9_ndjson_payload).
  payload="$(b9_ndjson_payload "${BACKLOG_FILE}")"
  if [[ -z "${payload}" ]]; then
    backlog_host_fail ndjson "the exported file is not ONE JSON line \
($(wc -l < "${BACKLOG_FILE}" 2>/dev/null || echo 0) newline(s) in \
$(wc -c < "${BACKLOG_FILE}" 2>/dev/null || echo 0) bytes); \`strfry import\` \
reads NDJSON and would discard it and still exit 0"
    return 1
  fi

  if ! detect_strfry_bin; then
    backlog_host_fail strfry "no \`strfry\` binary in the \
'${STRFRY_CONTAINER}' container could answer a scan"
    return 1
  fi

  # PRE-SCAN — the anti-vacuity check that matters most. If the relay ALREADY
  # holds this event, the DEVICE published it, and a later decrypt would say
  # nothing whatever about a partition.
  if ! prescan="$(backlog_scan_count "${id}")"; then
    backlog_host_fail prescan "\`${STRFRY_BIN} scan\` failed; a relay that \
will not answer must never be read as a relay holding nothing"
    return 1
  fi
  if [[ "${prescan}" != "0" ]]; then
    backlog_host_fail prescan "the relay already held the staged event \
before the import (${prescan} hit(s)) — it got there from the device"
    return 1
  fi

  # No `--no-verify`: the signature check is a feature here. It is the last
  # thing standing between "a genuine kind-445 crossed the gap" and "some
  # bytes were written into a database".
  if ! printf '%s\n' "${payload}" \
       | docker exec -i "${STRFRY_CONTAINER}" "${STRFRY_BIN}" import \
         >> "${HOST_LOG}" 2>&1; then
    backlog_host_fail import "\`${STRFRY_BIN} import\` returned non-zero; \
see the lines above it in ${HOST_LOG}"
    return 1
  fi

  # STRFRY'S OWN ACCOUNTING, read before the post-scan. A zero exit says
  # nothing about what was written, and the post-scan alone can only report
  # THAT nothing was — which is how run 31868809387 spent a lane pointing at
  # LMDB visibility when the payload had simply never been parsed.
  read -r processed added rejected <<<"$(b9_import_counts "${HOST_LOG}")"
  if [[ -z "${added}" ]]; then
    backlog_host_fail import "\`${STRFRY_BIN} import\` printed no \
\`Done. Processed …\` summary, so there is no accounting to read and its exit \
status is not evidence that anything was written"
    return 1
  fi
  if [[ "${added}" != "1" ]]; then
    backlog_host_fail import "\`${STRFRY_BIN} import\` exited 0 without \
adding the event (processed=${processed} added=${added} \
rejected=${rejected}). processed=0 means the payload was not one parseable \
JSON line; rejected>0 means strfry's ingest validation refused the event \
itself"
    return 1
  fi

  # POST-SCAN — the store is read back rather than inferred from the summary.
  # Now that the accounting gate above rules out "strfry never wrote it", this
  # is narrowly the STORAGE question it was always meant to be: strfry counted
  # an event it cannot find again means a second LMDB env or a read-only
  # mount, NOT a payload it discarded.
  if ! postscan="$(backlog_scan_count "${id}")"; then
    backlog_host_fail postscan "\`${STRFRY_BIN} scan\` failed after the \
import, so there is no evidence the store changed"
    return 1
  fi
  if [[ "${postscan}" == "0" ]]; then
    backlog_host_fail postscan "\`${STRFRY_BIN} import\` counted the event as \
added but the relay does not hold it — a SILENT NO-OP import. The payload \
parsed, so look at the STORE: a second LMDB env or a read-only mount, not the \
event"
    return 1
  fi

  # And re-read the toggle: if connectivity came back mid-import, the device
  # may have been able to receive the event live and the claim collapses.
  air_after="$(airplane_state)"
  if [[ "${air_after}" != "1" ]]; then
    backlog_host_fail airplane "connectivity returned WHILE the import was \
running (airplane_mode_on=${air_after:-<unreadable>}), so the device may have \
been able to receive the event live"
    return 1
  fi

  printf '%s %s airplane_before=%s airplane_after=%s prescan=%s postscan=%s\n' \
    "$(date -u +%H:%M:%S)" "${MARK_HOST_IMPORTED}" \
    "${air_before}" "${air_after}" "${prescan}" "${postscan}" >> "${HOST_LOG}"
  echo "  backlog event imported into strfry with the guest still in" \
       "airplane mode (prescan=${prescan} postscan=${postscan})"
  return 0
}

# ---------------------------------------------------------------------------
# Phase 0 — hermetic relay + device readiness.
# ---------------------------------------------------------------------------
echo "Phase 0/6 — starting hermetic strfry..."
bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device
echo "Phase 0/6 — device ready."

# ---------------------------------------------------------------------------
# Phase 1 — clean install. Force-stop + uninstall FIRST so no sticky state
# from a prior target survives into this run.
# ---------------------------------------------------------------------------
echo "Phase 1/6 — installing ${APK}..."
[[ -f "${APK}" ]] || fail "APK not found: ${APK} (was the build step skipped?)"
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"

# ---------------------------------------------------------------------------
# Phase 2 — runtime permissions, best-effort by design.
#
# This lane injects `FakeLocationService` for Alice's own position (the
# RECEIVE path is the subject), so no real GPS and no verified location grant
# is needed — unlike B3/B6, where the grant is a gate. POST_NOTIFICATIONS is
# granted so the foreground-service notification channel never blocks
# startup; the location grants are requested only so the app's own startup
# path takes its ordinary branch rather than a permission-denied one.
# ---------------------------------------------------------------------------
echo "Phase 2/6 — granting runtime permissions (best-effort)..."
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.POST_NOTIFICATIONS
do
  adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}" 2>&1 | sed 's/^/    /' \
    || true
done

# ---------------------------------------------------------------------------
# Phase 3 — connectivity precondition: airplane mode OFF, verified.
#
# Checked BEFORE the drive rather than discovered at the toggle: a device
# whose airplane mode cannot be driven from the shell cannot run this lane at
# all, and finding that out 6 minutes into a drive wastes the whole run.
# ---------------------------------------------------------------------------
echo "Phase 3/6 — verifying the guest starts with connectivity..."
: > "${NET_LOG}"
: > "${HOST_LOG}"
if ! set_airplane 0; then
  fail "could not put the guest into a known-connected state:" \
       "\`settings get global airplane_mode_on\` did not read 0 after" \
       "\`cmd connectivity airplane-mode disable\`. This lane's whole" \
       "mechanism is that toggle, so it cannot run on this device."
fi

# ---------------------------------------------------------------------------
# Phase 4 — drive the target IN THE BACKGROUND and cut the network under it.
#
# The drive must be backgrounded because the outage happens MID-session: the
# subject is one continuous session that loses its relay connection and has
# to get it back, which a sequence of separate drives cannot express (each
# would start a fresh process, connect once, and never experience a drop at
# all).
#
# No `--keep-app-running`: nothing has to outlive the drive, and letting
# `flutter drive` stop the app afterwards keeps this lane from leaving a live
# MLS session behind for the next job on the runner (Rule 14).
# ---------------------------------------------------------------------------
echo "Phase 4/6 — capturing logcat and driving ${TARGET}..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!

: > "${DRIVE_LOG}"
(
  cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}"
) > "${DRIVE_LOG}" 2>&1 &
DRIVE_PID=$!

# --- Toggle sequence. Each stage is DEFERRED on failure rather than fatal:
# the oracle's findings are this lane's deliverable and stay readable as long
# as the capture is complete, so we always drain the drive and always restore
# connectivity before reporting.
toggle_failed=0
toggle_reason=""

echo "Phase 4/6 — waiting for the drive to arm (${MARK_AWAIT_DOWN})..."
if wait_for_marker "${MARK_AWAIT_DOWN}" "${ARM_MARKER_TIMEOUT}"; then
  echo "Phase 4/6 — dropping the network (L1 airplane mode + L2 port REJECT)..."
  host_block_install
  if ! set_airplane 1; then
    toggle_failed=1
    toggle_reason="\`cmd connectivity airplane-mode enable\` did not take \
(settings still read $(airplane_state)); the drop degraded to the host-side \
port REJECT alone, so any outage the drive observed was relay \
unreachability, NOT device-wide network loss"
    echo "WARN: ${toggle_reason}" >&2
  fi

  echo "Phase 4/6 — waiting for the outage window to complete" \
       "(${MARK_AWAIT_UP})..."
  if wait_for_marker "${MARK_AWAIT_UP}" "${OUTAGE_MARKER_TIMEOUT}"; then
    # THE BACKLOG IMPORT GOES HERE, and only here. The drive prints
    # BACKLOG_STAGED immediately before the cue we just observed, so the file
    # is on disk by now; and the restore below has not happened yet, so the
    # guest is still partitioned. Waiting on AWAIT_UP rather than on
    # BACKLOG_STAGED is deliberate: it gives one ordering guarantee instead of
    # two racing waits, and it cannot burn the drive's own 120 s restore
    # window on a marker that is already there.
    echo "Phase 4/6 — importing the backlog event (guest still offline)..."
    backlog_import || true
    echo "Phase 4/6 — restoring the network..."
  else
    toggle_failed=1
    toggle_reason="the drive never reached ${MARK_AWAIT_UP}"
    backlog_host_fail cue "the drive never reached ${MARK_AWAIT_UP}, so the \
backlog event was never imported and the backlog proof could not run" || true
  fi
  # Restore unconditionally: the drive's recovery phase must be able to run
  # and record evidence, and the runner must not be left disconnected.
  host_block_remove
  if ! set_airplane 0; then
    toggle_failed=1
    toggle_reason="airplane mode could not be turned back off"
  fi
else
  toggle_failed=1
  toggle_reason="the drive never reached ${MARK_AWAIT_DOWN}"
  backlog_host_fail cue "the drive never armed, so the network was never \
dropped and no backlog event was ever staged or imported" || true
fi

echo "Phase 5/6 — draining the drive..."
drc=0
wait "${DRIVE_PID}" || drc=$?
DRIVE_PID=""

# Scan BEFORE echoing. The EXIT trap's scan runs far too late to protect the
# STEP log, which has no retention control and cannot be redacted after the
# fact — a wider, more permanent sink than the artifact upload.
drive_log_clean=1
if bash "${SECRET_SCAN}" "${DRIVE_LOG}"; then
  cat "${DRIVE_LOG}" || true
else
  drive_log_clean=0
  echo "drive log withheld from the step log — secret-leak guard tripped." >&2
fi

# Record the drive's verdict WITHOUT exiting on it yet: the oracle below reads
# the capture, and its findings are the point of this lane. `drc == 0` alone
# is not trustworthy — `flutter drive` exits 0 when the failure happened
# outside a `testWidgets` body, and when nothing ran (drive-log-lib.sh).
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
       "its findings are this lane's deliverable. This is re-raised as a" \
       "failure at the end regardless of the oracle's verdict." >&2
  if (( drive_log_clean == 1 )); then
    drive_log_failure_evidence "${DRIVE_LOG}" >&2
  else
    echo "  (evidence withheld — secret-leak guard tripped on this log)" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Phase 6 — the oracle. Reads over a complete capture; no live polling.
# ---------------------------------------------------------------------------
echo "Phase 6/6 — asserting the network-loss/reconnect sequence..."
oracle_rc=0
b9_run_oracle "${LOGCAT_FILE}" "${HOST_LOG}" || oracle_rc=$?

if (( oracle_rc != 0 )); then
  echo "---- network toggle log ----" >&2
  cat "${NET_LOG}" >&2 2>/dev/null || true
  echo "---- backlog import log ----" >&2
  cat "${HOST_LOG}" >&2 2>/dev/null || true
  {
    echo "B9 findings (${#B9_FINDINGS[@]}):"
    for finding in "${B9_FINDINGS[@]}"; do
      echo "  * ${finding}"
    done
  } >&2
  fail "the network-loss/reconnect sequence did not hold — see the" \
       "${#B9_FINDINGS[@]} finding(s) above."
fi

if (( toggle_failed == 1 )); then
  fail "the oracle passed, but the harness network sequence did not:" \
       "${toggle_reason}. Treat the lane as RED — a sequence that did not" \
       "produce the outage it claims cannot have measured what the oracle" \
       "just blessed."
fi

if (( drive_failed == 1 )); then
  fail "the oracle passed, but ${drive_reason}. Treat the lane as RED —" \
       "a drive that dies early can truncate the very capture the oracle" \
       "measures."
fi

echo "B9 PASS — live receive was up, the app lost the network device-wide," \
     "and a PEER location published after connectivity returned was" \
     "decrypted and surfaced. Read the BACKLOG note above for whether the" \
     "backlog-replay claim was PROVEN on this run or left unproven by the" \
     "228s kind-445 TTL — a green lane does not imply the former."
