#!/usr/bin/env bash
#
# summarize-created-at-gaps.sh — the relay-side LIVENESS oracle for the
# owner-run hardware power measurements (docs/POWER_MEASUREMENT.md, which is
# the copy-out of docs/POWER_EFFICIENCY_PLAN.md §6.5).
#
# Those measurements are DEFERRED and none has been taken: there is no iPhone,
# no macOS machine and no Android handset (plan §2.5). Two consequences for
# anyone reading this file as evidence. (1) §6.6 re-bases the LIVENESS gate onto
# this same grader run over an EMULATOR or SIMULATOR lane's own relay capture —
# same instrument, smaller subject, shorter window. (2) No lane feeds it one
# yet: the only invocation in the tree is `--self-test` (repo-guards.yml), which
# proves the instrument and says nothing about any build. A green run of this
# script is a liveness result only for the capture it was given.
#
# ## Why this exists
#
# Every battery number in POWER_MEASUREMENT.md can be improved by DOING LESS,
# and the cheapest possible Haven publishes nothing at all. So a discharge-rate
# figure on its own cannot tell a power WIN from a power REGRESSION that
# silently stopped sharing — the exact field failure
# docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md was written for. Every run therefore has to carry independent proof that
# location updates never stopped, and that proof cannot come from:
#
#   * the app under test — the defendant testifying; a wedged publisher is
#     usually still convinced it is publishing, and
#   * the receiving phone's screen — the peer's foreground-service fetch runs
#     once per `kLocationUpdateInterval` and the age pill only thresholds at
#     5 min, so a perfectly healthy run routinely READS as 168 + 120 s stale.
#
# It comes from the relay: the sequence of `created_at` values the device under
# test actually landed there.
#
# ## The bound this checks, and where it comes from
#
# haven/lib/src/constants/location.dart states the no-gap invariant: a relay
# must always hold a NON-EXPIRED location event from every active publisher.
# The engine stamps every kind-445 location message with a NIP-40 `expiration`
# of `created_at + LOCATION_MESSAGE_RETENTION_SECS` — 228 s, pinned at
# haven-core/src/location/ttl.rs:85 — and the publish cadence is jittered into
# [72 s, 168 s] with `kLocationPublishMaxInterval = 168 s` as the ceiling
# (haven/lib/src/constants/location.dart). So:
#
#   * a consecutive gap > 228 s is a window in which peers held NO position for
#     this device. That is a broken promise, and the default failure bound.
#   * a consecutive gap > 168 s means a publish tick was late, which is inside
#     the promise but outside the cadence — worth seeing, so it gets its own
#     distribution bucket rather than being averaged away.
#
# The bound is PER ANDROID API LEVEL on EVERY Android row, and it is passed
# explicitly. It is not a property of the row's phase: on API 23-30 the shipped
# delivery-driven regime pays two acquisitions and has no delayed register, so
# plan D3 (iii)'s ACCEPTED cold residual reaches 248 s there, and a BASELINE row
# taken now is a row of that same shipped build (POWER_MEASUREMENT.md §3.5:
# "a baseline row taken now is a row of the SHIPPED build"). So:
#
#   * iOS, and Android API 31+, baseline row      the 228 s default
#   * Android API 23-30, ANY row                  --max-gap 248
#   * Android API 31+, post-P2a acceptance row    --max-gap 198
#
# Grading an API 23-30 capture against the 228 s default therefore REDS a
# legitimate run: this header scoped the split to acceptance rows until
# 2026-09-09 and contradicted POWER_MEASUREMENT.md, which has said otherwise
# since 2026-09-04. 248 is an accepted defect with a named trigger (`Api.legacy`
# AND a cold acquisition AND `J + rho + sigma >= 178 s`), never a passing
# invariant, so the row records its API level or the number cannot be read.
#
# The 198 s figure said 188 until 2026-09-08; §6.5 of the plan retracted that on
# 2026-09-04 as an artefact of a sweep that held sigma = 0, and §6.6 forbids any
# tighter post-P2a figure as a threshold. The default 228 is unchanged: it is the
# retention, and it stays the right bound wherever the residual does not apply.
#
# ## Why not summarize-wire-journal.sh
#
# That script redacts the wire-PROXY ndjson journal — an in-CI MITM transcript
# of a whole relay conversation (tooling/e2e/ci/summarize-wire-journal.sh).
# This one reads a RELAY capture: a different instrument, a different format,
# a different question. Neither can read the other's input.
#
# ## "Per author" on kind 445, honestly
#
# There is no stable author on the wire. Marmot Security Rule 2 requires a NEW
# ephemeral keypair for EVERY kind-445, so `pubkey` is unique per event and
# grouping by it yields nothing but one-event series (`--group-by pubkey` will
# say so out loud). The only stable series key a relay capture carries is the
# `h` tag — the public `nostr_group_id` — which identifies the CIRCLE, not the
# device. Consequences, stated rather than hidden:
#
#   * A capture from a relay that only the device under test publishes to IS a
#     per-device stream, reported as one series per capture file under the
#     default `file+h` grouping. Grade it with `--publishers 1`.
#   * Haven cannot currently produce such a capture for a LIVE 2-member circle:
#     a circle's relay set is fixed at creation and every member publishes to
#     ALL of it (haven/integration_test/relay_customization_publish_test.dart,
#     "per-circle 445 lands on BOTH relays"), so no relay exists that only one
#     device writes to. A capture of a live circle is therefore a CIRCLE
#     stream: its gaps are interleaved, so they are shorter than either
#     device's own gaps, and a healthy peer masks a dead device under test.
#     Declare it with `--publishers 2` — the verdict then says so out loud, and
#     the two event-count floors below become the instrument that can still see
#     a device drop out. Never quote a multi-publisher gap as device evidence.
#
# ## The event-count floors, and why there are two
#
# A publisher whose gaps are all <= `--max-interval` emits at least
# `floor(W / max-interval)` events in any window of W seconds it is alive for,
# so N publishers emit at least `N * floor(W / max-interval)`. Fewer than that
# means a publisher went quiet even when the INTERLEAVED gaps look healthy.
#
#   * The WHOLE-SPAN floor takes W from the DECLARED run window (`--from` /
#     `--until`, below), so it catches both a device that never really started
#     and one that stopped: the events it never published are simply missing
#     from the count. Taken over the OBSERVED span instead it would catch only
#     the first, which is why the window is required.
#   * The SLIDING-WINDOW floor (`--window`, default 1800 s) applies the same
#     arithmetic to every 1800 s window that fits inside the OBSERVED span. It
#     is what catches a device that died behind a still-publishing peer, whose
#     events keep the observed span running past the death. It CANNOT see a
#     lone publisher's death: that death ends the observed span, so there is no
#     window after it to fail. That case belongs to the tail gap, below.
#
# Both are conservative: a publisher that met the cadence clears them with an
# event to spare, so neither can fail a healthy run.
#
# ## The declared run window: `--from` / `--until`, and why they are required
#
# A capture's OBSERVED span is `last - first` over the events in it, so silence
# BEFORE the first event and AFTER the last one is invisible to it. A device
# that publishes for 30 min of a declared 3 h run and then dies observes a
# clean 30 min; so does one that stays silent for 2.5 h and then publishes for
# 30 min. Both are the field failure this instrument exists to catch, and both
# read as "worst gap 120 s, OK" against the observed span alone.
#
# Head and tail silence can therefore only be graded against the window the
# OPERATOR declares - which POWER_MEASUREMENT.md §1 already has them record.
# `--from` and `--until` (epoch seconds; the battery window's own start and
# end) are what makes a verdict gradeable:
#
#   * `first - from` and `until - last` are graded as gaps like any other, and
#     appear in the report naming the window edge instead of an event id;
#   * the whole-span event-count floor's W is that declared window;
#   * without them the run still prints its per-series report - that is the
#     §3.2 discovery listing - but every verdict is UNGRADED and the exit code
#     is 5. An un-graded run is never recorded as a pass.
#
# Events outside the declared window are kept rather than dropped: the head and
# tail gaps clamp at zero and the floor's W spans the union, so a capture
# started early and stopped late grades exactly as it should and can never
# yield a negative gap.
#
# ## Input format (this is the contract POWER_MEASUREMENT.md's capture step
# ## produces; nothing else is accepted)
#
# NDJSON: one JSON value per line, UTF-8, no wrapping array. Each line is
# either
#
#   (a) a bare Nostr event object, as emitted by `strfry scan '<filter>'`,
#       `strfry export` and `nak req`:
#
#         {"id":"<64-hex>","pubkey":"<64-hex>","created_at":1756540800,
#          "kind":445,"tags":[["h","<32-hex>"],["expiration","1756541028"]],
#          "content":"...","sig":"..."}
#
#   (b) a relay-to-client message array whose first element is "EVENT", as
#       emitted by raw WebSocket captures:
#
#         ["EVENT","<subid>",{ ...the same event object... }]
#
# Both shapes may be mixed in one file. Blank lines are ignored. Only `id`,
# `created_at`, `kind`, `pubkey` and `tags` are read; every other field is
# ignored, so a capture tool that adds fields stays compatible.
#
# Robustness rules, each chosen so a broken capture can never read as a clean
# run (this repo's recurring false-green shape):
#
#   * Events are SORTED by `created_at` before gapping. Relay exports and
#     `nak req` commonly return newest-first; a script that trusted file order
#     would report negative or nonsense gaps.
#   * Identical events are DEDUPED by id within a series, so the streaming
#     capture and an end-of-run export can be concatenated into one file.
#   * By default only kind 445 carrying a NIP-40 `expiration` tag is counted.
#     That tag is the location-message discriminator: kind 445 also carries MLS
#     commits and proposals, which carry NO expiration
#     (haven-core/src/circle/manager.rs,
#     `evolution_commit_carries_no_expiration_tag`) and which would otherwise
#     shorten a gap and hide a breach. `--include-commits` drops the
#     requirement.
#   * An unparseable line is fatal, EXCEPT a single unparseable LAST line,
#     which is warned about and dropped — that is the ordinary artifact of
#     stopping a streaming capture mid-write, and nothing else.
#   * A capture that yields no usable events after filtering is UNUSABLE
#     (exit 3), never "no gaps found, all clear".
#   * A series with fewer than two events is a FAILURE, not a pass: one
#     observation bounds nothing.
#   * Two capture files carrying the SAME `h` are two views of ONE circle, and
#     the default `file+h` grouping would grade them as two independent series
#     - so the seam between them (a stream restarted after a laptop sleep)
#     would never be graded at all. That is refused (exit 3) with the fix
#     named: concatenate them into one file, which the id dedupe makes safe.
#     Silently merging them here would be worse, because two files from two
#     RELAYS would fill each other's gaps, and a gap at one relay is a real
#     breach for the peers reading that relay.
#
# ## Usage
#
#   bash tooling/e2e/ci/summarize-created-at-gaps.sh [OPTIONS] <capture.ndjson>...
#   bash tooling/e2e/ci/summarize-created-at-gaps.sh --self-test
#
#   --max-gap SECS       Fail above this consecutive `created_at` delta.
#                        Default 228 = LOCATION_MESSAGE_RETENTION_SECS, which is
#                        the bound for iOS and for Android API 31+ baseline rows.
#                        Pass 248 for ANY Android API 23-30 row, baseline
#                        included (D3 (iii)'s accepted cold residual), and 198
#                        for an API 31+ post-P2a acceptance row — never a tighter
#                        figure; see the header.
#   --max-interval SECS  Publish-cadence ceiling, used for the distribution
#                        buckets and the event-count floor. Default 168 =
#                        kLocationPublishMaxInterval.
#   --publishers N       Distinct publishing devices expected in each series.
#                        REQUIRED: there is no safe default. The protocol's
#                        normal case is a 2-member circle, and declaring 1 for
#                        one halves every event-count floor and hides a device
#                        that dropped out behind a healthy peer. Anything above
#                        1 marks the series as circle-level, not device-level,
#                        evidence.
#   --from EPOCH         The declared run window, in epoch seconds: the battery
#   --until EPOCH        window's own start and end, which POWER_MEASUREMENT.md
#                        §1 already records. Given together, and required for a
#                        gradeable verdict - without them head and tail silence
#                        is never graded, so every verdict is UNGRADED (exit 5).
#   --window SECS        Sliding-window width for the per-window event-count
#                        floor. Default 1800; 0 disables it. Windows that do
#                        not fit inside the observed span are not graded.
#   --kind LIST          Comma-separated event kinds to include, or `any`.
#                        Default 445.
#   --include-commits    Do not require a NIP-40 `expiration` tag (includes
#                        MLS commits/proposals).
#   --group-by KEY       `file+h` (default), `h`, or `pubkey`. See the "per
#                        author" note above before reaching for `pubkey`.
#   --series HEX[,HEX]   Only report series whose `h` tag is one of these.
#                        Needed when capturing from a shared public relay that
#                        also carries other people's circles.
#   --self-test          Run the built-in fixtures and exit.
#
# ## Exit codes
#
#   0 = every series was readable, inside every bound, and graded against a
#       declared run window
#   1 = a bound was breached (gap, event-count floor, or a series too short to
#       bound anything)
#   2 = usage error, or `jq` is not installed
#   3 = the capture could not be read: absent, unreadable, empty, malformed
#       mid-file, missing the `h` tag it is grouped by, holding no event that
#       survived filtering, or split across files sharing one `h`; also the
#       grading pass failing INTERNALLY, which must never be mistaken for the
#       breach code. This run proves NOTHING either way, which is a different
#       answer from "clean" and gets a different code — the same convention as
#       tooling/e2e/ci/scan-logs-for-secrets.sh.
#   4 = `--self-test` failed. Distinct from 1 because a broken instrument and a
#       broken run are not the same finding.
#   5 = UNGRADED: readable, and inside every bound it could apply, but no
#       `--from`/`--until` was given, so head and tail silence went ungraded.
#       Never recorded as a pass. `--help` exits 0.

set -euo pipefail

readonly RC_CLEAN=0
readonly RC_BREACH=1
readonly RC_USAGE=2
readonly RC_UNUSABLE=3
readonly RC_SELFTEST=4
readonly RC_UNGRADED=5

SELF_PATH="${BASH_SOURCE[0]}"
readonly SELF_PATH
readonly TAB=$'\t'

# Defaults. Every one of these is a constant that lives in the tree; the
# comment names the file so a drift is a one-grep check, not a memory test.
MAX_GAP=228        # haven-core/src/location/ttl.rs:85
MAX_INTERVAL=168   # haven/lib/src/constants/location.dart
PUBLISHERS=''      # no default: see --publishers in the header
FROM=''            # the declared run window; no default, see --from/--until
UNTIL=''
WINDOW=1800
KINDS=445
REQUIRE_EXPIRATION=1
GROUP_BY='file+h'
SERIES_FILTER=''

usage() {
  cat <<'USAGE'
Usage: summarize-created-at-gaps.sh --publishers N --from EPOCH --until EPOCH \
                                   [OPTIONS] <capture.ndjson>...
       summarize-created-at-gaps.sh --self-test

  --publishers N       publishing devices expected per series (REQUIRED)
  --from EPOCH         declared run window start, epoch seconds
  --until EPOCH        declared run window end, epoch seconds
                       (--from/--until are given together; without them every
                        verdict is UNGRADED and the exit code is 5)
  --max-gap SECS       fail above this created_at delta (default 228; pass 248
                       on ANY Android API 23-30 row, 198 on an API 31+
                       post-P2a acceptance row)
  --max-interval SECS  cadence ceiling for buckets + count floor (default 168)
  --window SECS        sliding-window width for the count floor (default 1800)
  --kind LIST|any      event kinds to include (default 445)
  --include-commits    do not require a NIP-40 expiration tag
  --group-by KEY       file+h (default) | h | pubkey
  --series HEX[,HEX]   restrict to these `h` tag values
  --self-test          run the built-in fixtures

Exit: 0 clean+graded, 1 bound breached, 2 usage/no jq, 3 capture unusable,
      4 self-test failed, 5 ungraded (no --from/--until).
USAGE
}

die_usage() { # <message>
  echo "ERROR: $1" >&2
  usage >&2
  exit "${RC_USAGE}"
}

# A positive integer, and nothing that merely starts like one. `228s` and `-5`
# both have to be rejected here or they silently become 228 and 0 in awk.
require_uint() { # <flag> <value>
  case "$2" in
    ''|*[!0-9]*) die_usage "$1 needs a non-negative integer, got '$2'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
INPUTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test)      RUN_SELF_TEST=1; shift ;;
    --max-gap)        [[ $# -ge 2 ]] || die_usage "--max-gap needs a value"
                      require_uint --max-gap "$2"; MAX_GAP="$2"; shift 2 ;;
    --max-interval)   [[ $# -ge 2 ]] || die_usage "--max-interval needs a value"
                      require_uint --max-interval "$2"; MAX_INTERVAL="$2"; shift 2 ;;
    --publishers)     [[ $# -ge 2 ]] || die_usage "--publishers needs a value"
                      require_uint --publishers "$2"
                      [[ "$2" -ge 1 ]] || die_usage "--publishers must be >= 1"
                      PUBLISHERS="$2"; shift 2 ;;
    --from)           [[ $# -ge 2 ]] || die_usage "--from needs a value"
                      require_uint --from "$2"; FROM="$2"; shift 2 ;;
    --until)          [[ $# -ge 2 ]] || die_usage "--until needs a value"
                      require_uint --until "$2"; UNTIL="$2"; shift 2 ;;
    --window)         [[ $# -ge 2 ]] || die_usage "--window needs a value"
                      require_uint --window "$2"; WINDOW="$2"; shift 2 ;;
    --kind)           [[ $# -ge 2 ]] || die_usage "--kind needs a value"
                      KINDS="$2"; shift 2 ;;
    --include-commits) REQUIRE_EXPIRATION=0; shift ;;
    --group-by)       [[ $# -ge 2 ]] || die_usage "--group-by needs a value"
                      case "$2" in
                        'file+h'|h|pubkey) GROUP_BY="$2" ;;
                        *) die_usage "--group-by must be file+h, h or pubkey" ;;
                      esac
                      shift 2 ;;
    --series)         [[ $# -ge 2 ]] || die_usage "--series needs a value"
                      SERIES_FILTER="$2"; shift 2 ;;
    -h|--help)        usage; exit "${RC_CLEAN}" ;;
    -*)               die_usage "unknown option '$1'" ;;
    *)                INPUTS+=("$1"); shift ;;
  esac
done

if [[ "${KINDS}" != "any" ]]; then
  case "${KINDS}" in
    ''|*[!0-9,]*) die_usage "--kind takes a comma-separated kind list or 'any'" ;;
  esac
fi
if [[ "${MAX_INTERVAL}" -gt "${MAX_GAP}" ]]; then
  die_usage "--max-interval (${MAX_INTERVAL}) must not exceed --max-gap (${MAX_GAP})"
fi

# ---------------------------------------------------------------------------
# Normalisation: NDJSON -> TSV, one record per input LINE.
#
# jq rather than a hand-rolled parser because the two accepted line shapes,
# the tag array and the "a field has the wrong type" cases are all structural,
# and a regex over JSON is how a capture with an integer `id` gets read as a
# valid event. Every type is checked: anything that is not an event becomes a
# BAD record carrying only its line NUMBER, never its content.
# ---------------------------------------------------------------------------
readonly JQ_NORMALISE='
  input_line_number as $ln
  | select(test("[^[:space:]]"))
  | (try fromjson catch null) as $j
  | ( if   ($j|type) == "array" and ($j|length) >= 3 and ($j[0] == "EVENT")
      then $j[2]
      elif ($j|type) == "object" then $j
      else null end ) as $e
  | if ($e|type) != "object"
       or ($e.id|type) != "string"
       or ($e.created_at|type) != "number"
       or ($e.kind|type) != "number"
    then "BAD\t\($file)\t\($ln)"
    else
      ( [ $e.tags[]?
          | select((type == "array") and (length >= 2) and (.[0] == "h"))
          | .[1] ]
        | map(select(type == "string")) | first ) as $h
      | ( [ $e.tags[]?
            | select((type == "array") and (length >= 2) and (.[0] == "expiration"))
            | .[1] ] | first ) as $x
      | ( if   $x == null then null
          elif ($x|type) == "string" then ($x | tonumber? // "?")
          elif ($x|type) == "number" then $x
          else "?" end ) as $xn
      | "EV\t\($file)\t\($ln)\t\($e.id)\t\($e.created_at)\t\($e.pubkey // "")\t\($e.kind)\t\($h // "")\t\(if $x == null then 0 else 1 end)\t\(if ($xn == null or $xn == "?") then "" else ($xn - $e.created_at) end)"
    end
'

unusable() { # <message...>
  printf 'UNUSABLE: %s\n' "$@" >&2
  echo "RESULT: UNUSABLE - the capture proves nothing either way." >&2
  exit "${RC_UNUSABLE}"
}

main() {
  if [[ ${#INPUTS[@]} -eq 0 ]]; then
    die_usage "no capture file given"
  fi
  # `--publishers` has no default because both possible defaults are wrong for
  # half the captures, and being wrong the SAFE way is not an option: 1 against
  # a 2-publisher capture halves every floor and passes a device that dropped
  # out. The operator knows the number; make them say it.
  if [[ -z "${PUBLISHERS}" ]]; then
    die_usage "--publishers is required (2 for a live 2-member circle, 1 only for a window in which the peer published nothing)"
  fi
  if [[ -n "${FROM}" && -z "${UNTIL}" ]] || [[ -z "${FROM}" && -n "${UNTIL}" ]]; then
    die_usage "--from and --until are given together - one alone grades neither end of the window"
  fi
  local declared=0
  if [[ -n "${FROM}" ]]; then
    if [[ "${UNTIL}" -le "${FROM}" ]]; then
      die_usage "--until (${UNTIL}) must be after --from (${FROM})"
    fi
    declared=1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to parse the NDJSON capture but was not found." >&2
    echo "       Install it (brew install jq / apt-get install jq) and re-run." >&2
    exit "${RC_USAGE}"
  fi

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT

  local norm="${tmp}/norm.tsv"
  : > "${norm}"

  # Labels come from the file's basename, because that is what the operator
  # names after the device ("dut-stationary.ndjson"). Collisions are broken
  # apart rather than merged: two devices' streams silently sharing one series
  # would interleave into gaps that look healthy — the false green this whole
  # script exists to prevent.
  local -a used_labels=()
  local f label base i n
  for f in "${INPUTS[@]}"; do
    [[ -e "${f}" ]] || unusable "${f} [absent] - the capture file does not exist."
    [[ -f "${f}" ]] || unusable "${f} [not a regular file] - refusing to read."
    [[ -r "${f}" ]] || unusable "${f} [unreadable] - permission denied."
    [[ -s "${f}" ]] || unusable "${f} [empty] - 0 bytes; the capture never wrote anything."

    base="$(basename "${f}")"
    base="${base%.ndjson}"
    base="${base%.json}"
    label="${base}"
    n=1
    for i in "${used_labels[@]:-}"; do
      if [[ "${i}" == "${label}" ]]; then
        n=$(( n + 1 ))
        label="${base}#${n}"
      fi
    done
    used_labels+=("${label}")

    if ! jq -Rr --arg file "${label}" "${JQ_NORMALISE}" -- "${f}" >> "${norm}"; then
      unusable "${f} [jq failed] - the file is not line-delimited JSON."
    fi
  done

  # --- malformed lines -----------------------------------------------------
  # One unparseable LAST line is a stream stopped mid-write; anything else is
  # a capture with a hole in it, and a hole can hide a gap.
  local bad_report="${tmp}/bad.txt"
  awk -F"${TAB}" '
    { if ($3 + 0 > maxln[$2]) maxln[$2] = $3 + 0 }
    $1 == "BAD" { bad[$2] = bad[$2] " " $3; nbad[$2]++; last[$2] = $3 + 0 }
    END {
      for (f in nbad) {
        if (nbad[f] == 1 && last[f] == maxln[f])
          printf "TAIL\t%s\t%d\n", f, last[f]
        else
          printf "FATAL\t%s\t%d\t%s\n", f, nbad[f], bad[f]
      }
    }
  ' "${norm}" > "${bad_report}"

  if grep -q '^FATAL' "${bad_report}"; then
    while IFS="${TAB}" read -r _ f count lines; do
      echo "UNUSABLE: ${f} [malformed] - ${count} line(s) are not a Nostr event: ${lines}" >&2
    done < <(grep '^FATAL' "${bad_report}")
    echo "          (line numbers only - the content is never echoed.)" >&2
    echo "RESULT: UNUSABLE - the capture proves nothing either way." >&2
    exit "${RC_UNUSABLE}"
  fi
  while IFS="${TAB}" read -r _ f lineno; do
    [[ -n "${f}" ]] || continue
    echo "NOTE: ${f} line ${lineno} is truncated (last line) - dropped." >&2
  done < <(grep '^TAIL' "${bad_report}" || true)

  # --- filter + project ----------------------------------------------------
  local events="${tmp}/events.tsv" stats="${tmp}/stats.tsv"
  awk -F"${TAB}" -v OFS="${TAB}" \
      -v kinds="${KINDS}" -v needexp="${REQUIRE_EXPIRATION}" \
      -v groupby="${GROUP_BY}" -v serfilter="${SERIES_FILTER}" \
      -v outfile="${events}" -v statfile="${stats}" '
    BEGIN {
      if (kinds != "any") { n = split(kinds, a, ","); for (i = 1; i <= n; i++) want[a[i] + 0] = 1 }
      if (serfilter != "") { n = split(tolower(serfilter), b, ","); for (i = 1; i <= n; i++) wanth[b[i]] = 1 }
    }
    $1 != "EV" { next }
    {
      total++
      file = $2; id = $4; ts = $5 + 0; pk = $6; kind = $7 + 0
      h = tolower($8); hasexp = $9 + 0; delta = $10
      if (kinds != "any" && !(kind in want))    { skip_kind++;   next }
      if (needexp == 1 && hasexp == 0)          { skip_noexp++;  next }
      if (serfilter != "" && !(h in wanth))     { skip_series++; next }
      if (groupby == "pubkey")      key = pk
      else if (groupby == "h")      key = h
      else                          key = file "|" h
      if (groupby != "pubkey" && h == "")       { noh++;         next }
      if (groupby == "file+h" && !((h SUBSEP file) in seen)) {
        seen[h SUBSEP file] = 1
        nfiles[h]++
        hfiles[h] = (hfiles[h] == "" ? file : hfiles[h] ", " file)
      }
      print key, ts, id, delta > outfile
      kept++
    }
    END {
      printf "total\t%d\nkept\t%d\nskip_kind\t%d\nskip_noexp\t%d\nskip_series\t%d\nnoh\t%d\n", \
             total + 0, kept + 0, skip_kind + 0, skip_noexp + 0, skip_series + 0, noh + 0 > statfile
      for (hh in nfiles)
        if (nfiles[hh] > 1) printf "dupser\t%s\t%s\n", hh, hfiles[hh] > statfile
    }
  ' "${norm}"
  [[ -f "${events}" ]] || : > "${events}"

  local s_total s_kept s_kind s_noexp s_series s_noh
  s_total="$(awk -F"${TAB}" '$1=="total"{print $2}' "${stats}")"
  s_kept="$(awk -F"${TAB}" '$1=="kept"{print $2}' "${stats}")"
  s_kind="$(awk -F"${TAB}" '$1=="skip_kind"{print $2}' "${stats}")"
  s_noexp="$(awk -F"${TAB}" '$1=="skip_noexp"{print $2}' "${stats}")"
  s_series="$(awk -F"${TAB}" '$1=="skip_series"{print $2}' "${stats}")"
  s_noh="$(awk -F"${TAB}" '$1=="noh"{print $2}' "${stats}")"

  if [[ "${s_noh}" -gt 0 ]]; then
    unusable "${s_noh} event(s) carry no \`h\` tag but the grouping is '${GROUP_BY}'." \
             "A kind-445 without an \`h\` tag is not a Haven group message; the" \
             "capture filter is wrong, or the file is not a relay capture."
  fi
  if [[ "${s_kept}" -eq 0 ]]; then
    unusable "no event survived filtering (${s_total} read; ${s_kind} wrong kind," \
             "${s_noexp} without a NIP-40 expiration tag, ${s_series} outside --series)." \
             "Either the capture ran against the wrong relay/filter, or the device" \
             "under test published nothing at all - both are findings, not passes."
  fi

  # Two files, one circle: under `file+h` they would be graded as two separate
  # series and the SEAM between them - the outage a restarted stream leaves -
  # would be graded by neither. Refuse rather than merge: files from two
  # RELAYS would fill each other's gaps, and a gap at one relay is a real
  # breach for the peers reading that relay.
  local dupser
  dupser="$(awk -F"${TAB}" '$1=="dupser"{printf "  h %s appears in: %s\n", $2, $3}' "${stats}")"
  if [[ -n "${dupser}" ]]; then
    echo "UNUSABLE: the same circle is split across capture files:" >&2
    printf '%s\n' "${dupser}" >&2
    echo "          Under --group-by file+h each file becomes its own series, so the" >&2
    echo "          seam between them is never graded. Concatenate them into ONE file" >&2
    echo "          (duplicate ids are merged, so that is always safe), or pass" >&2
    echo "          --group-by h if they really are one relay's one stream." >&2
    echo "RESULT: UNUSABLE - the capture proves nothing either way." >&2
    exit "${RC_UNUSABLE}"
  fi

  # --- dedupe + chronological sort ----------------------------------------
  local sorted="${tmp}/events.sorted.tsv"
  LC_ALL=C sort -t"${TAB}" -k1,1 -k2,2n -k3,3 "${events}" | uniq > "${sorted}"
  local raw_count dedup_count dupes
  raw_count="$(wc -l < "${events}" | tr -d ' ')"
  dedup_count="$(wc -l < "${sorted}" | tr -d ' ')"
  dupes=$(( raw_count - dedup_count ))

  # --- per-series meta + gap stream ---------------------------------------
  local meta="${tmp}/meta.tsv" gaps="${tmp}/gaps.tsv"
  : > "${meta}"; : > "${gaps}"
  awk -F"${TAB}" -v OFS="${TAB}" -v META="${meta}" -v GAPS="${gaps}" -v W="${WINDOW}" \
      -v DECL="${declared}" -v FROMTS="${FROM:-0}" -v UNTILTS="${UNTIL:-0}" '
    # The sliding-window floor. Two pointers over the series own chronological
    # timestamps: for every event i whose window [T[i], T[i]+W] still fits
    # inside the observed span, count the events inside it and keep the worst.
    # Windows that run past the last observation are NOT graded - the capture
    # simply stopped there, and grading a partial window would fail every
    # healthy run on its own tail.
    function worst_window(   i, j, c, wc, wat) {
      wc = -1; wat = ""
      if (W <= 0 || (last - first) < W) return wc "\t" wat
      j = 1
      for (i = 1; i <= cnt; i++) {
        if (T[i] + W > last) break
        if (j < i) j = i
        while (j <= cnt && T[j] <= T[i] + W) j++
        c = j - i
        if (wc < 0 || c < wc) { wc = c; wat = T[i] }
      }
      return wc "\t" wat
    }
    # The head and tail gaps ride the SAME stream as the consecutive ones, so
    # they reach every bucket, percentile and bound without a second code path.
    # They clamp at zero: a capture started before the window and stopped after
    # it must never produce a negative gap.
    function flush() {
      if (prev == "") return
      if (DECL + 0 == 1) {
        if (first > FROMTS + 0)
          print prev, (first - FROMTS), FROMTS + 0, first, "(window start)", fid > GAPS
        if (UNTILTS + 0 > last)
          print prev, (UNTILTS - last), last, UNTILTS + 0, pid, "(window end)" > GAPS
      }
      print prev, cnt, first, last, deltas, worst_window() > META
    }
    {
      s = $1; ts = $2 + 0; id = $3; d = $4
      if (s != prev) {
        flush()
        prev = s; cnt = 0; first = ts; deltas = ""; pts = ""; pid = ""; fid = id
        delete T
      }
      cnt++
      last = ts
      T[cnt] = ts
      if (d != "" && index("," deltas ",", "," d ",") == 0)
        deltas = (deltas == "" ? d : deltas "," d)
      if (pts != "") print s, (ts - pts), pts, ts, pid, id > GAPS
      pts = ts; pid = id
    }
    END { flush() }
  ' "${sorted}"

  local gaps_sorted="${tmp}/gaps.sorted.tsv"
  LC_ALL=C sort -t"${TAB}" -k1,1 -k2,2n "${gaps}" > "${gaps_sorted}"

  # --- report --------------------------------------------------------------
  echo "summarize-created-at-gaps.sh - relay-side liveness summary"
  printf '  inputs        : %d file(s), %d event record(s) read\n' "${#INPUTS[@]}" "${s_total}"
  printf '  filtered out  : %d wrong kind, %d without a NIP-40 expiration tag, %d outside --series\n' \
    "${s_kind}" "${s_noexp}" "${s_series}"
  printf '  deduped       : %d duplicate event id(s) merged, %d event(s) analysed\n' \
    "${dupes}" "${dedup_count}"
  printf '  filter        : kind %s%s\n' "${KINDS}" \
    "$( [[ "${REQUIRE_EXPIRATION}" -eq 1 ]] && echo ' carrying a NIP-40 expiration tag' || echo ' (commits/proposals included)')"
  printf '  grouping      : %s\n' "${GROUP_BY}"
  printf '  bounds        : max gap %s s, cadence ceiling %s s, %s publisher(s) per series, %s\n' \
    "${MAX_GAP}" "${MAX_INTERVAL}" "${PUBLISHERS}" \
    "$( [[ "${WINDOW}" -gt 0 ]] && echo "${WINDOW} s count window" || echo 'no count window')"
  if [[ "${declared}" -eq 1 ]]; then
    printf '  run window    : %s -> %s (declared)\n' "${FROM}" "${UNTIL}"
  else
    printf '  run window    : NOT DECLARED - pass --from/--until, or head and tail silence goes ungraded\n'
  fi
  echo

  local rc=0
  awk -F"${TAB}" \
      -v maxgap="${MAX_GAP}" -v maxint="${MAX_INTERVAL}" \
      -v pubs="${PUBLISHERS}" -v groupby="${GROUP_BY}" -v gf="${gaps_sorted}" \
      -v win="${WINDOW}" -v declared="${declared}" \
      -v fromts="${FROM:-0}" -v untilts="${UNTIL:-0}" '
    function pct(s, p,   m, idx) {
      m = ng[s]
      idx = int(p * m); if (idx < p * m) idx++
      if (idx < 1) idx = 1; if (idx > m) idx = m
      return g[s, idx]
    }
    function hms(x,   h, m, sec) {
      h = int(x / 3600); m = int((x % 3600) / 60); sec = x % 60
      return sprintf("%02d:%02d:%02d", h, m, sec)
    }
    BEGIN { declared += 0; fromts += 0; untilts += 0 }
    FILENAME == gf {
      s = $1; ng[s]++
      g[s, ng[s]] = $2 + 0; ga[s, ng[s]] = $3; gb[s, ng[s]] = $4
      gi[s, ng[s]] = $5; gj[s, ng[s]] = $6
      next
    }
    {
      nser++; S[nser] = $1
      CNT[$1] = $2 + 0; FIRST[$1] = $3 + 0; LAST[$1] = $4 + 0; DELTAS[$1] = $5
      WCNT[$1] = $6 + 0; WAT[$1] = $7
    }
    END {
      failed = 0; singles = 0; worst = -1
      for (i = 1; i <= nser; i++) {
        s = S[i]; cnt = CNT[s]; n = ng[s] + 0
        obsfirst = FIRST[s]; obslast = LAST[s]
        # W for the span floor is the DECLARED window where there is one,
        # widened to the union so an event captured outside it still sits
        # inside its own denominator.
        gfirst = (declared && fromts  < obsfirst) ? fromts  : obsfirst
        glast  = (declared && untilts > obslast)  ? untilts : obslast
        span = glast - gfirst
        printf "series %s\n", s
        printf "  events        : %d\n", cnt
        printf "  observed      : %d -> %d  (%d s = %s)\n", \
          obsfirst, obslast, obslast - obsfirst, hms(obslast - obsfirst)
        if (declared)
          printf "  declared      : %d -> %d  (%d s = %s)\n", \
            fromts, untilts, untilts - fromts, hms(untilts - fromts)
        else
          printf "  declared      : none - head and tail silence is NOT graded\n"
        printf "  retention     : expiration - created_at = %s\n", (DELTAS[s] == "" ? "(no expiration tag)" : DELTAS[s])
        if (cnt < 2) {
          singles++
          printf "  gaps          : a single observation bounds nothing\n"
          printf "  verdict       : FAIL - INSUFFICIENT: %d event(s); at least 2 are needed\n\n", cnt
          failed = 1
          continue
        }
        b1 = b2 = b3 = 0
        for (k = 1; k <= n; k++) {
          v = g[s, k]
          if (v <= maxint) b1++; else if (v <= maxgap) b2++; else b3++
        }
        mx = g[s, n]
        if (mx > worst) worst = mx
        floorexp = pubs * int(span / maxint)
        printf "  %-14s: min %d  p50 %d  p90 %d  max %d   (seconds)\n", \
          sprintf("gaps (%d)", n), g[s, 1], pct(s, 0.5), pct(s, 0.9), mx
        printf "  distribution  : <=%ds %d | %d-%ds %d | >%ds %d\n", \
          maxint, b1, maxint + 1, maxgap, b2, maxgap, b3
        printf "  worst gap     : %d s between created_at %s and %s\n", mx, ga[s, n], gb[s, n]
        printf "                  ids %s / %s\n", gi[s, n], gj[s, n]
        printf "  span floor    : %d = %d publisher(s) x floor(%d s / %d s)%s\n", \
          floorexp, pubs, span, maxint, \
          (declared ? " over the declared window" : " over the OBSERVED span")
        winfloor = pubs * int(win / maxint)
        if (win > 0 && WCNT[s] >= 0)
          printf "  window floor  : %d per %d s window; worst observed %d, starting at created_at %s\n", \
            winfloor, win, WCNT[s], WAT[s]
        else if (win > 0)
          printf "  window floor  : not graded - the %d s span is shorter than the %d s window\n", \
            span, win
        v = "OK"
        if (mx > maxgap) {
          v = sprintf("FAIL - LIVENESS: worst gap %d s exceeds the %d s bound", mx, maxgap)
          failed = 1
        } else if (cnt < floorexp) {
          v = sprintf("FAIL - UNDERCOUNT: %d events is below the %d-event span floor; at least one publisher never really started", cnt, floorexp)
          failed = 1
        } else if (win > 0 && WCNT[s] >= 0 && WCNT[s] < winfloor) {
          v = sprintf("FAIL - UNDERCOUNT: only %d events in the %d s window at created_at %s, below the %d-event floor; a publisher went quiet mid-run", WCNT[s], win, WAT[s], winfloor)
          failed = 1
        } else if (!declared) {
          v = "UNGRADED - no --from/--until, so head and tail silence was never graded; not a pass"
          ungraded = 1
        } else if (pubs > 1) {
          v = sprintf("OK (circle-level: %d publishers interleave, so this does NOT attribute to one device)", pubs)
        }
        printf "  verdict       : %s\n\n", v
      }
      if (groupby == "pubkey" && nser > 0 && singles * 2 > nser) {
        printf "HINT: %d of %d pubkey series hold a single event. Kind-445 outer keys are\n", singles, nser
        printf "      EPHEMERAL - a new keypair per message (Marmot Security Rule 2) - so\n"
        printf "      grouping by pubkey can never form a stream. Use --group-by h.\n\n"
      }
      if (failed) {
        printf "RESULT: FAIL - %d series, %d publisher(s) declared, worst gap %d s against a %d s bound\n", \
          nser, pubs, worst, maxgap
        exit 1
      }
      if (ungraded) {
        printf "RESULT: UNGRADED - %d series, %d publisher(s) declared, worst OBSERVED gap %d s within the %d s bound,\n", \
          nser, pubs, worst, maxgap
        printf "        but no run window was declared, so head and tail silence went ungraded. Pass --from/--until.\n"
        exit 5
      }
      printf "RESULT: OK - %d series, %d publisher(s) declared, worst gap %d s within the %d s bound over the declared %d s window\n", \
        nser, pubs, worst, maxgap, untilts - fromts
    }
  ' "${gaps_sorted}" "${meta}" || rc=$?

  case "${rc}" in
    0) exit "${RC_CLEAN}" ;;
    1) exit "${RC_BREACH}" ;;
    5) exit "${RC_UNGRADED}" ;;
    *) echo "UNUSABLE: the grading pass exited ${rc}, which it never does deliberately -" >&2
       echo "          awk failed. Nothing was graded." >&2
       echo "RESULT: UNUSABLE - the capture proves nothing either way." >&2
       exit "${RC_UNUSABLE}" ;;
  esac
}

# ===========================================================================
# --self-test
#
# Fixtures are built here rather than checked in as data files because the
# packet ships exactly two files, and because a fixture that lives beside the
# assertion it feeds cannot drift away from it.
#
# Every case runs the REAL entry point in a child shell and asserts the EXACT
# exit code, never merely "non-zero": "the capture is unreadable" and "the
# capture shows a breach" demand opposite responses from the operator and must
# never be the same observation.
#
# SELF_TEST_FIXTURES is an EQUALITY pin, not a floor. A floor lets a deleted
# fixture hide in the slack - this repo has lost cases that way before. Adding
# or removing a case is a deliberate act: change the number in the same edit.
# ===========================================================================

# _ev <created_at> <h> <nonce> [kind] [retention|-]
# Emits one bare-event NDJSON line. The pubkey is unique per event, exactly as
# the real wire is (Security Rule 2), so no fixture can accidentally suggest a
# stable author. `-` for retention omits the expiration tag, i.e. an MLS
# commit rather than a location message.
_ev() {
  local ts="$1" h="$2" n="$3" kind="${4:-445}" rd="${5:-228}"
  local id pk sig tags
  id="$(printf '%064x' $(( ts * 977 + n )))"
  pk="$(printf '%064x' $(( ts * 131 + n + 7 )))"
  sig="$(printf '%0128x' $(( ts + n )))"
  if [[ "${rd}" == "-" ]]; then
    tags="[[\"h\",\"${h}\"]]"
  else
    tags="[[\"h\",\"${h}\"],[\"expiration\",\"$(( ts + rd ))\"]]"
  fi
  printf '{"id":"%s","pubkey":"%s","created_at":%d,"kind":%d,"tags":%s,"content":"Y2lwaGVy","sig":"%s"}\n' \
    "${id}" "${pk}" "${ts}" "${kind}" "${tags}" "${sig}"
}

# _ev_nohtag <created_at> <nonce> — a kind-445 location message with no `h`.
_ev_nohtag() {
  local ts="$1" n="$2" id pk
  id="$(printf '%064x' $(( ts * 977 + n )))"
  pk="$(printf '%064x' $(( ts * 131 + n + 7 )))"
  printf '{"id":"%s","pubkey":"%s","created_at":%d,"kind":445,"tags":[["expiration","%d"]],"content":"Y2lwaGVy","sig":"00"}\n' \
    "${id}" "${pk}" "${ts}" "$(( ts + 228 ))"
}

# _wrap <file> — rewrite a bare-event capture as ["EVENT","sub",{...}] lines.
_wrap() {
  local f="$1" line
  while IFS= read -r line; do
    printf '["EVENT","haven-power-sub",%s]\n' "${line}"
  done < "${f}"
}

self_test() {
  local -r SELF_TEST_FIXTURES=42
  local tmp checked=0 fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local out="${tmp}/out.txt"

  # expect <want-rc> <description> [--grep <pattern>] -- <args...>
  expect() {
    local want="$1" desc="$2"; shift 2
    local pattern=''
    if [[ "${1:-}" == "--grep" ]]; then pattern="$2"; shift 2; fi
    if [[ "${1:-}" == "--" ]]; then shift; fi
    checked=$(( checked + 1 ))
    local got=0
    bash "${SELF_PATH}" "$@" > "${out}" 2>&1 || got=$?
    if [[ "${got}" != "${want}" ]]; then
      echo "SELF-TEST FAIL: ${desc} - expected rc=${want}, got rc=${got}" >&2
      sed 's/^/    | /' "${out}" >&2
      fail=1
      return
    fi
    if [[ -n "${pattern}" ]] && ! grep -qE -- "${pattern}" "${out}"; then
      echo "SELF-TEST FAIL: ${desc} - rc=${want} as expected but the report is missing /${pattern}/" >&2
      sed 's/^/    | /' "${out}" >&2
      fail=1
      return
    fi
    printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${desc}" "${got}"
  }

  local H1='3f9a1c0d4b6e8a2f5c7d9e1b3a5c7e90'
  local H2='aa11bb22cc33dd44ee55ff6677889900'
  local T=1756540800

  # (1) A healthy stationary run: jittered cadence inside [72, 168], graded
  #     against the window the operator declared for it.
  local healthy="${tmp}/healthy.ndjson"
  {
    _ev $(( T +    0 )) "${H1}" 1
    _ev $(( T +  120 )) "${H1}" 2
    _ev $(( T +  238 )) "${H1}" 3   # gap 118
    _ev $(( T +  406 )) "${H1}" 4   # gap 168 - the cadence ceiling itself
    _ev $(( T +  480 )) "${H1}" 5   # gap  74
    _ev $(( T +  600 )) "${H1}" 6   # gap 120
    _ev $(( T +  761 )) "${H1}" 7   # gap 161 - the worst gap
    _ev $(( T +  850 )) "${H1}" 8   # gap  89
  } > "${healthy}"
  expect 0 "healthy capture passes and reports its worst gap" \
    --grep 'worst gap     : 168 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${healthy}"

  # (2) The bound is inclusive: exactly LOCATION_MESSAGE_RETENTION_SECS passes.
  local at228="${tmp}/at228.ndjson"
  { _ev $(( T + 0 )) "${H1}" 1; _ev $(( T + 228 )) "${H1}" 2; _ev $(( T + 300 )) "${H1}" 3; } > "${at228}"
  expect 0 "a gap of exactly 228 s is inside the promise" \
    -- --publishers 1 --from "${T}" --until $(( T + 300 )) "${at228}"

  # (3) The packet's named negative: 229 s > 228 s must FAIL.
  local at229="${tmp}/at229.ndjson"
  { _ev $(( T + 0 )) "${H1}" 1; _ev $(( T + 229 )) "${H1}" 2; _ev $(( T + 301 )) "${H1}" 3; } > "${at229}"
  expect 1 "a 229 s gap breaches the 228 s retention bound" \
    --grep 'FAIL - LIVENESS: worst gap 229 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 301 )) "${at229}"

  # (4) The ["EVENT",sub,{...}] wrapper must reach the same verdict.
  local wrapped="${tmp}/wrapped.ndjson"
  _wrap "${at229}" > "${wrapped}"
  expect 1 "an [\"EVENT\",sub,{...}] capture reaches the same verdict" \
    --grep 'worst gap     : 229 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 301 )) "${wrapped}"

  # (5) Mixed shapes in one file (a websocket dump concatenated with an export).
  local mixed="${tmp}/mixed.ndjson"
  { head -n 4 "${healthy}"; _wrap <(tail -n 4 "${healthy}"); } > "${mixed}"
  expect 0 "bare events and EVENT arrays mix in one file" \
    --grep 'worst gap     : 168 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${mixed}"

  # (6) Streaming capture + end-of-run export appended: dedupe by id, so the
  #     doubled file must NOT read as a run with zero-second gaps.
  local doubled="${tmp}/doubled.ndjson"
  cat "${healthy}" "${healthy}" > "${doubled}"
  expect 0 "duplicate event ids are merged, not counted as 0 s gaps" \
    --grep 'deduped       : 8 duplicate event id\(s\) merged' \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${doubled}"

  # (7) Relay exports commonly return newest-first.
  local reversed="${tmp}/reversed.ndjson"
  tail -r "${healthy}" > "${reversed}" 2>/dev/null || tac "${healthy}" > "${reversed}"
  expect 0 "a newest-first export is sorted before gapping" \
    --grep 'worst gap     : 168 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${reversed}"

  # (8)-(9) No evidence is not clean evidence.
  expect 3 "an absent capture file is UNUSABLE, never clean" \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${tmp}/never-written.ndjson"
  local emptyf="${tmp}/empty.ndjson"; : > "${emptyf}"
  expect 3 "a zero-byte capture is UNUSABLE, never clean" \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${emptyf}"

  # (10) A capture of the wrong kinds proves nothing about location liveness.
  local wrongkind="${tmp}/wrongkind.ndjson"
  { _ev $(( T + 0 )) "${H1}" 1 1059; _ev $(( T + 100 )) "${H1}" 2 1059; } > "${wrongkind}"
  expect 3 "a capture holding no kind-445 is UNUSABLE" \
    -- --publishers 1 --from "${T}" --until $(( T + 100 )) "${wrongkind}"

  # (11) kind 445 is not enough: commits carry no expiration tag.
  local commits="${tmp}/commits.ndjson"
  {
    _ev $(( T +   0 )) "${H1}" 1 445 -
    _ev $(( T +  90 )) "${H1}" 2 445 -
    _ev $(( T + 180 )) "${H1}" 3 445 -
  } > "${commits}"
  expect 3 "a capture of MLS commits only holds no location evidence" \
    -- --publishers 1 --from "${T}" --until $(( T + 180 )) "${commits}"

  # (12) ...and the same file read with --include-commits IS analysable.
  expect 0 "--include-commits admits commits/proposals" \
    -- --include-commits --publishers 1 --from "${T}" --until $(( T + 180 )) "${commits}"

  # (13) The discriminator earns its keep: a commit landing mid-gap must not
  #      shorten it and launder a breach into a pass.
  local laundered="${tmp}/laundered.ndjson"
  {
    _ev $(( T +   0 )) "${H1}" 1
    _ev $(( T + 115 )) "${H1}" 2 445 -   # commit, no expiration
    _ev $(( T + 229 )) "${H1}" 3
    _ev $(( T + 301 )) "${H1}" 4
  } > "${laundered}"
  expect 1 "an MLS commit inside a 229 s gap does not shorten it" \
    --grep 'worst gap     : 229 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 301 )) "${laundered}"

  # (14) A hole in the middle of a capture can hide a gap.
  local holed="${tmp}/holed.ndjson"
  { head -n 3 "${healthy}"; echo '{"id":"truncat'; tail -n 5 "${healthy}"; } > "${holed}"
  expect 3 "an unparseable line mid-file makes the capture UNUSABLE" \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${holed}"

  # (15) ...but a single unparseable LAST line is just a stopped stream.
  local tailcut="${tmp}/tailcut.ndjson"
  { cat "${healthy}"; printf '{"id":"0000","created_at":17565'; } > "${tailcut}"
  expect 0 "a single truncated last line is dropped with a note" \
    --grep 'truncated \(last line\)' \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${tailcut}"

  # (16) One observation bounds nothing, declared window or not.
  local single="${tmp}/single.ndjson"
  _ev "${T}" "${H1}" 1 > "${single}"
  expect 1 "a single-event series FAILS as insufficient" \
    --grep 'FAIL - INSUFFICIENT' \
    -- --publishers 1 --from "${T}" --until $(( T + 120 )) "${single}"

  # (17)-(18) Two circles in one capture; a breach in either fails, and
  #           --series narrows the report to the circle under test.
  local twoseries="${tmp}/twoseries.ndjson"
  cat "${healthy}" > "${twoseries}"
  {
    _ev $(( T +   0 )) "${H2}" 11
    _ev $(( T + 229 )) "${H2}" 12
    _ev $(( T + 301 )) "${H2}" 13
  } >> "${twoseries}"
  expect 1 "a breach in either circle fails the run" \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) "${twoseries}"
  expect 0 "--series narrows the report to the circle under test" \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) --series "${H1}" "${twoseries}"

  # (19)-(20) Multi-publisher attribution. Publisher A stops after 320 s while
  #           B keeps a 160 s cadence: every INTERLEAVED gap is <= 168 s and B
  #           keeps publishing to the end of the window, so neither the gap
  #           bound nor the tail gap can see A leave - only the event-count
  #           floor can, and only if the publisher count is declared honestly.
  local twopub="${tmp}/twopub.ndjson"
  {
    _ev $(( T +   0 )) "${H1}" 21
    _ev $(( T + 160 )) "${H1}" 22
    _ev $(( T + 320 )) "${H1}" 23
    for off in 80 240 400 560 720 880 1040 1200 1360 1520 1680; do
      _ev $(( T + off )) "${H1}" $(( 100 + off ))
    done
  } > "${twopub}"
  expect 1 "--publishers 2 catches a device that went quiet behind a healthy peer" \
    --grep 'FAIL - UNDERCOUNT' \
    -- --publishers 2 --from "${T}" --until $(( T + 1680 )) "${twopub}"
  expect 0 "declaring 1 publisher for a 2-publisher capture is the operator error --publishers exists to make impossible to reach by default" \
    -- --publishers 1 --from "${T}" --until $(( T + 1680 )) "${twopub}"

  # (21)-(22) The failure the whole-span floor is too coarse to see: publisher
  #           A keeps a 120 s cadence for the first half of a 3 h run and then
  #           dies while B publishes throughout. Every interleaved gap stays
  #           <= 168 s, there is no tail silence, and the whole-span floor
  #           (126) is still met by the 136 surviving events, so ONLY the
  #           sliding-window floor can catch it - which is exactly the
  #           "sharing stops after hours" field shape.
  local midstop="${tmp}/midstop.ndjson"
  : > "${midstop}"
  local off
  for (( off = 0; off <= 5400; off += 120 )); do
    _ev $(( T + off )) "${H1}" $(( 200 + off / 120 )) >> "${midstop}"
  done
  for (( off = 60; off <= 10740; off += 120 )); do
    _ev $(( T + off )) "${H1}" $(( 900 + off / 120 )) >> "${midstop}"
  done
  expect 1 "the sliding window catches a publisher that dies behind a live peer" \
    --grep 'FAIL - UNDERCOUNT: only [0-9]+ events in the 1800 s window' \
    -- --publishers 2 --from "${T}" --until $(( T + 10740 )) "${midstop}"
  expect 0 "--window 0 disables exactly that check and nothing else" \
    -- --publishers 2 --window 0 --from "${T}" --until $(( T + 10740 )) "${midstop}"

  # (23) The other half of the window rule: a long HEALTHY run must not be
  #      failed by its own tail. Windows that run past the last observation are
  #      partial by construction - grading them would redden every run that
  #      ever stops, which is every run. The DECLARED window is what grades the
  #      tail, and here it ends where the events do.
  local longhealthy="${tmp}/longhealthy.ndjson"
  : > "${longhealthy}"
  for (( off = 0; off <= 11880; off += 120 )); do
    _ev $(( T + off )) "${H1}" $(( 3000 + off / 120 )) >> "${longhealthy}"
  done
  expect 0 "a 3 h healthy run is not failed by its own truncated tail window" \
    --grep 'window floor  : 10 per 1800 s window' \
    -- --publishers 1 --from "${T}" --until $(( T + 11880 )) "${longhealthy}"

  # (24)-(25) A bound tighter than the promise is honoured, and the promise
  # itself is not silently tightened with it. 188 is the fixture's own value,
  # deliberately not a threshold this project uses any more (see the header: the
  # bound is per API level, on every Android row).
  local at200="${tmp}/at200.ndjson"
  { _ev $(( T + 0 )) "${H1}" 1; _ev $(( T + 200 )) "${H1}" 2; _ev $(( T + 320 )) "${H1}" 3; } > "${at200}"
  expect 1 "a --max-gap tighter than the 228 s promise rejects a 200 s gap" \
    -- --max-gap 188 --publishers 1 --from "${T}" --until $(( T + 320 )) "${at200}"
  expect 0 "the same 200 s gap is inside the 228 s baseline bound" \
    -- --publishers 1 --from "${T}" --until $(( T + 320 )) "${at200}"

  # (25a)-(25b) The API 23-30 residual, both ways. A 240 s gap is D3 (iii)'s
  # ACCEPTED cold residual there — on a BASELINE row as much as on an acceptance
  # one, because a baseline row taken now is a row of the shipped
  # delivery-driven build — so the default must red it (nothing here loosens the
  # retention) and the row's own 248 must pass it. Grading such a capture
  # against the default was the false red this header used to invite.
  local at240="${tmp}/at240.ndjson"
  { _ev $(( T + 0 )) "${H1}" 1; _ev $(( T + 240 )) "${H1}" 2; _ev $(( T + 360 )) "${H1}" 3; } > "${at240}"
  expect 1 "a 240 s gap breaches the 228 s default" \
    -- --publishers 1 --from "${T}" --until $(( T + 360 )) "${at240}"
  expect 0 "the same 240 s gap is inside an API 23-30 row's 248 s bound" \
    -- --max-gap 248 --publishers 1 --from "${T}" --until $(( T + 360 )) "${at240}"

  # (26) Two captures of two DIFFERENT circles must stay two series even when
  #      the operator gave both files the same name.
  local healthy2="${tmp}/healthy2.ndjson"
  {
    _ev $(( T +   0 )) "${H2}" 41
    _ev $(( T + 120 )) "${H2}" 42
    _ev $(( T + 288 )) "${H2}" 43
    _ev $(( T + 456 )) "${H2}" 44
    _ev $(( T + 600 )) "${H2}" 45
    _ev $(( T + 761 )) "${H2}" 46
    _ev $(( T + 850 )) "${H2}" 47
  } > "${healthy2}"
  mkdir -p "${tmp}/dutA" "${tmp}/dutB"
  cp "${healthy}"  "${tmp}/dutA/capture.ndjson"
  cp "${healthy2}" "${tmp}/dutB/capture.ndjson"
  expect 0 "same-named captures of two circles stay separate series" \
    --grep 'series capture#2' \
    -- --publishers 1 --from "${T}" --until $(( T + 850 )) \
       "${tmp}/dutA/capture.ndjson" "${tmp}/dutB/capture.ndjson"

  # (27) The ephemeral-key trap says so out loud instead of reporting nothing.
  expect 1 "--group-by pubkey degenerates and explains why" \
    --grep 'EPHEMERAL' \
    -- --group-by pubkey --publishers 1 --from "${T}" --until $(( T + 850 )) "${healthy}"

  # (28) A kind-445 with no `h` is not a Haven group message.
  local nohtag="${tmp}/nohtag.ndjson"
  { _ev_nohtag $(( T + 0 )) 1; _ev_nohtag $(( T + 120 )) 2; } > "${nohtag}"
  expect 3 "a kind-445 without an h tag makes the capture UNUSABLE" \
    -- --publishers 1 --from "${T}" --until $(( T + 120 )) "${nohtag}"

  # (29)-(30) Operator errors are usage errors, not silent passes.
  expect 2 "no capture file is a usage error" -- --publishers 1
  expect 2 "an unknown option is a usage error" \
    -- --max-gaps 228 --publishers 1 --from "${T}" --until $(( T + 850 )) "${healthy}"

  # (31)-(32) The head and tail of the DECLARED window. Both of these read as a
  #           clean 30 min against the observed span alone - 16 events, every
  #           gap 120 s - and both are the "stopped publishing" field failure
  #           this instrument exists to catch. Neither event-count floor can
  #           see them either: over the observed span the count is exactly
  #           right. Only the declared window can.
  local diesearly="${tmp}/dies-early.ndjson"
  : > "${diesearly}"
  for (( off = 0; off <= 1800; off += 120 )); do
    _ev $(( T + off )) "${H1}" $(( 5000 + off / 120 )) >> "${diesearly}"
  done
  expect 1 "a device that publishes for 30 min of a declared 3 h window and dies FAILS" \
    --grep 'FAIL - LIVENESS: worst gap 9000 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 10800 )) "${diesearly}"

  local latestart="${tmp}/late-start.ndjson"
  : > "${latestart}"
  for (( off = 9000; off <= 10800; off += 120 )); do
    _ev $(( T + off )) "${H1}" $(( 6000 + off / 120 )) >> "${latestart}"
  done
  expect 1 "a device silent for the first 2.5 h of a declared 3 h window FAILS" \
    --grep 'FAIL - LIVENESS: worst gap 9000 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 10800 )) "${latestart}"

  # (33) ...and the same dead capture without a declared window is UNGRADED,
  #      never OK. This is also the §3.2 discovery listing: the per-series
  #      report is still printed, so the operator can read the `h` off it.
  expect 5 "a capture graded without --from/--until is UNGRADED, never a pass" \
    --grep 'RESULT: UNGRADED' -- --publishers 1 "${diesearly}"

  # (34)(40) Half a window grades neither end of it, and a window that runs
  #          backwards is not a window.
  expect 2 "--from without --until is a usage error" \
    -- --publishers 1 --from "${T}" "${healthy}"
  expect 2 "--until at or before --from is a usage error" \
    -- --publishers 1 --from "${T}" --until "${T}" "${healthy}"

  # (35) The capture is normally started BEFORE the window and stopped after
  #      it, so head and tail gaps must clamp at zero rather than go negative.
  expect 0 "a capture wider than the declared window yields no negative gap" \
    --grep 'worst gap     : 168 s' \
    -- --publishers 1 --from $(( T + 120 )) --until $(( T + 700 )) "${healthy}"

  # (36) `--publishers` has no default, because the wrong one is a false green:
  #      fixture (20) above is that exact capture read as one publisher.
  expect 2 "omitting --publishers is a usage error, not a default of 1" \
    -- --from "${T}" --until $(( T + 850 )) "${healthy}"

  # (37)-(38) One circle split across two capture files - a stream restarted
  #           mid-run. Graded as two file-series the 600 s seam between them
  #           belongs to neither, so the split is REFUSED; concatenated, the
  #           seam is an ordinary gap and breaches the bound.
  local seamA="${tmp}/seam-a.ndjson" seamB="${tmp}/seam-b.ndjson"
  local seamed="${tmp}/seamed.ndjson"
  : > "${seamA}"; : > "${seamB}"
  for (( off = 0; off <= 1800; off += 120 )); do
    _ev $(( T + off )) "${H1}" $(( 7000 + off / 120 )) >> "${seamA}"
  done
  for (( off = 2400; off <= 4200; off += 120 )); do
    _ev $(( T + off )) "${H1}" $(( 8000 + off / 120 )) >> "${seamB}"
  done
  cat "${seamA}" "${seamB}" > "${seamed}"
  expect 3 "one circle split across two capture files is refused, not graded twice" \
    --grep 'the same circle is split across capture files' \
    -- --publishers 1 --from "${T}" --until $(( T + 4200 )) "${seamA}" "${seamB}"
  expect 1 "concatenated, the seam between the two captures is graded" \
    --grep 'worst gap     : 600 s' \
    -- --publishers 1 --from "${T}" --until $(( T + 4200 )) "${seamed}"

  # (39) --help is a request that was answered, not an error.
  expect 0 "--help exits 0" --grep 'Usage: summarize-created-at-gaps.sh' -- --help

  if (( checked != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${checked} fixture(s), expected ${SELF_TEST_FIXTURES}." >&2
    echo "  The count is pinned by EQUALITY so a deleted fixture cannot hide in" >&2
    echo "  a floor's slack. Update it in the same edit that adds or removes one." >&2
    fail=1
  fi
  if (( fail != 0 )); then
    echo "summarize-created-at-gaps.sh --self-test: FAILED" >&2
    return "${RC_SELFTEST}"
  fi
  echo "summarize-created-at-gaps.sh --self-test: ${checked} fixtures passed"
  return 0
}

if [[ "${RUN_SELF_TEST:-0}" -eq 1 ]]; then
  if [[ ${#INPUTS[@]} -ne 0 ]]; then
    die_usage "--self-test takes no capture files"
  fi
  self_test
  exit $?
fi

main
