#!/usr/bin/env bash
#
# Structural (closed-world) privacy oracle over the E2E wire journal.
#
# Backlog Workstream C, items C2/C3/C4. Consumes the NDJSON journal written by
# the recording WebSocket proxy (C1, `tooling/e2e/local-relay`) and asserts the
# STRUCTURAL layer of what Haven put on the wire:
#
#   C2  meta-floors      the journal is readable, non-empty, internally
#                        consistent, ANCHORED to a sentinel, and proves that
#                        every expected participant actually transmitted.
#   C3  closed kind set  the set of event kinds Haven SENT (over de-duplicated
#                        client->relay events) is a SUBSET of the day-one
#                        allow-list, and a SUPERSET of the kinds a healthy run
#                        must produce.
#   C4  per-kind tags    for each kind Haven sent, the tag-NAME set is a subset
#                        of that kind's allow-list and a superset of its
#                        required list.
#   C4-REQ filter keys  every filter key on a REQ frame is in the allow-list's
#                        `req_filters.allowed_keys`. A REQ is the other thing a
#                        client puts on a relay, and a filter field nobody has
#                        reasoned about cannot be shown not to carry identity
#                        or location material (NIP-50 `search` puts plaintext
#                        query terms on the wire; a `#g` geohash filter tells
#                        the relay which area the user is watching).
#
# The allow-list itself is DATA, not code: `tooling/e2e/wire_allowlist.json`.
# Anything absent from it is forbidden — that is what makes this closed-world,
# and it is the whole point of replacing the forbid-list this supersedes
# (`_assertWirePrivacyInvariants` in `haven/integration_test/e2e/
# e2e_combined.dart`), under which a new kind, a new tag or an MDK-introduced
# field passed silently.
#
# # Why a SET and never a multiset
#
# One event is legitimately published to N relays and returned to M
# subscribers, and a retry changes both numbers. Every count in this journal is
# therefore nondeterministic, and a count assertion would flake. A flaky
# privacy oracle is a bypassed privacy oracle, so events are de-duplicated
# before any assertion and the assertions are set operations. The de-dup key is
# the event BODY, not the id alone — see `evaluate`.
#
# # Why subset AND superset, never equality
#
# Exact set equality false-reds the moment an optional tag legitimately does
# not appear in a run (a kind-445 commit carries `h` only; an application
# message also carries `expiration`). So both directions are asserted
# separately: `observed ⊆ allowed` catches anything NEW reaching a relay, and
# `required ⊆ observed` catches a feature that silently STOPPED emitting.
# Only the second can see a publish path that quietly died.
#
# # Which assertions are SEND-SIDE, and what that costs
#
# The journal records `dir`, so this oracle has strictly more information than
# a relay does. Declining to use it does not make the guard more honest — it
# makes it attribute other parties' traffic to Haven. Every event-level
# assertion below is therefore restricted to `dir == "c2r"` (client->relay):
#
#   * C3 closed kind set, C3 required kind set
#   * C4 per-kind tag allow-list and required tags
#   * the C2 publisher / connection floors (always were)
#   * the REQUIRED half of the closed frame-verb set
#   * the "snapshot contains no events" meta-floor
#
# Without that restriction the two sharpest checks in the file are satisfiable
# by traffic Haven never sent. Both shapes were real:
#
#   * a run in which Haven publishes only 30443 while the 445 and the 1059
#     arrive `r2c` from a peer satisfies `required ⊆ observed` and reports
#     clean, so the direction the header claims "can see a publish path that
#     quietly died" saw nothing;
#   * a run in which EVERY 445 Haven sends has lost its NIP-40 `expiration`
#     reports clean as long as ONE inbound 445 still carries it — while
#     wire_allowlist.json calls that union-level `expiration` requirement the
#     sharpest check in the file.
#
# WHAT THIS GIVES UP, stated plainly. Restricting to `c2r` means the oracle no
# longer reds on:
#
#   * an INBOUND event of a kind outside the allow-list. That is a statement
#     about what a relay or a peer sent, not about what Haven sent, and this
#     file's scope note already disclaims relay behaviour. The part of it that
#     IS a Haven fact — "Haven asked for something it should not have" — is a
#     property of the REQ filter, which C4-REQ now examines directly.
#   * an INBOUND event carrying an unexpected tag name (say an `r2c` kind-445
#     with a `p` tag). Same argument; cross-event and value-layer facts about
#     inbound traffic are `check-wire-correlation.sh`'s half of the workstream.
#
# To keep that information visible rather than merely discarded, the summary
# PRINTS the inbound kind set as an advisory line. It is reported, never
# asserted, and never affects the exit code.
#
# Three classes are deliberately evaluated over BOTH directions, because they
# are statements about frames nobody can classify rather than about who sent
# them: an unrecognised (`frame: null`) frame, a MALFORMED record, and the
# SUBSET half of the closed frame-verb set. A verb this file cannot name is
# worth a human look wherever it came from, and neither hermetic relay emits
# one today.
#
# # A record the oracle cannot decode is a FINDING
#
# A line the oracle cannot parse is exactly as unsafe as one it can parse and
# dislikes: in both cases the file cannot say the traffic was safe. The decoder
# is therefore TOTAL — it type-checks `id`, `pubkey`, `kind` and `tags` and
# emits a `malformed record` finding rather than letting jq abort, it classifies
# EVERY event object in an EVENT frame rather than the first, and the whole
# per-line body is wrapped in a `try`/`catch` so an unforeseen type error
# becomes a finding too. The caught message is never echoed: an undecodable
# payload is precisely where unexpected plaintext would be, and these messages
# land in a world-readable job log.
#
# This is the shape of the A4 false-green this file's own header claims to have
# designed out. Before the fix, one event whose `id` was a number aborted jq's
# processing of that record; jq dropped it and carried on, jq's exit status was
# not latched across inputs, and the sentinel line — by construction the last
# input at or below the boundary, and always parseable — guaranteed a success
# after the error. A kind-3 contact list on the wire reported CLEAN.
#
# # Why a sentinel
#
# Background wakes (WorkManager / BGTask) write to the journal while this
# oracle reads it, so the file is a moving target. The drive target emits
# `["HAVEN_WIRE_SENTINEL","<token>"]`; the proxy INTERCEPTS it — recording it
# as an ordinary `dir:"c2r"` frame and never forwarding it upstream, so no
# relay ever sees the marker and nothing about the scenario is perturbed. This
# oracle asserts ONLY over lines at or below that `wire_seq`. A wake that
# happens mid-read appends above the boundary and is invisible here — which is
# the point: it cannot race the read, and it also cannot be used to smuggle a
# violation past the oracle, because a later run's sentinel moves the boundary
# up over it.
#
# The sentinel is a REQUIREMENT, not an option. An unanchored read is a read
# whose sample nobody can reproduce.
#
# # "Nothing to check" is not "nothing leaked"
#
# Every assertion here passes trivially over an empty input, so an absent,
# empty, truncated or unparseable journal is its OWN failure class with its own
# exit code — never a pass. This is the A4 lesson, already learned once in this
# repo by `scan-logs-for-secrets.sh`: "nothing to scan" was reported as
# "nothing leaked". The same posture is reproduced here deliberately, including
# the separate exit code, so triage can tell "we found a leak" from "we found
# no evidence" without parsing prose.
#
# For the same reason at least ONE participant floor (--participant,
# --min-distinct-publishers or --min-distinct-conns) is MANDATORY. Without one,
# a scenario in which a client silently never armed would satisfy every other
# assertion in this file.
#
# # What each participant floor actually proves
#
# A mandatory floor that can be satisfied by anything is not a floor, so each
# is stated in terms of what it proves and each is guarded against being
# passed a value that disables it:
#
#   --participant <64-hex>
#       That NAMED pubkey authored a client->relay event below the sentinel.
#       The strongest of the three, and the only one that names an identity.
#       The value must be 64 lowercase hex; a typo'd or truncated pubkey used
#       to sail through and then simply never match, turning an operator error
#       into a META-FLOOR blamed on the scenario.
#
#   --min-distinct-publishers <n>, n >= 2
#       At least n distinct IDENTITY-KEY pubkeys authored a client->relay
#       event. "Identity-key" is load-bearing: Security Rule 2 mints a FRESH
#       ephemeral keypair for every kind-445 and every kind-1059, so counting
#       raw author pubkeys made one device sending four location events look
#       like six publishers. The kinds whose author is ephemeral are declared
#       in the allow-list (`"ephemeral_pubkey": true`) and excluded from this
#       count, which is what makes it a count of PARTICIPANTS.
#
#   --min-distinct-conns <n>, n >= 2
#       At least n distinct WebSocket connections carried a client->relay
#       event. The weakest of the three and deliberately not described as a
#       participant count: one device talking to two relays satisfies it, and
#       so does one app connection beside the harness's own TestRelay socket
#       (the harness publishes real 445/1059/30443 through the same proxy).
#       It is still the lever a lane reaches for when every identity on the
#       wire is ephemeral. Narrow it with --exclude-conn.
#
# `n` must be an integer >= 2 for both counts. `0` and every negative value
# used to pass the mandatory-floor gate AND disable the check — `-1` reported
# CLEAN on the exact one-participant journal the self-test asserts must be a
# META-FLOOR. `1` is legal arithmetic but zero information: it is already
# implied by the "the snapshot contains at least one client->relay event"
# meta-floor, and it had been used as filler in five self-test cases.
#
# # --exclude-conn, and why it prints what it dropped
#
# The harness's own TestRelay socket reaches the proxy exactly as the app does.
# Two things separate them, and both are needed. A socket DECLARES itself by
# emitting the intercepted `["HAVEN_WIRE_SENTINEL",<token>]` marker
# (`TestRelay._declareHarnessSocket`), which is journalled as an ordinary c2r
# frame and which no production path can produce — that covers every socket the
# harness opens, including the ones a mid-run reconnect mints. `--exclude-conn`
# covers the rest: a lane naming a `conn_id` it learned from the sentinel ack.
# Either way the connection is dropped from the EVENT-level attribution — the
# kind set, the tag sets and both floors — so those become statements about the
# app rather than about the scenario.
#
# Partial exclusion can hide a real finding, so two things bound it. First, the
# exclusion applies to EVENT records ONLY: unrecognised frames, malformed
# records, the frame-verb closed set and the REQ filter-key check are still
# evaluated over every connection, so those classes cannot be excluded away at
# all. Second, every run PRINTS what each exclusion dropped — the connection,
# how many client->relay event frames it accounted for, and which kinds they
# carried — so an exclusion that swallowed something interesting is visible in
# the same job log as the verdict.
#
# # Scope, stated honestly
#
# This is a SEND-SIDE instrument. It says nothing about a hostile relay
# withholding, reordering or forging inbound events (eclipse, welcome
# suppression, stale-KeyPackage serving). It is also the STRUCTURAL layer only:
# the value of a particular tag, cross-event correlation and canary strings are
# backlog items C5.x/C6 and deliberately not asserted here.
#
# Usage:
#   bash tooling/e2e/ci/check-wire-journal.sh \
#        --journal <path> [--journal <path>...] \
#        --sentinel <token> \
#        [--allowlist <path>] \
#        [--participant <hex>]... \
#        [--min-distinct-publishers <n>] \
#        [--min-distinct-conns <n>] \
#        [--exclude-conn <conn_id>]...
#   bash tooling/e2e/ci/check-wire-journal.sh --self-test
#   bash tooling/e2e/ci/check-wire-journal.sh --lint-allowlist [<path>]
#
# # How a lane wires this in
#
# Post-drive, on the HOST — the journal is written by the proxy on the runner,
# not on the device, so this cannot live inside the drive target. The lane
# mints the sentinel token, hands the SAME string to the drive and to this
# script, and runs the check after the drive exits (same slot as the mandatory
# `scan-logs-for-secrets.sh` call in `run-single-avd-scenario.sh`):
#
#   TOKEN="HAVEN_WIRE_SENTINEL:$(openssl rand -hex 16)"
#   flutter drive … --dart-define=HAVEN_WIRE_SENTINEL="${TOKEN}"
#   bash tooling/e2e/ci/check-wire-journal.sh \
#        --journal /tmp/haven-wire-journal.ndjson \
#        --sentinel "${TOKEN}" \
#        --min-distinct-publishers 2 \
#        --min-distinct-conns 2
#
# `--min-distinct-publishers 2` is the floor that means "two identities
# transmitted"; `--min-distinct-conns 2` is a weaker companion, kept because it
# still catches a client that never opened a socket. A two-device lane that
# knows both npubs should pass `--participant` twice instead — it is the only
# floor that names who.
#
# The drive target emits the marker with
# `TestRelay.emitWireJournalSentinel()` (haven/integration_test/e2e/_lib/
# test_relay.dart), which defaults to that same define. Passing the token in
# rather than scraping it back out of a log is what keeps the two halves from
# drifting: there is one string, and both sides read it from the same place.
#
# Exit codes. The set is CLOSED — {0,1,2,3,4} and nothing else — because
# triage reads the number, not the prose. Anything that could escape it is
# mapped back in: a jq abort inside the decoder, and an allow-list whose shape
# makes a jq expression fail, both used to surface as an undocumented rc 5.
#
#   0 = every named journal was usable, anchored, and structurally clean
#   1 = VIOLATION — a closed-world finding (unexpected kind, unexpected tag,
#       missing required kind/tag, unrecognised frame, unknown frame verb,
#       an unknown REQ filter key, or a MALFORMED record the decoder could not
#       classify)
#   2 = usage error, INCLUDING a malformed argument value: a non-integer or
#       out-of-range participant floor, or a --participant that is not 64 hex.
#       These used to collapse into other codes — `--min-distinct-publishers
#       abc` tripped `set -u` inside an arithmetic test and exited 1, so an
#       operator typo read as a wire-privacy VIOLATION.
#   3 = UNUSABLE — the check could not be performed, so this run proves nothing
#       either way. Two sources, deliberately sharing one code because the
#       operator response is the same (fix the instrument, re-run, believe
#       nothing until then):
#         * the JOURNAL — absent, unreadable, empty, containing a line that is
#           not a JSON object (a truncated write), missing a contract field,
#           mixing a lifecycle record with traffic fields, or with a duplicated
#           / gapped / non-zero-based `wire_seq`; also a journal the decoder
#           itself could not run over;
#         * the ORACLE'S OWN INPUTS — jq not installed, or an allow-list that
#           is absent, unreadable, or does not lint (see --lint-allowlist).
#   4 = META-FLOOR — the journal parsed, but proves too little: no sentinel to
#       anchor the read, no client->relay events at all below the sentinel, or
#       a participant that transmitted nothing. Distinct from 3 because the
#       operator response differs: 3 means the recorder or the allow-list
#       broke, 4 means the SCENARIO did.

set -euo pipefail

# Named exit codes, so the "missing != clean" and "broken != proved nothing"
# distinctions cannot be collapsed by an accidental `return 0` in a later edit.
readonly RC_CLEAN=0
readonly RC_VIOLATION=1
readonly RC_USAGE=2
readonly RC_UNUSABLE=3
readonly RC_METAFLOOR=4

SELF_PATH="${BASH_SOURCE[0]}"
readonly SELF_PATH
SELF_DIR="$(cd -- "$(dirname -- "${SELF_PATH}")" && pwd)"
readonly SELF_DIR
# tooling/e2e/ci -> tooling/e2e
readonly DEFAULT_ALLOWLIST="${SELF_DIR}/../wire_allowlist.json"

usage() {
  cat >&2 <<'EOF'
Usage:
  check-wire-journal.sh --journal <path> [--journal <path>...] \
                        --sentinel <token> \
                        [--allowlist <path>] \
                        [--participant <64-hex>]... \
                        [--min-distinct-publishers <n>] \
                        [--min-distinct-conns <n>] \
                        [--exclude-conn <conn_id>]...
  check-wire-journal.sh --self-test
  check-wire-journal.sh --lint-allowlist [<path>]

At least one participant floor (--participant / --min-distinct-publishers /
--min-distinct-conns) is REQUIRED: without one the meta-floor is vacuous.

  --participant                 64 lowercase hex. Asserts THAT pubkey sent a
                                client->relay event below the sentinel.
  --min-distinct-publishers <n> n >= 2. Distinct IDENTITY-key authors of a
                                client->relay event. Kinds whose author is a
                                fresh ephemeral key per message (445, 1059)
                                are excluded, so this counts participants.
  --min-distinct-conns <n>      n >= 2. Distinct connections that sent an
                                event. NOT a participant count: one device
                                over two relays satisfies it.
  --exclude-conn <conn_id>      Drop a connection from the EVENT-level
                                attribution (kinds, tags, both floors). The
                                run prints what each exclusion dropped.

A floor of 0, 1 or a negative number is refused: 0 and negatives disable the
check they were passed to enable, and 1 is already implied by the meta-floor.
EOF
}

# ---------------------------------------------------------------------------
# Usability gate (C2, first half). Mirrors scan-logs-for-secrets.sh: each
# branch is a DIFFERENT operator failure and each says so, because "the journal
# is missing" and "the journal is clean" demand opposite responses.
# ---------------------------------------------------------------------------

# journal_usable <path> — RC_CLEAN if the file can be read at all.
journal_usable() {
  local f="$1"
  if [[ ! -e "${f}" ]]; then
    echo "UNUSABLE: ${f} [absent] — the wire journal was never written; nothing was checked." >&2
    return "${RC_UNUSABLE}"
  fi
  if [[ ! -f "${f}" ]]; then
    echo "UNUSABLE: ${f} [not a regular file] — refusing to treat as a journal." >&2
    return "${RC_UNUSABLE}"
  fi
  if [[ ! -r "${f}" ]]; then
    # jq on an unreadable file exits non-zero with no output, and a `|| true`
    # anywhere downstream would launder that into "no violations found".
    echo "UNUSABLE: ${f} [unreadable] — exists but permission denied; nothing was checked." >&2
    return "${RC_UNUSABLE}"
  fi
  # EMPTY is deliberately fatal, exactly like ABSENT. `cmd > file &` creates the
  # file at redirection time, so a proxy that died before its first frame leaves
  # zero bytes while one that died a moment earlier leaves no file at all: the
  # same failure, in two states, decided by scheduling. Passing one and failing
  # the other would make the verdict on an identical failure a coin flip.
  if [[ ! -s "${f}" ]]; then
    echo "UNUSABLE: ${f} [empty] — 0 bytes; the recorder never wrote a frame." >&2
    return "${RC_UNUSABLE}"
  fi
  return "${RC_CLEAN}"
}

# journal_wellformed <path> — every line is a JSON object carrying the contract
# fields for its record type, and `wire_seq` is a gapless 0-based sequence with
# no duplicates.
#
# A truncated final line is caught here (it is not valid JSON), and it is fatal
# rather than skipped: the contract says the recorder NEVER drops a line, so a
# line it could not finish writing means the sample is incomplete and this run
# cannot bound what went out. Same for a gap in `wire_seq`.
#
# Three record types exist. Only `frame` lines carry `dir` and `frame`;
# `conn_open` / `conn_error` are connection-lifecycle records and carry
# neither. Requiring the traffic fields on every line would make every real
# journal UNUSABLE — a failure mode worth naming, because "the guard rejects
# all valid input" and "the guard accepts all input" look equally like a guard
# that is not working.
#
# The producer contract (docs/WIRE_JOURNAL.md, "Record types") promises that
# equivalence in BOTH directions: `"frame" in line` and `type == "frame"` are
# interchangeable discriminators, and lifecycle records carry no `dir` and no
# `frame`. This function now ASSERTS it, because the two oracles over this
# journal picked different sides of it — this file switches on `type`, its
# sibling `check-wire-correlation.sh` switches on `has("frame")` — and an
# unasserted equivalence between two consumers is a gap shaped exactly like a
# smuggling channel. A kind-3 EVENT on a line labelled `type:"conn_open"` was
# invisible here (this file filtered it out as lifecycle) while the sibling
# decoded it as traffic; the two oracles disagreed about what the same line
# was, and neither said so. Now the line is UNUSABLE and the journal is fixed
# at the producer, which is the only place the disagreement can be resolved.
journal_wellformed() {
  local f="$1" bad gaps

  # -R reads each line as a string, so an unparseable line cannot abort the
  # pass and lose its position; `input_line_number` reports 1-based lines.
  bad="$(
    jq -R '
      (try (fromjson) catch null) as $o
      | if ($o | type) != "object" then "not a JSON object"
        elif ($o.wire_seq | type) != "number" then "missing/invalid wire_seq"
        elif ($o.wire_seq != ($o.wire_seq | floor)) or ($o.wire_seq < 0) then "wire_seq not a non-negative integer"
        elif ($o.conn_id | type) != "string" then "missing/invalid conn_id"
        elif (["frame","conn_open","conn_error"] | index($o.type)) == null then
          "unknown record type \($o.type | tojson)"
        elif ($o.type == "frame") and ($o.dir != "c2r" and $o.dir != "r2c") then "frame line with missing/invalid dir"
        elif ($o.type == "frame") and ($o | has("frame") | not) then "frame line with no frame key"
        # The two halves of the documented `type == "frame"` <=> `"frame" in
        # line` equivalence. Without these a lifecycle label is a way to put an
        # event on the wire that this oracle skips as self-description.
        elif ($o.type != "frame") and ($o | has("frame")) then
          "\($o.type) lifecycle record carries a `frame` key — the contract says lifecycle records carry none, and this oracle skips them as self-description"
        elif ($o.type != "frame") and ($o | has("dir")) then
          "\($o.type) lifecycle record carries a `dir` key — the contract says lifecycle records carry none"
        elif ($o.type == "conn_error") and (($o.reason | type) != "string") then
          "conn_error record with missing/invalid reason"
        else empty end
      | "line \(input_line_number): \(.)"
    ' -- "${f}" 2>&1 || echo "line ?: journal could not be read by jq"
  )"
  if [[ -n "${bad}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "UNUSABLE: ${f} [malformed] ${line}" >&2
    done <<< "${bad}"
    return "${RC_UNUSABLE}"
  fi

  # Sequence integrity. The contract promises a monotonic sequence from 0 with
  # no dropped lines, so all three of these are recorder failures, and each
  # means the checked sample is not the transmitted sample.
  gaps="$(
    jq -s '
      [ .[].wire_seq ] as $s
      | ($s | length) as $n
      | ($s | unique) as $u
      | [
          (if ($u | length) != $n then "duplicate wire_seq values (\($n - ($u|length)) duplicate line(s))" else empty end),
          (if ($u | length) > 0 and ($u[0] != 0) then "wire_seq does not start at 0 (starts at \($u[0])) — the journal head is truncated" else empty end),
          (if ($u | length) > 0 and ($u[-1] - $u[0] + 1) != ($u | length) then "wire_seq has \(($u[-1] - $u[0] + 1) - ($u|length)) gap(s) — the recorder dropped line(s)" else empty end)
        ][]
    ' -- "${f}"
  )"
  if [[ -n "${gaps}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "UNUSABLE: ${f} [sequence] ${line//\"/}" >&2
    done <<< "${gaps}"
    return "${RC_UNUSABLE}"
  fi
  return "${RC_CLEAN}"
}

# sentinel_seq <path> <token> — prints the HIGHEST wire_seq of a line that IS
# the sentinel marker, or nothing if no such line exists.
#
# Highest rather than first: the drive may emit the marker once per relay
# connection, and the snapshot should extend to the last one it managed.
#
# "IS the marker" is a structural test — `type == "frame"`, `dir == "c2r"`,
# `frame[0] == "HAVEN_WIRE_SENTINEL"`, `frame[1] == <token>` — not a substring
# match on the raw line. The substring form is what docs/WIRE_JOURNAL.md
# described, and it is wrong in the direction that MOVES THE BOUNDARY UP: any
# line merely CONTAINING the token extended the snapshot, and event content, a
# NOTICE echoing an unknown frame, and a truncated `raw_preview` of an
# unparseable frame are all lines that can contain it. A boundary that other
# parties' traffic can push around is not a boundary — the snapshot stops being
# the reproducible sample the sentinel exists to define, and it reopens the
# background-wake race the whole mechanism was built to close.
#
# `grep` stays as a cheap prefilter (these journals are large and the token is
# rare); the verdict is jq's. `dir == "c2r"` is required because the proxy
# synthesizes the ack and deliberately does NOT journal it: a marker recorded
# as `r2c` would be the recorder claiming a relay sent it, and a relay cannot
# have sent one — the proxy intercepts the marker and never forwards it, so no
# relay ever learns the token.
sentinel_seq() {
  local f="$1" token="$2" hits
  hits="$(grep -aF -- "${token}" "${f}" || true)"
  [[ -z "${hits}" ]] && return 0
  printf '%s\n' "${hits}" | jq -s --arg tok "${token}" '
    [ .[]
      | select(type == "object")
      | select(.type == "frame")
      | select(.dir == "c2r")
      | select((.frame | type) == "array")
      | select((.frame[0] // null) == "HAVEN_WIRE_SENTINEL")
      | select((.frame[1] // null) == $tok)
      | .wire_seq ]
    | if length == 0 then empty else max end'
}

# sentinel_token_present <path> <token> — true when the token appears anywhere
# in the raw file. Used ONLY to tell "the drive never emitted a marker" from
# "the token is in this journal but never as a marker frame", which are the
# same META-FLOOR with very different causes.
sentinel_token_present() {
  grep -aqF -- "$2" "$1"
}

# normalize <path> <boundary> — emits one compact JSON object per EVENT frame
# at or below <boundary>, plus a marker object per REQ frame, per unparseable
# frame, per malformed record and per frame verb seen. Everything downstream
# reads only this stream, so the journal's shape is decoded in exactly one
# place.
#
# Both EVENT frame shapes are handled: client->relay is `["EVENT", <event>]`
# while relay->client is `["EVENT", <subid>, <event>]` (NIP-01). Selecting the
# array members that are objects with a `kind` covers both without branching on
# direction — and getting this wrong would silently drop every relay->client
# event, i.e. halve the sample.
#
# # This function is TOTAL, and that is the whole point
#
# jq aborts the record it is working on when a filter meets the wrong type, and
# in a streaming pass that means the record is DROPPED and the pass carries on.
# Three fields reached type-sensitive filters unguarded — `ascii_downcase` on
# `id` and `pubkey`, and `[]` iteration over `tags` — so an event whose `id`
# was a number, whose `pubkey` was a number, or whose `tags` was a string
# vanished from the sample. A kind-3 contact list in that shape reported CLEAN;
# byte-identical and well-formed it reports a VIOLATION. Two independent
# launderings kept it quiet: jq's exit status reflects only the LAST input, and
# the sentinel line is by construction the last input at or below the boundary
# and always parses, so a success always followed the error.
#
# So: every field is type-checked BEFORE it is used, a wrong type becomes a
# `malformed record` finding rather than a drop, and the whole per-line body
# sits inside a `try`/`catch` so an unforeseen type error becomes the same
# finding instead of an abort. The caught error text is NEVER echoed — jq's
# messages quote the offending value, and an undecodable payload is precisely
# where unexpected plaintext would be. Field NAMES and jq TYPE names are safe
# and are all that is reported.
#
# EVERY event object in an EVENT frame is classified, not just the first: the
# frame `["EVENT", <445>, <3>]` used to reduce to its 445. A frame carrying
# more than one is itself reported, because NIP-01 carries exactly one.
#
# REQ frames used to reduce to their verb, so a filter carrying `authors`,
# `#p`, `#h`, `search` or `#g` was clean here while the summary printed
# `verbs [… REQ …]` as if the frame had been examined. The filter KEY names are
# now extracted and closed over in `evaluate`.
normalize() {
  local f="$1" boundary="$2"
  jq -c --argjson b "${boundary}" '
    # defects($ev) — the list of reasons this object cannot be trusted to be a
    # Nostr event. Empty list == safe to decode. Every subsequent filter in the
    # `else` branch depends on this having returned empty.
    def defects($ev):
      [ (if ($ev.id | type) != "string"
           then "id is \($ev.id | type), not a string" else empty end),
        (if ($ev.pubkey | type) != "string"
           then "pubkey is \($ev.pubkey | type), not a string" else empty end),
        (if ($ev.kind | type) != "number"
           then "kind is \($ev.kind | type), not a number" else empty end),
        (if ($ev | has("tags")) and (($ev.tags | type) != "array")
           then "tags is \($ev.tags | type), not an array" else empty end),
        (if (($ev.tags | type) == "array")
           then ( ($ev.tags
                   | map(select((type != "array") or (length == 0)
                                or ((.[0] | type) != "string")))
                   | length) as $n
                  | if $n > 0 then
                      "\($n) of \($ev.tags | length) tag element(s) are not a non-empty array with a string name"
                    else empty end )
           else empty end) ];

    select(.wire_seq <= $b)
    # Traffic only. `conn_open` / `conn_error` are lifecycle records with no
    # `dir` and no `frame`; they are the recorder describing itself, not
    # something Haven put on the wire. `journal_wellformed` has already
    # asserted that a lifecycle record carries neither field, so this filter
    # cannot be used to hide traffic behind a lifecycle label.
    | select(.type == "frame")
    | . as $line
    | try (
        if (.frame == null) then
          {t:"nullframe", seq:.wire_seq, conn:.conn_id, dir:.dir,
           preview:(.raw_preview // "")}
        elif ((.frame | type) == "array") then
          ( .frame[0] ) as $verb
          | if (($verb|type) != "string") then
              {t:"badverb", seq:.wire_seq, dir:.dir, verb:"<\($verb|type)>"}
            else
              # The verb marker is emitted for EVERY frame, including EVENT and
              # REQ. It used to be emitted only for the frames nothing else
              # handled, and `evaluate` then appended a synthetic "EVENT" —
              # which made `frame_verbs.required` containing "EVENT" vacuously
              # true over a snapshot with no EVENT frame in it.
              {t:"verb", seq:.wire_seq, dir:.dir, conn:.conn_id, verb:$verb},
              ( if $verb == "EVENT" then
                  ( [ .frame[1:][] | select(type == "object") | select(has("kind")) ] ) as $evs
                  | if ($evs | length) == 0 then
                      {t:"badevent", seq:$line.wire_seq, dir:$line.dir, conn:$line.conn_id,
                       why:"the frame carries no event object"}
                    else
                      ( if ($evs | length) > 1 then
                          {t:"badevent", seq:$line.wire_seq, dir:$line.dir, conn:$line.conn_id,
                           why:"the frame carries \($evs | length) event objects; a NIP-01 EVENT frame carries exactly one"}
                        else empty end ),
                      ( $evs[]
                        | . as $ev
                        | (defects($ev)) as $d
                        | if ($d | length) > 0 then
                            {t:"badevent", seq:$line.wire_seq, dir:$line.dir, conn:$line.conn_id,
                             why:($d | join("; "))}
                          else
                            {t:"event", seq:$line.wire_seq, dir:$line.dir, conn:$line.conn_id,
                             id:($ev.id | ascii_downcase),
                             kind:$ev.kind,
                             pubkey:($ev.pubkey | ascii_downcase),
                             tags:[ (($ev.tags // [])[] | .[0]) ]}
                          end )
                    end
                elif $verb == "REQ" then
                  # `["REQ", <subid>, <filter>, ...]` — filters start at index
                  # 2 and a REQ may legitimately carry several.
                  ( [ .frame[2:][] ] ) as $rest
                  | {t:"req", seq:$line.wire_seq, dir:$line.dir, conn:$line.conn_id,
                     keys:( [ $rest[] | select(type == "object") | keys[] ] | unique ),
                     nfilters:( [ $rest[] | select(type == "object") ] | length ),
                     nonobj:( [ $rest[] | select(type != "object") ] | length )}
                else empty end )
            end
        else
          {t:"badverb", seq:.wire_seq, dir:.dir, verb:"<\(.frame|type)>"}
        end
      # NOT REACHABLE BY ANY FIXTURE, AND THAT IS THE POINT. `defects` above
      # covers every type error the current shapes can produce, so a mutation
      # that turns this catch back into a silent drop leaves the self-test
      # green. It is the backstop for a shape nobody has thought of yet — the
      # class the pre-fix decoder handled by dropping the record and reporting
      # CLEAN. Do not delete it as dead code: its being unreachable is a
      # statement about `defects` being complete TODAY, not about this arm
      # being unnecessary tomorrow.
      ) catch (
        {t:"badevent", seq:($line.wire_seq), dir:($line.dir), conn:($line.conn_id),
         why:"the decoder could not classify this line (the payload is deliberately NOT echoed — read it from the on-runner journal at this wire_seq)"}
      )
  ' -- "${f}"
}

# ---------------------------------------------------------------------------
# The assertions (C2 second half, C3, C4). Written in jq rather than bash so
# the whole comparison runs on bash 3.2 (the macOS runners hosting the iOS
# lanes have no associative arrays).
# ---------------------------------------------------------------------------

# evaluate <normalized-stream-file> <allowlist> <participants-json> <min-pub>
#          <min-conn> <exclude-conns-json>
# Prints a JSON verdict: {"meta":[...],"violations":[...],"summary":{...}}
#
# DIRECTION. Every event-level assertion is restricted to `dir == "c2r"` —
# see "Which assertions are SEND-SIDE, and what that costs" in the header for
# the two repro shapes that forced it and for the list of what that gives up.
# The inbound half is summarised (`inbound_kinds`) and never asserted.
#
# EXCLUSION. `--exclude-conn` narrows the EVENT-level attribution only. Null
# frames, malformed records, the frame-verb closed set and the REQ filter-key
# check are evaluated over EVERY connection, so no exclusion can hide them, and
# the summary reports exactly what each exclusion dropped.
evaluate() {
  local stream="$1" allow="$2" participants="$3" min_pub="$4" min_conn="$5" exclude="$6"
  jq -s \
    --slurpfile allow "${allow}" \
    --argjson participants "${participants}" \
    --argjson minPub "${min_pub}" \
    --argjson minConn "${min_conn}" \
    --argjson exclude "${exclude}" '
    ($allow[0]) as $A
    | [ .[] | select(.t == "event") ]     as $allEvents
    | [ .[] | select(.t == "nullframe") ] as $nulls
    | [ .[] | select(.t == "badverb") ]   as $badverbs
    | [ .[] | select(.t == "badevent") ]  as $badevents
    | [ .[] | select(.t == "req") ]       as $reqs

    # ---- direction + connection scoping -------------------------------------
    # `$sent` is the send-side sample: client->relay, minus any connection the
    # lane excluded. It is the ONLY input to the kind set, the tag sets and the
    # floors. `$inbound` exists to be REPORTED, never asserted.
    # `. as $c` before the lookup is load-bearing: in `$exclude | index(.)`
    # the argument is evaluated against the INPUT of index, so a bare `.conn`
    # there means "index $exclude by the key .conn OF $exclude" — which is a
    # type error on an array, and was one.
    #
    # SELF-DECLARED HARNESS SOCKETS are unioned into the list the lane gave. A
    # connection that EMITTED the intercepted `HAVEN_WIRE_SENTINEL` verb is the
    # drive-s own `TestRelay` (`TestRelay._declareHarnessSocket`); no
    # production path can emit it. The lane can only name the ONE socket whose
    # ack it greps out of the drive log, and a scenario opens several (plus a
    # fresh one per reconnect) — so without this the participant floors below
    # are discharged by the harness-s own traffic and "the app transmitted"
    # is not what a green run means.
    | ( [ .[] | select(.t == "verb" and .dir == "c2r"
                       and .verb == "HAVEN_WIRE_SENTINEL") | .conn ]
        | unique ) as $harness
    | (( $exclude + $harness ) | unique) as $EXCL
    | ( [ $allEvents[] | . as $e | select(($EXCL | index($e.conn)) == null) ] ) as $inScope
    | ( [ $inScope[]   | select(.dir == "c2r") ] ) as $sent
    | ( [ $inScope[]   | select(.dir == "r2c") ] ) as $inbound
    | ( [ $allEvents[] | . as $e | select(($EXCL | index($e.conn)) != null)
                       | select(.dir == "c2r") ] ) as $dropped

    # ---- de-duplication: SET, never multiset (see header) -------------------
    # Keyed on the event BODY (id + kind + pubkey + tag names), not on the id
    # alone. Keying on the id would let two frames sharing an id but differing
    # in kind or tags collapse to whichever arrived first, and the survivor
    # would answer for both — the one shape in which de-duplication could HIDE
    # a finding rather than merely make the sample deterministic. Direction,
    # connection and sequence are excluded, because those are exactly the axes
    # along which a legitimate event repeats (published to N relays, returned
    # to M subscribers).
    | ( $sent
        | group_by([.id, .kind, .pubkey, (.tags | sort)])
        | map(.[0]) ) as $uniq

    | ( $uniq | map(.kind) | unique ) as $observedKinds
    # Non-numeric keys are ignored so the allow-list can carry `_`-prefixed
    # documentation entries without `tonumber` aborting the whole comparison.
    | ( $A.kinds | keys | map(select(test("^[0-9]+$"))) | map(tonumber) | sort ) as $allowedKinds
    | ( $A.kinds | to_entries
        | map(select(.key | test("^[0-9]+$")))
        | map(select(.value.required)) | map(.key | tonumber) | sort ) as $requiredKinds
    # Kinds whose author is a fresh ephemeral key per message (Security Rule 2).
    # Declared as DATA so the floor cannot drift from the protocol silently.
    | ( $A.kinds | to_entries
        | map(select(.key | test("^[0-9]+$")))
        | map(select(.value.ephemeral_pubkey == true))
        | map(.key | tonumber) | sort ) as $ephemeralKinds

    # Verbs: the SUBSET direction over both directions (a verb this file cannot
    # name is worth a look wherever it came from), the REQUIRED direction over
    # c2r alone (it is an assertion that HAVEN sent one).
    | ( [ .[] | select(.t == "verb") | .verb ] | unique ) as $observedVerbs
    | ( [ .[] | select(.t == "verb") | select(.dir == "c2r") | .verb ] | unique ) as $sentVerbs

    # ---- C2 meta-floors -----------------------------------------------------
    # `$publishers` counts IDENTITY-key authors only. Counting raw author
    # pubkeys made one device sending four location events look like six
    # publishers, because every 445 and every 1059 carries a fresh ephemeral
    # key. `$sentPubkeys` (all authors) backs --participant, which names a
    # pubkey and therefore cannot be inflated by an ephemeral one.
    | ( [ $sent[] | . as $e | select(($ephemeralKinds | index($e.kind)) == null) ] ) as $identitySent
    | ( $identitySent | map(.pubkey) | unique ) as $publishers
    | ( $sent | map(.pubkey) | unique ) as $sentPubkeys
    | ( $sent | map(.conn) | unique ) as $sendingConns
    | [
        (if ($sent | length) == 0 then
          "C2 meta-floor: the snapshot contains NO client->relay event frames" +
          (if ($inbound | length) > 0 then
             " (\($inbound | length) inbound frame(s) were recorded, but an event a relay sent to Haven is not evidence of what Haven sent)"
           else "" end) +
          (if ($dropped | length) > 0 then
             " (\($dropped | length) client->relay frame(s) were dropped by --exclude-conn)"
           else "" end) +
          ". Every send-side assertion in this oracle passes vacuously over an empty sample, so this is a failure, not a pass."
         else empty end),
        ( $participants[]
          | . as $p
          | if ($sentPubkeys | index($p)) == null then
              "C2 meta-floor: participant \($p[0:8])… published NO event (client->relay) below the sentinel. Either that client never armed, or its traffic never reached the recorder."
            else empty end ),
        (if ($minPub > 0) and (($publishers | length) < $minPub) then
          "C2 meta-floor: only \($publishers | length) distinct IDENTITY-key publisher(s) sent an event; at least \($minPub) required. Kinds \($ephemeralKinds) are excluded from this count because each of their events carries a fresh ephemeral key (Security Rule 2), so counting raw authors would let ONE device satisfy any floor."
         else empty end),
        (if ($minConn > 0) and (($sendingConns | length) < $minConn) then
          "C2 meta-floor: only \($sendingConns | length) distinct connection(s) sent an event; at least \($minConn) required. (A connection count is not a participant count — one device over two relays satisfies it.)"
         else empty end)
      ] as $meta

    # ---- C3 closed kind set + closed frame-verb set -------------------------
    # Malformed records lead, because they are the class that says "this oracle
    # could not read part of its own sample" and every other finding below is
    # conditional on the sample being readable.
    | [
        ( $badevents[]
          | "C3 malformed record: the event frame at wire_seq \(.seq) on \(.conn) (\(.dir)) could not be decoded — \(.why). A line this oracle cannot parse is exactly as unsafe as one it can parse and dislikes: in neither case can the traffic be shown to be safe. This used to be a SILENT DROP that reported CLEAN." ),
        ( $observedKinds[]
          | . as $k
          | if ($allowedKinds | index($k)) == null then
              "C3 closed kind set: kind \($k) was SENT to a relay and is NOT in the day-one allow-list. Either Haven started publishing something new (add it to tooling/e2e/wire_allowlist.json WITH a privacy rationale) or something is publishing that should not."
            else empty end ),
        ( $requiredKinds[]
          | . as $k
          | if ($observedKinds | index($k)) == null then
              "C3 required kind set: kind \($k) is required by the allow-list and was never SENT (client->relay). A publish path has silently stopped emitting — this is the direction a subset check cannot see, and it is asserted send-side because an inbound event of that kind proves a PEER still publishes it, not that Haven does."
            else empty end ),
        ( $observedVerbs[]
          | . as $v
          | if ($A.frame_verbs.allowed | index($v)) == null then
              "C3 closed frame set: frame verb \"\($v)\" is not in the allow-list."
            else empty end ),
        ( ($A.frame_verbs.required // [])[]
          | . as $v
          | if ($sentVerbs | index($v)) == null then
              "C3 required frame set: frame verb \"\($v)\" was never sent (client->relay)."
            else empty end ),
        ( $nulls[]
          | "C3 closed frame set: an UNRECOGNISED frame was recorded at wire_seq \(.seq) on \(.conn) (\(.dir)), \(.preview | tostring | length) preview bytes. A frame this oracle cannot classify cannot be shown to be safe. The payload is deliberately NOT echoed — an unparseable frame is precisely where unexpected plaintext would be, and this message lands in a world-readable job log. Read it from the on-runner journal at that wire_seq." ),
        ( $badverbs[]
          | "C3 closed frame set: a malformed frame was recorded at wire_seq \(.seq) (\(.dir), verb: \(.verb))." )
      ] as $kindFindings

    # ---- C4 per-kind tag sets ----------------------------------------------
    | [ $observedKinds[]
        | . as $k
        | ($A.kinds[$k | tostring]) as $spec
        | if $spec == null then empty
          else
            ( [ $uniq[] | select(.kind == $k) | .tags[] ] | unique ) as $obsTags
            | (
                ( $obsTags[]
                  | . as $t
                  | if (($spec.tags.allowed // []) | index($t)) == null then
                      "C4 tag allow-list: kind \($k) carried tag \"\($t)\", which is not allowed for that kind. A relay sees every tag name in the clear."
                    else empty end ),
                ( (($spec.tags.required // [])[])
                  | . as $t
                  | if ($obsTags | index($t)) == null then
                      "C4 required tags: kind \($k) was SENT but NO client->relay event of that kind carried the required tag \"\($t)\". Asserted send-side on purpose: an inbound event of the same kind carrying the tag says a peer still stamps it, not that Haven does."
                    else empty end )
              )
          end
      ] as $tagFindings

    # ---- C4-prime REQ filter keys ------------------------------------------
    # A REQ is the other thing a client puts on a relay, and it used to be
    # reduced to its verb — so a filter carrying `authors`, `#p`, `#h`,
    # `search` or `#g` was clean here while the summary printed
    # `verbs [… REQ …]` as if the frame had been read. Closed-world over the
    # KEY names, not their values: values are the C5.2 layer in check-wire-correlation.sh.
    | ( $A.req_filters.allowed_keys // [] ) as $allowedFilterKeys
    | ( [ $reqs[] | .keys[] ] | unique ) as $observedFilterKeys
    | [
        ( $reqs[]
          | select((.nonobj // 0) > 0)
          | "C4-REQ shape: the REQ at wire_seq \(.seq) on \(.conn) carried \(.nonobj) filter element(s) that are not JSON objects. An element this oracle cannot read as a filter cannot be shown not to carry identity material." ),
        ( $reqs[]
          | select((.nfilters // 0) == 0)
          | "C4-REQ shape: the REQ at wire_seq \(.seq) on \(.conn) carried NO filter. NIP-01 requires at least one, so this frame is not something Haven is known to construct." ),
        ( $observedFilterKeys[]
          | . as $k
          | if ($allowedFilterKeys | index($k)) == null then
              "C4-REQ filter: a REQ carried the filter key \"\($k)\", which is not in the allow-list (tooling/e2e/wire_allowlist.json `req_filters.allowed_keys`). This is closed-world by design: a filter field nobody has reasoned about cannot be shown not to carry identity or location material — NIP-50 `search` puts plaintext query terms on the wire, and a `#g` geohash filter tells the relay which area the user is watching. Add it there WITH a rationale, or stop sending it."
            else empty end )
      ] as $reqFindings

    | {
        meta: $meta,
        violations: ($kindFindings + $tagFindings + $reqFindings),
        summary: {
          sent_event_frames: ($sent | length),
          inbound_event_frames: ($inbound | length),
          malformed_records: ($badevents | length),
          unique_events: ($uniq | length),
          kinds: $observedKinds,
          inbound_kinds: ( $inbound | map(.kind) | unique ),
          verbs: $observedVerbs,
          req_filter_keys: $observedFilterKeys,
          publishers: ($publishers | length),
          sending_conns: ($sendingConns | length),
          excluded_conns: $EXCL,
          declared_harness_conns: $harness,
          excluded_frames: ($dropped | length),
          excluded_kinds: ( $dropped | map(.kind) | unique ),
          tags_by_kind: ( reduce $observedKinds[] as $k ({};
              .[$k|tostring] = ([ $uniq[] | select(.kind == $k) | .tags[] ] | unique)) )
        }
      }
  ' -- "${stream}"
}

# ---------------------------------------------------------------------------
# The allow-list linter (F10). The allow-list is DATA, and nothing checked it:
# a `kinds` that is an ARRAY passed the old two-key shape probe (`[]` is truthy
# in jq) and then aborted inside `evaluate` with an undocumented rc 5, and the
# disjointness between `kinds` and `_forbidden_by_omission` — the property the
# whole closed-world argument rests on, since a kind in both is simultaneously
# permitted and forbidden — held by care rather than by construction.
#
# Runs on EVERY invocation, not only under --lint-allowlist: a guard whose
# configuration is only validated when someone remembers to ask is a guard with
# an unvalidated configuration.
# ---------------------------------------------------------------------------
lint_allowlist() {
  local f="$1" problems
  if [[ ! -r "${f}" ]]; then
    echo "UNUSABLE: allow-list ${f} is absent or unreadable." >&2
    return "${RC_UNUSABLE}"
  fi
  if ! jq -e . -- "${f}" >/dev/null 2>&1; then
    echo "UNUSABLE: allow-list ${f} is not valid JSON." >&2
    return "${RC_UNUSABLE}"
  fi
  problems="$(
    jq -r '
      def strArray: (type == "array") and (all(.[]; type == "string"));
      def numericKeys: [ keys[] | select(test("^[0-9]+$")) ];

      [
        (if (.version | type) != "number" then "`version` is \(.version | type), not a number" else empty end),

        (if (.kinds | type) != "object" then
           "`kinds` is \(.kinds | type), not an object"
         else
           ( (.kinds | keys[])
             | select((test("^[0-9]+$") or startswith("_")) | not)
             | "`kinds` key \"\(.)\" is neither a kind number nor a `_`-prefixed note" ),
           ( .kinds as $K
             | ($K | numericKeys)[]
             | . as $k
             | ($K[$k]) as $spec
             | ( if ($spec | type) != "object" then "kind \($k) entry is \($spec | type), not an object"
                 elif ($spec.required | type) != "boolean" then "kind \($k) `required` is \($spec.required | type), not a boolean"
                 elif ($spec.tags | type) != "object" then "kind \($k) `tags` is \($spec.tags | type), not an object"
                 elif (($spec.tags.allowed | strArray) | not) then "kind \($k) `tags.allowed` is not an array of strings"
                 elif ($spec | has("tags")) and ($spec.tags | has("required")) and (($spec.tags.required | strArray) | not) then "kind \($k) `tags.required` is not an array of strings"
                 elif ($spec | has("ephemeral_pubkey")) and (($spec.ephemeral_pubkey | type) != "boolean") then "kind \($k) `ephemeral_pubkey` is \($spec.ephemeral_pubkey | type), not a boolean"
                 else
                   ( ($spec.tags.allowed) as $al
                     | ($spec.tags.required // []) as $rq
                     # `. as $t` before the lookup is load-bearing: in
                     # `$al | index(.)` the argument is evaluated against
                     # the INPUT of index, so a bare `.` there means "$al inside
                     # $al" (always 0) and the rule would never fire.
                     | ( ($rq[] | . as $t | select(($al | index($t)) == null)
                          | "kind \($k) requires tag \"\($t)\" but does not allow it — the required check could never pass"),
                         (if ($al | length) != ($al | unique | length) then "kind \($k) `tags.allowed` has duplicate entries" else empty end),
                         (if ($rq | length) != ($rq | unique | length) then "kind \($k) `tags.required` has duplicate entries" else empty end) )
                   )
                 end ) )
         end),

        (if (.frame_verbs | type) != "object" then "`frame_verbs` is \(.frame_verbs | type), not an object"
         elif ((.frame_verbs.allowed | strArray) | not) then "`frame_verbs.allowed` is not an array of strings"
         elif ((.frame_verbs.allowed | length) == 0) then "`frame_verbs.allowed` is empty — every frame would be a violation"
         elif (.frame_verbs | has("required")) and ((.frame_verbs.required | strArray) | not) then "`frame_verbs.required` is not an array of strings"
         else ( .frame_verbs.allowed as $al
                | (.frame_verbs.required // [])[]
                | . as $v
                | select(($al | index($v)) == null)
                | "`frame_verbs.required` names \"\($v)\", which `frame_verbs.allowed` does not permit — the required check could never pass" )
         end),

        (if (.req_filters | type) != "object" then "`req_filters` is \(.req_filters | type), not an object — the REQ filter-key check has no closed set to compare against"
         elif ((.req_filters.allowed_keys | strArray) | not) then "`req_filters.allowed_keys` is not an array of strings"
         elif ((.req_filters.allowed_keys | length) == 0) then "`req_filters.allowed_keys` is empty — every REQ would be a violation"
         else empty end),

        (if (._forbidden_by_omission | type) == "null" then empty
         elif (._forbidden_by_omission | type) != "object" then "`_forbidden_by_omission` is \(._forbidden_by_omission | type), not an object"
         else
           ( (._forbidden_by_omission | keys[])
             | select(test("^[0-9]+$") | not)
             | "`_forbidden_by_omission` key \"\(.)\" is not a kind number" ),
           # THE disjointness invariant. A kind in both lists is permitted and
           # forbidden at once, and which one wins is an implementation detail
           # of `evaluate` rather than a decision anyone made.
           ( (._forbidden_by_omission | keys) as $forb
             | (if (.kinds | type) == "object" then (.kinds | numericKeys) else [] end) as $allowed
             | ($forb - ($forb - $allowed))[]
             | "kind \(.) is in BOTH `kinds` and `_forbidden_by_omission` — it is permitted and forbidden at the same time" )
         end)
      ] | .[]
    ' -- "${f}" 2>&1
  )" || {
    echo "UNUSABLE: allow-list ${f} could not be linted (the linter itself failed)." >&2
    return "${RC_UNUSABLE}"
  }
  if [[ -n "${problems}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && echo "UNUSABLE: allow-list ${f} — ${line}" >&2
    done <<< "${problems}"
    return "${RC_UNUSABLE}"
  fi
  return "${RC_CLEAN}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# require_floor <flag> <value> — a participant floor must be an integer >= 2.
#
# Three separate bugs live here. A non-integer reached `(( min_pub == 0 ))`,
# where bash treats the word as a variable name, and `set -u` turned an
# operator typo into an unbound-variable abort with rc 1 — i.e. a typo read as
# a wire-privacy VIOLATION. A negative value passed the mandatory-floor gate
# (`min_conn != 0`) and then failed the `$minConn > 0` test that consumes it,
# so `--min-distinct-conns -1` both satisfied the requirement to pass a floor
# and disabled the floor. And `1` is legal arithmetic that asserts nothing: a
# snapshot with at least one client->relay event already has at least one
# sending connection and at least one publisher, which the meta-floor requires
# anyway.
require_floor() {
  local flag="$1" value="$2"
  if [[ ! "${value}" =~ ^-?[0-9]+$ ]]; then
    echo "ERROR: ${flag} needs an integer (got \"${value}\")." >&2
    usage; exit "${RC_USAGE}"
  fi
  if (( value < 2 )); then
    echo "ERROR: ${flag} must be at least 2 (got ${value})." >&2
    echo "       0 and negative values pass the mandatory-floor gate and then" >&2
    echo "       DISABLE the very check they were passed to enable; 1 is already" >&2
    echo "       implied by the meta-floor that requires a non-empty send-side" >&2
    echo "       snapshot, so it proves nothing." >&2
    usage; exit "${RC_USAGE}"
  fi
}

main() {
  local allowlist="${DEFAULT_ALLOWLIST}"
  local sentinel="" min_pub=0 min_conn=0
  local -a journals=()
  local -a participants=()
  local -a exclude_conns=()
  local _p=""

  if [[ $# -lt 1 ]]; then
    usage
    exit "${RC_USAGE}"
  fi
  if [[ "$1" == "--self-test" ]]; then
    self_test
    exit $?
  fi
  if [[ "$1" == "--lint-allowlist" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "UNUSABLE: jq is not installed; the allow-list cannot be linted." >&2
      exit "${RC_UNUSABLE}"
    fi
    local lint_target="${2:-${DEFAULT_ALLOWLIST}}"
    local lrc=0
    lint_allowlist "${lint_target}" || lrc=$?
    if (( lrc == 0 )); then
      echo "wire-journal: allow-list ${lint_target} lints clean."
    fi
    exit "${lrc}"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --journal)
        [[ $# -ge 2 ]] || { echo "ERROR: --journal needs a value" >&2; usage; exit "${RC_USAGE}"; }
        journals+=("$2"); shift 2 ;;
      --sentinel)
        [[ $# -ge 2 ]] || { echo "ERROR: --sentinel needs a value" >&2; usage; exit "${RC_USAGE}"; }
        sentinel="$2"; shift 2 ;;
      --allowlist)
        [[ $# -ge 2 ]] || { echo "ERROR: --allowlist needs a value" >&2; usage; exit "${RC_USAGE}"; }
        allowlist="$2"; shift 2 ;;
      --participant)
        [[ $# -ge 2 ]] || { echo "ERROR: --participant needs a value" >&2; usage; exit "${RC_USAGE}"; }
        # Validated as 64 hex rather than accepted verbatim: a truncated or
        # typo'd pubkey used to sail through and then simply never match any
        # author, turning an operator error into a META-FLOOR that blamed the
        # scenario for a client that had armed perfectly well.
        _p="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
        if [[ ! "${_p}" =~ ^[0-9a-f]{64}$ ]]; then
          echo "ERROR: --participant must be a 64-character hex pubkey (got ${#_p} char(s))." >&2
          echo "       A pubkey this oracle cannot match would silently become a" >&2
          echo "       META-FLOOR blamed on the scenario." >&2
          usage; exit "${RC_USAGE}"
        fi
        participants+=("${_p}"); shift 2 ;;
      --min-distinct-publishers)
        [[ $# -ge 2 ]] || { echo "ERROR: --min-distinct-publishers needs a value" >&2; usage; exit "${RC_USAGE}"; }
        require_floor --min-distinct-publishers "$2"
        min_pub="$2"; shift 2 ;;
      --min-distinct-conns)
        [[ $# -ge 2 ]] || { echo "ERROR: --min-distinct-conns needs a value" >&2; usage; exit "${RC_USAGE}"; }
        require_floor --min-distinct-conns "$2"
        min_conn="$2"; shift 2 ;;
      --exclude-conn)
        [[ $# -ge 2 ]] || { echo "ERROR: --exclude-conn needs a value" >&2; usage; exit "${RC_USAGE}"; }
        if [[ -z "$2" ]]; then
          echo "ERROR: --exclude-conn needs a non-empty conn_id." >&2; usage; exit "${RC_USAGE}"
        fi
        exclude_conns+=("$2"); shift 2 ;;
      *)
        echo "ERROR: unknown argument: $1" >&2; usage; exit "${RC_USAGE}" ;;
    esac
  done

  if (( ${#journals[@]} == 0 )); then
    echo "ERROR: at least one --journal is required." >&2
    usage; exit "${RC_USAGE}"
  fi
  if [[ -z "${sentinel}" ]]; then
    echo "ERROR: --sentinel is required. An unanchored read races background" >&2
    echo "       wakes and yields a sample nobody can reproduce." >&2
    usage; exit "${RC_USAGE}"
  fi
  if [[ ${#sentinel} -lt 8 ]]; then
    echo "ERROR: --sentinel token must be at least 8 characters (got ${#sentinel})." >&2
    echo "       A short token risks colliding with ordinary frame content." >&2
    usage; exit "${RC_USAGE}"
  fi
  # The vacuity guard on the guard: with no participant floor, a scenario in
  # which one client never armed satisfies everything else in this file.
  if (( ${#participants[@]} == 0 )) && (( min_pub == 0 )) && (( min_conn == 0 )); then
    echo "ERROR: no participant floor given. Pass at least one of --participant," >&2
    echo "       --min-distinct-publishers or --min-distinct-conns; without one" >&2
    echo "       the C2 meta-floor proves nothing about who actually transmitted." >&2
    usage; exit "${RC_USAGE}"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # Hard failure, never a skip: a guard that stands down when its dependency
    # is missing is a guard that reports green having checked nothing.
    echo "UNUSABLE: jq is not installed; the wire journal cannot be parsed." >&2
    exit "${RC_UNUSABLE}"
  fi
  # The full lint, not a two-key shape probe. The probe it replaces accepted a
  # `kinds` that was an ARRAY (`[]` is truthy in jq) and the run then aborted
  # inside `evaluate` with an undocumented rc 5.
  local alrc=0
  lint_allowlist "${allowlist}" || alrc=$?
  if (( alrc != 0 )); then
    echo "ERROR: the allow-list is the closed world this oracle compares against;" >&2
    echo "       a broken one cannot be checked against, so nothing was checked." >&2
    exit "${RC_UNUSABLE}"
  fi

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT

  local stream="${tmp}/normalized.ndjson"
  : > "${stream}"

  local j rc=0 boundary
  local unusable=0 metafloor=0
  for j in "${journals[@]}"; do
    rc=0; journal_usable "${j}" || rc=$?
    if (( rc != 0 )); then unusable=1; continue; fi
    rc=0; journal_wellformed "${j}" || rc=$?
    if (( rc != 0 )); then unusable=1; continue; fi
    boundary="$(sentinel_seq "${j}" "${sentinel}")"
    if [[ -z "${boundary}" || "${boundary}" == "null" ]]; then
      if sentinel_token_present "${j}" "${sentinel}"; then
        echo "META-FLOOR: ${j} [no sentinel FRAME] — the token appears in this" >&2
        echo "            journal but never as a c2r [\"HAVEN_WIRE_SENTINEL\",<token>]" >&2
        echo "            frame. The boundary is deliberately NOT taken from a" >&2
        echo "            substring hit: any line merely containing the token would" >&2
        echo "            move it, and event content, a NOTICE echo and a truncated" >&2
        echo "            raw_preview are all such lines." >&2
      else
        echo "META-FLOOR: ${j} [no sentinel] — the token was never recorded, so the" >&2
        echo "            read cannot be anchored and a background wake could have" >&2
        echo "            appended to the file mid-check. Did the drive target emit" >&2
        echo "            its marker frame?" >&2
      fi
      metafloor=1
      continue
    fi
    echo "wire-journal: ${j} anchored at wire_seq ${boundary}" >&2
    # The decoder's exit status is LATCHED.
    #
    # Like the `catch` arm inside `normalize`, this is unreachable by fixture:
    # the decoder is total by construction, so a non-zero status here means jq
    # itself could not run. It stays because the pre-fix failure was exactly a
    # non-zero decoder status that nobody looked at — jq reports only its LAST
    # input, and the sentinel line is by construction the last parseable input
    # at or below the boundary, so a success always followed the error. Two
    # layers, because the laundering had two independent mechanisms.
    rc=0; normalize "${j}" "${boundary}" >> "${stream}" || rc=$?
    if (( rc != 0 )); then
      echo "UNUSABLE: ${j} [decoder] — the journal decoder exited ${rc}; the sample" >&2
      echo "          could not be read, so this run proves nothing either way." >&2
      unusable=1; continue
    fi
  done

  # A broken recorder outranks a thin scenario: fix the instrument first.
  if (( unusable )); then
    echo >&2
    echo "ERROR: the wire journal could not be checked (see UNUSABLE line(s) above)." >&2
    echo "       An absent, empty, truncated or gapped journal is NOT a clean one." >&2
    echo "       This run carries no evidence about what Haven put on the wire." >&2
    exit "${RC_UNUSABLE}"
  fi
  if (( metafloor )); then
    echo >&2
    echo "ERROR: the wire journal could not be anchored (see META-FLOOR line(s) above)." >&2
    exit "${RC_METAFLOOR}"
  fi

  local participants_json="[]"
  if (( ${#participants[@]} > 0 )); then
    participants_json="$(printf '%s\n' "${participants[@]}" | jq -R . | jq -s -c .)"
  fi
  local exclude_json="[]"
  if (( ${#exclude_conns[@]} > 0 )); then
    exclude_json="$(printf '%s\n' "${exclude_conns[@]}" | jq -R . | jq -s -c .)"
  fi

  local verdict
  verdict="$(evaluate "${stream}" "${allowlist}" "${participants_json}" \
                      "${min_pub}" "${min_conn}" "${exclude_json}")"

  local n_meta n_viol
  n_meta="$(printf '%s' "${verdict}" | jq '.meta | length')"
  n_viol="$(printf '%s' "${verdict}" | jq '.violations | length')"

  printf '%s' "${verdict}" | jq -r '
    "wire-journal summary: \(.summary.unique_events) unique SENT event(s) from " +
    "\(.summary.sent_event_frames) client->relay EVENT frame(s); kinds \(.summary.kinds); " +
    "verbs \(.summary.verbs); REQ filter keys \(.summary.req_filter_keys); " +
    "\(.summary.publishers) identity-key publisher(s) over " +
    "\(.summary.sending_conns) connection(s)"' >&2
  printf '%s' "${verdict}" | jq -r '.summary.tags_by_kind | to_entries[] | "  kind \(.key) tags: \(.value)"' >&2
  # ADVISORY, never asserted: the inbound half of the journal. Reported because
  # this oracle records `dir` and therefore knows more than a relay does, and
  # discarding that knowledge silently would be its own kind of dishonesty —
  # but attributing it to Haven is what the send-side restriction exists to
  # stop. It never affects the exit code.
  printf '%s' "${verdict}" | jq -r '
    if (.summary.inbound_event_frames > 0) then
      "  advisory (NOT asserted): \(.summary.inbound_event_frames) relay->client EVENT frame(s), kinds \(.summary.inbound_kinds). Inbound traffic is a statement about what a relay or a peer sent, not about what Haven sent."
    else empty end' >&2
  # What --exclude-conn dropped, printed on every run that uses it. Partial
  # exclusion can hide a real finding, so the exclusion is never silent.
  printf '%s' "${verdict}" | jq -r '
    if ((.summary.excluded_conns | length) > 0) then
      "  \(.summary.excluded_conns) dropped from the EVENT-level attribution (\(.summary.declared_harness_conns | length) self-declared harness socket(s), the rest named by the lane): \(.summary.excluded_frames) client->relay frame(s), kinds \(.summary.excluded_kinds). Null frames, malformed records, the frame-verb set and REQ filter keys are still evaluated over those connections."
    else empty end' >&2

  if (( n_meta > 0 )); then
    printf '%s' "${verdict}" | jq -r '.meta[] | "META-FLOOR: " + .' >&2
  fi
  if (( n_viol > 0 )); then
    printf '%s' "${verdict}" | jq -r '.violations[] | "VIOLATION: " + .' >&2
  fi

  # PRECEDENCE. Normally a real finding outranks a thin sample — it is the
  # actionable one, and the META-FLOOR lines are already on stderr above. The
  # one exception is an EMPTY snapshot, where the "violations" are entirely
  # derivative: with no events at all, every required kind is trivially absent,
  # so reporting that as a closed-world finding would send triage after a
  # publish path that is working fine while the real fault (the scenario
  # produced nothing, or the sentinel landed at the head of the journal) goes
  # unnamed. Zero evidence is a meta failure, never a finding.
  #
  # A MALFORMED record is the one thing that must survive this precedence. A
  # snapshot whose only events are records the decoder could not classify is
  # not an empty snapshot — it is a snapshot full of traffic nobody can vouch
  # for — and routing it to META-FLOOR would reproduce, one level up, exactly
  # the silent drop this fix exists to close.
  local n_events n_malformed
  n_events="$(printf '%s' "${verdict}" | jq '.summary.sent_event_frames')"
  n_malformed="$(printf '%s' "${verdict}" | jq '.summary.malformed_records')"
  if (( n_events == 0 && n_malformed == 0 )); then
    echo >&2
    echo "ERROR: the sentinel-anchored snapshot contains NO client->relay events at" >&2
    echo "       all — this run proves nothing about what Haven put on the wire." >&2
    exit "${RC_METAFLOOR}"
  fi
  if (( n_viol > 0 )); then
    echo >&2
    echo "ERROR: ${n_viol} wire-privacy violation(s) — what Haven put on the relay" >&2
    echo "       is outside the closed-world allow-list (tooling/e2e/wire_allowlist.json)." >&2
    exit "${RC_VIOLATION}"
  fi
  if (( n_meta > 0 )); then
    echo >&2
    echo "ERROR: ${n_meta} meta-floor failure(s) — the journal is readable but proves" >&2
    echo "       too little for its clean verdict to mean anything." >&2
    exit "${RC_METAFLOOR}"
  fi

  echo "wire-journal: clean — closed kind set and per-kind tag sets hold over the" \
       "sentinel-anchored snapshot."
  exit "${RC_CLEAN}"
}

# ---------------------------------------------------------------------------
# Self-test. Hermetic: pure bash + jq, no network, no toolchain, no relay.
# ---------------------------------------------------------------------------

# expect_rc <want-rc> <description> <args...> — run a FULL `main` in a child
# shell and assert the exit code.
#
# Through the real entry point rather than reaching in at a helper, because
# this repo's recorded false-green (A4) did not live in the scanning helper: it
# lived in the arg loop, which printed a note and exited 0.
CASES_RUN=0
# Cases that could not run in THIS environment. Counted, not ignored: the floor
# below is exact, and an environment-conditional case has to be accounted for
# somewhere or the floor must be slackened — and a slack floor is a floor a
# case can be deleted through.
CASES_SKIPPED=0

expect_rc() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  CASES_RUN=$(( CASES_RUN + 1 ))
  bash "${SELF_PATH}" "$@" >/dev/null 2>&1 || got=$?
  if [[ "${got}" != "${want}" ]]; then
    echo "SELF-TEST FAIL: ${desc} — expected rc=${want}, got rc=${got}" >&2
    return 1
  fi
  return 0
}

# expect_msg <needle> <description> <args...> — run a FULL `main` and assert
# that <needle> appears in its stderr.
#
# An exit code says a fixture red; it does not say WHICH rule red. A fixture
# checked by exit code alone keeps passing when a later edit makes it fire on a
# NEIGHBOURING rule instead, and at that point the rule the fixture was written
# for is unexercised while the suite is still green. That is not hypothetical
# here: a mutation sweep found four working rules in this file that no fixture
# reached, and every one of them was invisible precisely because the fixtures
# nearby asserted only a number.
#
# So every fixture that can plausibly fire more than one rule is paired with an
# `expect_msg` naming the one it exists for, and where a fixture is genuinely
# over-determined it is ALSO split into an unambiguous control.
expect_msg() {
  local needle="$1" desc="$2"
  shift 2
  local out
  CASES_RUN=$(( CASES_RUN + 1 ))
  out="$(bash "${SELF_PATH}" "$@" 2>&1 || true)"
  if [[ "${out}" != *"${needle}"* ]]; then
    echo "SELF-TEST FAIL: ${desc} — stderr did not contain \"${needle}\"" >&2
    return 1
  fi
  return 0
}

# expect_no_msg <needle> <description> <args...> — the converse: prove a
# fixture is NOT firing a rule it must not reach. Used where a case's whole
# point is that one specific finding is absent.
expect_no_msg() {
  local needle="$1" desc="$2"
  shift 2
  local out
  CASES_RUN=$(( CASES_RUN + 1 ))
  out="$(bash "${SELF_PATH}" "$@" 2>&1 || true)"
  if [[ "${out}" == *"${needle}"* ]]; then
    echo "SELF-TEST FAIL: ${desc} — stderr unexpectedly contained \"${needle}\"" >&2
    return 1
  fi
  return 0
}

# ---- fixture builders -----------------------------------------------------
# Every fixture is built line by line through `jline`, which stamps the
# monotonic `wire_seq` itself. Hand-numbering would make a fixture's own
# sequence a source of accidental UNUSABLE verdicts and mask the real subject.

FIXTURE_SEQ=0
FIXTURE_FILE=""

fx_begin() { FIXTURE_FILE="$1"; FIXTURE_SEQ=0; : > "${FIXTURE_FILE}"; }

# jline <dir> <conn> <frame-json> — one `type:"frame"` traffic line, in the
# recorder's real field shape (`type`, `relay_url` and `listen` included).
jline() {
  local dir="$1" conn="$2" frame="$3"
  printf '{"wire_seq":%d,"type":"frame","conn_id":"%s","ts_ms":%d,"dir":"%s","relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7877","frame":%s,"raw_len":%d}\n' \
    "${FIXTURE_SEQ}" "${conn}" $(( 1785886144000 + FIXTURE_SEQ )) "${dir}" "${frame}" "${#frame}" \
    >> "${FIXTURE_FILE}"
  FIXTURE_SEQ=$(( FIXTURE_SEQ + 1 ))
}

# jconn <conn> [reason] — a connection-lifecycle line. These carry no `dir` and
# no `frame`, so they exist in the fixtures to prove the oracle tolerates them:
# an earlier draft required the traffic fields on every line, which would have
# made every real journal UNUSABLE.
jconn() {
  local conn="$1" reason="${2:-}"
  if [[ -n "${reason}" ]]; then
    printf '{"wire_seq":%d,"type":"conn_error","conn_id":"%s","ts_ms":%d,"relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7877","reason":"%s"}\n' \
      "${FIXTURE_SEQ}" "${conn}" $(( 1785886144000 + FIXTURE_SEQ )) "${reason}" >> "${FIXTURE_FILE}"
  else
    printf '{"wire_seq":%d,"type":"conn_open","conn_id":"%s","ts_ms":%d,"relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7877"}\n' \
      "${FIXTURE_SEQ}" "${conn}" $(( 1785886144000 + FIXTURE_SEQ )) >> "${FIXTURE_FILE}"
  fi
  FIXTURE_SEQ=$(( FIXTURE_SEQ + 1 ))
}

# jsentinel <conn> — the recorder's sentinel marker, verbatim. The proxy
# intercepts `["HAVEN_WIRE_SENTINEL","<token>"]`, records it as an ordinary
# c2r frame and never forwards it upstream, so it is journalled exactly like
# this and no relay ever sees it.
jsentinel() { jline c2r "$1" "[\"HAVEN_WIRE_SENTINEL\",\"${SENTINEL}\"]"; }

# jdeclare <conn> — a HARNESS-SOCKET DECLARATION, verbatim
# (`TestRelay._harnessSocketDeclaration`). Same intercepted verb, deliberately
# NOT the run's token: attribution keys on the verb, while the boundary keys on
# `frame[1] == <token>` — so a declaration marks its connection without being
# able to move the snapshot.
jdeclare() { jline c2r "$1" '["HAVEN_WIRE_SENTINEL","HAVEN_WIRE_CONN"]'; }

# ev <kind> <id> <pubkey> <tags-json>
ev() {
  printf '{"id":"%s","kind":%s,"pubkey":"%s","created_at":1785886144,"tags":%s,"content":"","sig":"%s"}' \
    "$2" "$1" "$3" "$4" "$(printf 'f%.0s' {1..128})"
}

# ev_raw <kind> <id-json> <pubkey-json> <tags-json> — the same event shape with
# every field interpolated as RAW JSON, so a fixture can build an event whose
# `id` is a number or whose `tags` is a string. `ev` quotes them, which is what
# a well-formed event needs and exactly what a malformed-record fixture has to
# be able to bypass: these are the shapes that used to abort jq mid-record and
# vanish from the sample.
ev_raw() {
  printf '{"id":%s,"kind":%s,"pubkey":%s,"created_at":1785886144,"tags":%s,"content":"","sig":"%s"}' \
    "$2" "$1" "$3" "$4" "$(printf 'f%.0s' {1..128})"
}

# jlifecycle_with_traffic <type> <conn> <dir> <frame-json> — a line labelled as
# a connection-lifecycle record that ALSO carries `dir` and `frame`.
#
# The producer contract says lifecycle records carry neither, and the two
# oracles over this journal split on it: this file discriminates traffic with
# `type == "frame"` and skips such a line as self-description, while
# check-wire-correlation.sh uses `has("frame")` and decodes it as traffic. A
# line the two consumers classify differently is a smuggling channel, so the
# well-formedness check now refuses it.
jlifecycle_with_traffic() {
  local rtype="$1" conn="$2" dir="$3" frame="$4"
  printf '{"wire_seq":%d,"type":"%s","conn_id":"%s","ts_ms":%d,"dir":"%s","relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7877","frame":%s}\n' \
    "${FIXTURE_SEQ}" "${rtype}" "${conn}" $(( 1785886144000 + FIXTURE_SEQ )) "${dir}" "${frame}" \
    >> "${FIXTURE_FILE}"
  FIXTURE_SEQ=$(( FIXTURE_SEQ + 1 ))
}

# jraw <json-line> — a fixture line stamped with the next `wire_seq` but
# otherwise verbatim. Used where a case needs a field combination the typed
# helpers deliberately cannot produce.
jraw() {
  printf '%s\n' "$1" | jq -c --argjson s "${FIXTURE_SEQ}" '.wire_seq = $s' >> "${FIXTURE_FILE}"
  FIXTURE_SEQ=$(( FIXTURE_SEQ + 1 ))
}

# renumber <in> <out> — rewrite `wire_seq` as a gapless 0-based sequence.
#
# Fixtures built by DELETING lines from a healthy journal would otherwise trip
# the gap check, and the resulting UNUSABLE verdict would mask the C3/C4
# subject the fixture actually exists to prove. Renumbering keeps each fixture
# testing exactly one thing.
renumber() {
  jq -c -n '[inputs] | to_entries | map(.value.wire_seq = .key | .value) | .[]' -- "$1" > "$2"
}

# The two participant identities used across fixtures (64-hex, obviously fake).
readonly PK_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly PK_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
readonly PK_EPH1="1111111111111111111111111111111111111111111111111111111111111111"
readonly PK_EPH2="2222222222222222222222222222222222222222222222222222222222222222"
readonly SENTINEL="HAVEN_WIRE_SENTINEL:selftest0001"

# The real kind-30443 tag set, copied from
# haven-core/src/relay/maintenance/key_package.rs:479-486. An unfaithful test
# double is how a self-test comes to prove something other than what it claims:
# a fixture carrying invented tag names would pass the allow-list only because
# the allow-list had been written from the same invention.
readonly KP_TAGS='[["d","haven-kp-0"],["mls_protocol_version","1.0"],["i","0001"],["mls_ciphersuite","0x0001"],["mls_extensions","0x0002"],["mls_proposals","0x0003"],["app_components","0x8005"]]'

# write_healthy <path> — a journal a healthy full scenario would produce.
#
# Deliberately includes the two shapes that would break a naive oracle:
#   * the SAME event id repeated (published to two relays, echoed back to a
#     subscriber) — a multiset assertion would trip on it;
#   * a kind-445 commit carrying `h` ONLY, beside an application message
#     carrying `h` + `expiration` — set EQUALITY on the tag set would trip on
#     the first of those.
write_healthy() {
  fx_begin "$1"
  # c0 carries NOTHING but the harness marker, which is the real topology: the
  # sentinel comes off the drive's own TestRelay socket, never off the relay
  # client the app under test publishes through. A marker on the publishing
  # connection would now declare THAT connection a harness socket and drop its
  # events from attribution.
  jconn c0
  jconn c1
  jconn c2
  jconn c3
  # A connection that never came up. Present in the BASELINE fixture, not in a
  # fixture of its own, so every downstream case inherits it: a lifecycle
  # record must never be mistaken for traffic, and must never make an
  # otherwise-clean journal UNUSABLE.
  jconn c4 "upstream unreachable"
  jline c2r c1 "[\"EVENT\",$(ev 0 "e00" "${PK_A}" '[]')]"
  jline r2c c1 '["OK","e00",true,""]'
  jline c2r c1 "[\"EVENT\",$(ev 10002 "e02" "${PK_A}" '[["r","ws://localhost:7777"]]')]"
  jline c2r c1 "[\"EVENT\",$(ev 10050 "e03" "${PK_A}" '[["relay","ws://localhost:7777"]]')]"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c2 "[\"EVENT\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline c2r c2 "[\"EVENT\",$(ev 10002 "e06" "${PK_B}" '[["r","ws://localhost:7777"]]')]"
  jline c2r c1 '["REQ","sub-kp",{"kinds":[30443],"limit":50}]'
  jline r2c c1 "[\"EVENT\",\"sub-kp\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline r2c c1 '["EOSE","sub-kp"]'
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  # commit: `h` only.
  jline c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" '[["h","cafebabe"]]')]"
  # application message: `h` + NIP-40 expiration.
  jline c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  # the SAME event, published to the second relay and echoed to a subscriber.
  jline c2r c3 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jline r2c c2 "[\"EVENT\",\"sub-h\",$(ev 445 "e09" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jline c2r c2 "[\"EVENT\",$(ev 445 "e10" "${PK_EPH1}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jline c2r c1 '["CLOSE","sub-kp"]'
  jsentinel c0
}

self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  if ! command -v jq >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: jq is not installed; this guard cannot run." >&2
    return 1
  fi

  local allow="${DEFAULT_ALLOWLIST}"
  if [[ ! -r "${allow}" ]]; then
    echo "SELF-TEST FAIL: allow-list ${allow} not found." >&2
    return 1
  fi

  # The shipped allow-list must lint. It is the closed world every assertion
  # below compares against, and nothing used to check it at all.
  if ! bash "${SELF_PATH}" --lint-allowlist "${allow}" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: the shipped allow-list ${allow} does not lint." >&2
    bash "${SELF_PATH}" --lint-allowlist "${allow}" >&2 || true
    fail=1
  fi

  local -a base=(--sentinel "${SENTINEL}" --allowlist "${allow}"
                 --participant "${PK_A}" --participant "${PK_B}"
                 --min-distinct-publishers 2
                 --min-distinct-conns 2)

  # -------------------------------------------------------------------------
  # POSITIVE CONTROL. Without it an oracle hard-coded to red would look correct
  # on every fixture below.
  # -------------------------------------------------------------------------
  local healthy="${tmp}/healthy.ndjson"
  write_healthy "${healthy}"
  expect_rc 0 "healthy journal passes" --journal "${healthy}" "${base[@]}" || fail=1

  # The multiset trap. `write_healthy` already publishes e09 three times, but a
  # case asserting that with the SAME journal and the SAME arguments as the
  # positive control is a byte-identical re-invocation: it cannot fail unless
  # the control does, and it was nevertheless load-bearing to MIN_CASES. This
  # fixture instead pushes the multiplicity somewhere no legitimate run reaches
  # — one event body repeated eleven times across four connections and both
  # directions — so any count that ever creeps into an assertion trips here and
  # not in the control.
  local multiset="${tmp}/multiset.ndjson"
  fx_begin "${tmp}/multiset.raw"
  local i
  for i in 1 2 3 4 5 6; do
    jline c2r c1 "[\"EVENT\",$(ev 445 "eMULT" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
    jline r2c c2 "[\"EVENT\",\"sub-h\",$(ev 445 "eMULT" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  done
  cat "${healthy}" >> "${tmp}/multiset.raw"
  renumber "${tmp}/multiset.raw" "${multiset}"
  expect_rc 0 "one event body repeated 12x over 2 connections is still ONE event" \
    --journal "${multiset}" "${base[@]}" || fail=1
  # ...and the de-duplication is OBSERVABLE, not merely inferred from a rc 0:
  # a journal whose entire send side is one body repeated six times must report
  # exactly one unique event.
  local onebody="${tmp}/onebody.ndjson"
  fx_begin "${onebody}"
  for i in 1 2 3 4 5 6; do
    jline c2r c1 "[\"EVENT\",$(ev 445 "eONE" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  done
  jsentinel c0
  expect_msg "1 unique SENT event(s) from 6 client->relay EVENT frame(s)" \
    "the repeats de-duplicate to one, and the summary says so" \
    --journal "${onebody}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # -------------------------------------------------------------------------
  # UNUSABLE (rc 3) — the anti-vacuity class. Each is a DIFFERENT operator
  # failure and must stay distinguishable from both clean and violating.
  # -------------------------------------------------------------------------
  local absent="${tmp}/never-written.ndjson"
  local empty="${tmp}/empty.ndjson"
  local unreadable="${tmp}/unreadable.ndjson"
  local truncated="${tmp}/truncated.ndjson"
  local gapped="${tmp}/gapped.ndjson"
  local duped="${tmp}/duped.ndjson"
  local headless="${tmp}/headless.ndjson"
  local nofield="${tmp}/nofield.ndjson"
  local adirectory="${tmp}/a-directory.ndjson"

  : > "${empty}"
  cp "${healthy}" "${unreadable}"; chmod 000 "${unreadable}"
  mkdir -p "${adirectory}"

  # Truncated mid-line: the tail of the last write never made it to disk. This
  # is the shape a killed recorder leaves, and it must not be silently skipped.
  head -c $(( $(wc -c < "${healthy}") - 40 )) "${healthy}" > "${truncated}"

  # A dropped line: the contract says the recorder never drops one, so a hole
  # means the checked sample is not the transmitted sample.
  grep -v '"wire_seq":5,' "${healthy}" > "${gapped}"

  # A repeated wire_seq: two lines claiming the same position in the total
  # order means the sequence cannot be trusted to bound anything.
  { cat "${healthy}"; grep '"wire_seq":3,' "${healthy}"; } > "${duped}"

  # Head truncation: log rotation, or a reader that started late. The sample
  # silently begins after an unknown amount of traffic.
  grep -v '"wire_seq":0,' "${healthy}" > "${headless}"

  # A line missing a contract field.
  { cat "${healthy}"; printf '{"conn_id":"cX","ts_ms":1,"dir":"c2r","frame":["EOSE","x"]}\n'; } > "${nofield}"

  expect_rc 3 "absent journal"          --journal "${absent}"    "${base[@]}" || fail=1
  expect_rc 3 "empty journal"           --journal "${empty}"     "${base[@]}" || fail=1
  expect_rc 3 "journal truncated mid-line" --journal "${truncated}" "${base[@]}" || fail=1
  expect_rc 3 "journal with a dropped line (wire_seq gap)" --journal "${gapped}" "${base[@]}" || fail=1
  expect_rc 3 "journal with a duplicated wire_seq" --journal "${duped}" "${base[@]}" || fail=1
  expect_rc 3 "journal whose head is truncated (does not start at 0)" --journal "${headless}" "${base[@]}" || fail=1
  expect_rc 3 "journal line missing a contract field" --journal "${nofield}" "${base[@]}" || fail=1
  # A path that exists but is not a file. Unconditional, unlike the mode-000
  # fixture below, and it covers the same "exists, cannot be read as a journal"
  # branch on a runner where the test process is uid 0.
  expect_rc 3 "a journal path that is a directory" --journal "${adirectory}" "${base[@]}" || fail=1
  # One good journal must never vouch for a missing one.
  expect_rc 3 "healthy journal + absent journal" \
    --journal "${healthy}" --journal "${absent}" "${base[@]}" || fail=1

  # CONDITIONAL, and deliberately NOT counted in MIN_CASES — see the floor at
  # the end of this function. mode 000 does not stop uid 0, so this fixture
  # cannot run as root; counting it would make the floor accuse a root runner
  # of having deleted cases. repo-guards.yml runs this self-test.
  if [[ -r "${unreadable}" ]]; then
    echo "check-wire-journal: NOTE — skipping the unreadable-journal fixture" \
         "(running as uid $(id -u), which bypasses mode 000); counted as skipped." >&2
    CASES_SKIPPED=$(( CASES_SKIPPED + 1 ))
  else
    expect_rc 3 "unreadable journal" --journal "${unreadable}" "${base[@]}" || fail=1
  fi
  chmod 644 "${unreadable}" 2>/dev/null || true

  # The documented `type == "frame"` <=> `"frame" in line` equivalence. A
  # kind-3 EVENT on a line labelled `type:"conn_open"` was invisible to THIS
  # oracle (it filters traffic on `type`) while check-wire-correlation.sh
  # decoded it as traffic (it filters on `has("frame")`). Two consumers
  # disagreeing about what a line IS is a smuggling channel, and neither said
  # so. It is now UNUSABLE — the producer is the only place that can resolve it.
  local lifecycletraffic="${tmp}/lifecycle-traffic.ndjson"
  fx_begin "${lifecycletraffic}"
  jconn c1
  jlifecycle_with_traffic conn_open c1 c2r "[\"EVENT\",$(ev 3 "eSNEAK" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c2 "[\"EVENT\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline c2r c1 '["REQ","sub-kp",{"kinds":[30443],"limit":50}]'
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jsentinel c0
  expect_rc 3 "an EVENT smuggled onto a conn_open line is UNUSABLE, not invisible" \
    --journal "${lifecycletraffic}" "${base[@]}" || fail=1
  expect_msg "lifecycle record carries a \`frame\` key" \
    "...and the message names the contract clause it broke" \
    --journal "${lifecycletraffic}" "${base[@]}" || fail=1

  # The other half of the same equivalence: a lifecycle record carrying `dir`.
  local lifecycledir="${tmp}/lifecycle-dir.ndjson"
  fx_begin "${lifecycledir}"
  jraw '{"type":"conn_open","conn_id":"c1","ts_ms":1,"dir":"c2r","relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7877"}'
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jsentinel c0
  expect_rc 3 "a lifecycle record carrying \`dir\` is UNUSABLE" \
    --journal "${lifecycledir}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # A conn_error with no `reason`. The contract says it carries one, and a
  # lifecycle record missing its own field is the recorder mis-describing
  # itself.
  local noreason="${tmp}/noreason.ndjson"
  fx_begin "${noreason}"
  jraw '{"type":"conn_error","conn_id":"c1","ts_ms":1,"relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7877"}'
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jsentinel c0
  expect_rc 3 "a conn_error with no reason is UNUSABLE" \
    --journal "${noreason}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # -------------------------------------------------------------------------
  # META-FLOOR (rc 4) — C2. The journal parses; it just proves too little.
  # -------------------------------------------------------------------------
  local nosentinel="${tmp}/nosentinel.ndjson"
  local onlyA="${tmp}/onlyA.ndjson"
  local sentinelfirst="${tmp}/sentinelfirst.ndjson"

  grep -v 'HAVEN_WIRE_SENTINEL' "${healthy}" > "${tmp}/nosentinel.raw"
  renumber "${tmp}/nosentinel.raw" "${nosentinel}"
  expect_rc 4 "journal with no sentinel cannot be anchored" \
    --journal "${nosentinel}" "${base[@]}" || fail=1

  # Only one participant ever transmitted — the exact scenario in which a
  # client silently never armed and every other assertion still holds.
  fx_begin "${onlyA}"
  jline c2r c1 "[\"EVENT\",$(ev 0 "e00" "${PK_A}" '[]')]"
  jline c2r c1 "[\"EVENT\",$(ev 10002 "e02" "${PK_A}" '[["r","ws://localhost:7777"]]')]"
  jline c2r c1 "[\"EVENT\",$(ev 10050 "e03" "${PK_A}" '[["relay","ws://localhost:7777"]]')]"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" '[["h","cafebabe"]]')]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jline c2r c1 '["REQ","sub-kp",{"kinds":[30443],"limit":50}]'
  jsentinel c0
  expect_rc 4 "only one participant transmitted (per-pubkey floor)" \
    --journal "${onlyA}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --participant "${PK_A}" --participant "${PK_B}" || fail=1
  # ...and the connection floor catches the same scenario without needing to
  # know either identity pubkey, which is the lever a lane uses when all its
  # traffic is ephemerally keyed.
  expect_rc 4 "only one connection transmitted (per-conn floor)" \
    --journal "${onlyA}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # THE PUBLISHER FLOOR, and the reason it counts identity keys only.
  #
  # `onlyA` is ONE device. It sends a 1059 signed by PK_EPH1 and two 445s
  # signed by PK_EPH1 and PK_EPH2 — because Security Rule 2 mints a fresh
  # keypair for every one of those. Counting raw authors made this journal
  # report THREE distinct publishers, so `--min-distinct-publishers 3` passed
  # on a single-participant scenario: the floor was satisfied by the very key
  # rotation that makes those events unattributable. Excluding the kinds
  # flagged `ephemeral_pubkey` in the allow-list leaves exactly one publisher,
  # which is the truth.
  expect_rc 4 "the publisher floor counts identities, not ephemeral keys" \
    --journal "${onlyA}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-publishers 3 || fail=1
  expect_msg "distinct IDENTITY-key publisher(s) sent an event" \
    "...and the message says which population it counted" \
    --journal "${onlyA}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-publishers 3 || fail=1
  # The floor's positive control: the healthy journal has two real identities.
  expect_rc 0 "two identity publishers satisfy --min-distinct-publishers 2" \
    --journal "${healthy}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-publishers 2 || fail=1

  # A journal whose sentinel is the FIRST line: the snapshot is empty, so every
  # assertion below it would pass over nothing.
  fx_begin "${sentinelfirst}"
  jsentinel c0
  jline c2r c1 "[\"EVENT\",$(ev 445 "e99" "${PK_EPH1}" '[["h","cafebabe"]]')]"
  expect_rc 4 "sentinel at the head yields an empty snapshot" \
    --journal "${sentinelfirst}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # -------------------------------------------------------------------------
  # VIOLATION (rc 1) — C3/C4.
  # -------------------------------------------------------------------------
  local badkind="${tmp}/badkind.ndjson"
  local badtag="${tmp}/badtag.ndjson"
  local missingkind="${tmp}/missingkind.ndjson"
  local nullframe="${tmp}/nullframe.ndjson"
  local badverb="${tmp}/badverb.ndjson"

  # C3, subset direction: a kind that is not in the allow-list at all. Kind 3
  # is the canonical one — a contact list walks the user's social graph out —
  # and it must land BELOW the sentinel, or the snapshot fixture further down
  # would be the thing under test instead of the kind check.
  fx_begin "${badkind}"
  jline c2r c1 "[\"EVENT\",$(ev 3 "eBAD" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${badkind}"
  expect_rc 1 "unexpected kind fails the closed kind set (C3)" \
    --journal "${badkind}" "${base[@]}" || fail=1
  expect_msg "kind 3 was SENT to a relay" "...naming the kind check, not a neighbour" \
    --journal "${badkind}" "${base[@]}" || fail=1

  # The same kind, on a kind that is FORBIDDEN BY OMISSION rather than by an
  # explicit forbid-list entry. This is the difference the whole workstream
  # exists for: kind 24242 (Blossom authorization) is an HTTP header that must
  # never reach a relay, and the forbid-list this oracle replaces — {3, 443,
  # 10051} — could not see it. Nor could it see a kind-9 rumor, a bare 444, a
  # kind-450 identity proof, or anything MDK adds next.
  local omitted="${tmp}/omitted.ndjson"
  fx_begin "${omitted}"
  jline c2r c1 "[\"EVENT\",$(ev 24242 "eBLOSSOM" "${PK_A}" '[["t","upload"],["x","deadbeef"],["expiration","1785886204"]]')]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${omitted}"
  expect_rc 1 "a kind forbidden BY OMISSION is caught (the forbid-list could not)" \
    --journal "${omitted}" "${base[@]}" || fail=1

  # C3, superset direction: a required kind that never appears. Built by
  # dropping every kind-445 from the healthy journal and renumbering.
  jq -c 'select((.frame | tostring | test("\"kind\":445")) | not)' "${healthy}" \
    > "${tmp}/missingkind.raw"
  renumber "${tmp}/missingkind.raw" "${missingkind}"
  expect_rc 1 "missing required kind fails the required set (C4 direction)" \
    --journal "${missingkind}" "${base[@]}" || fail=1

  # C4, subset direction: a tag name that is not allowed on that kind. A `p`
  # tag on a kind-445 re-attaches recipients to a message whose whole design
  # is that the relay cannot enumerate the circle.
  # (replaces the commit 445 `e08` with one carrying an extra `p` tag)
  jq -c "if (.frame | tostring | test(\"e08\")) then .frame = [\"EVENT\", $(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"cafebabe\"],[\"p\",\"${PK_B}\"]]")] else . end" \
    "${healthy}" > "${badtag}"
  expect_rc 1 "unexpected tag on a known kind fails the tag allow-list (C4)" \
    --journal "${badtag}" "${base[@]}" || fail=1
  expect_msg "kind 445 carried tag \"p\"" "...naming the tag allow-list, not the required set" \
    --journal "${badtag}" "${base[@]}" || fail=1

  # De-duplication must never HIDE a finding. Two frames sharing an event id
  # but differing in body: keying the de-dup on the id alone would keep
  # whichever came first and let the other answer for it, which is the one way
  # a set-based oracle can be made blind by its own determinism fix.
  local idcollision="${tmp}/idcollision.ndjson"
  fx_begin "${idcollision}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eDUP" "${PK_EPH1}" '[["h","cafebabe"]]')]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eDUP" "${PK_EPH1}" "[[\"h\",\"cafebabe\"],[\"p\",\"${PK_B}\"]]")]"
  jq -c '.wire_seq = .wire_seq + 2' "${healthy}" >> "${idcollision}"
  expect_rc 1 "two bodies under one event id are both checked, not collapsed" \
    --journal "${idcollision}" "${base[@]}" || fail=1

  # C4, superset direction, ONE finding at a time.
  #
  # The single fixture this replaces stripped ALL tags off every 445, which
  # fires the `h` finding AND the `expiration` finding while its name claimed
  # one. An over-determined fixture keeps passing after a later edit breaks the
  # rule it was written for, because the neighbour still reds — so each
  # required tag now gets a fixture that removes exactly it.
  local missingh="${tmp}/missing-h.ndjson"
  jq -c 'if (.frame | tostring | test("\"kind\":445")) then
           .frame = (.frame | map(if (type == "object" and .kind == 445)
                                  then .tags = [ .tags[] | select(.[0] != "h") ]
                                  else . end))
         else . end' "${healthy}" > "${missingh}"
  expect_rc 1 "a 445 stream with no \`h\` tag at all fails the required set (C4)" \
    --journal "${missingh}" "${base[@]}" || fail=1
  expect_msg "required tag \"h\"" "...and it is the \`h\` rule that fired" \
    --journal "${missingh}" "${base[@]}" || fail=1
  expect_no_msg "required tag \"expiration\"" \
    "...and ONLY the \`h\` rule: the fixture is not over-determined" \
    --journal "${missingh}" "${base[@]}" || fail=1

  # THE SHARPEST CHECK IN THE ALLOW-LIST, in its own fixture: the NIP-40 TTL
  # silently stops being stamped on location events.
  local missingexp="${tmp}/missing-expiration.ndjson"
  jq -c 'if (.frame | tostring | test("\"kind\":445")) then
           .frame = (.frame | map(if (type == "object" and .kind == 445)
                                  then .tags = [ .tags[] | select(.[0] != "expiration") ]
                                  else . end))
         else . end' "${healthy}" > "${missingexp}"
  expect_rc 1 "a 445 stream with no \`expiration\` fails the required set (C4)" \
    --journal "${missingexp}" "${base[@]}" || fail=1
  expect_msg "required tag \"expiration\"" "...and it is the TTL rule that fired" \
    --journal "${missingexp}" "${base[@]}" || fail=1
  expect_no_msg "required tag \"h\"" \
    "...and ONLY the TTL rule: the fixture is not over-determined" \
    --journal "${missingexp}" "${base[@]}" || fail=1

  # An UNRECOGNISED frame. The contract records these as `frame:null` rather
  # than dropping them; a frame this oracle cannot classify cannot be shown to
  # be safe, so it is a finding, not noise.
  jq -c 'if (.wire_seq == 5) then (.frame = null | .raw_preview = "<binary frame>") else . end' \
    "${healthy}" > "${nullframe}"
  expect_rc 1 "an unrecognised (null) frame is a finding, not noise" \
    --journal "${nullframe}" "${base[@]}" || fail=1
  expect_msg "an UNRECOGNISED frame was recorded" "...naming the null-frame rule" \
    --journal "${nullframe}" "${base[@]}" || fail=1

  # An unknown frame VERB — the same closed-world argument one level up.
  jq -c 'if (.wire_seq == 5) then .frame = ["SLURP","everything"] else . end' \
    "${healthy}" > "${badverb}"
  expect_rc 1 "an unknown frame verb fails the closed frame set" \
    --journal "${badverb}" "${base[@]}" || fail=1
  expect_msg "frame verb \"SLURP\" is not in the allow-list" "...naming the verb rule" \
    --journal "${badverb}" "${base[@]}" || fail=1

  # THE REQUIRED half of the frame-verb set, which nothing reached: mutating it
  # to `if false` left the suite green. A journal Haven never subscribed on is
  # a journal whose whole receive path is dead, and the verb set is where that
  # is declared. Every REQ stripped, renumbered so the gap check does not mask
  # the subject.
  local noreq="${tmp}/noreq.ndjson"
  jq -c 'select((.frame | tostring | startswith("[\"REQ\"")) | not)' "${healthy}" \
    > "${tmp}/noreq.raw"
  renumber "${tmp}/noreq.raw" "${noreq}"
  expect_rc 1 "a run that never sent a REQ fails the REQUIRED frame-verb set" \
    --journal "${noreq}" "${base[@]}" || fail=1
  expect_msg "frame verb \"REQ\" was never sent" "...naming the required-verb rule" \
    --journal "${noreq}" "${base[@]}" || fail=1

  # A `badverb` shape that LOSES EVIDENCE rather than merely muting a message.
  # `["EVENT","a-string-not-an-event"]` carries no event object at all: with
  # the rule no-opped it is dropped from the kind check AND the tag check in
  # silence, so the frame that reached a relay is simply not in the sample.
  local noeventobj="${tmp}/noeventobj.ndjson"
  fx_begin "${noeventobj}"
  jline c2r c1 '["EVENT","a-string-not-an-event"]'
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${noeventobj}"
  expect_rc 1 "an EVENT frame with no event object is a finding, not a drop" \
    --journal "${noeventobj}" "${base[@]}" || fail=1
  expect_msg "carries no event object" "...naming the missing-event-object rule" \
    --journal "${noeventobj}" "${base[@]}" || fail=1

  # A frame whose verb is not a string, and a frame that is not an array.
  local nonstringverb="${tmp}/nonstringverb.ndjson"
  fx_begin "${nonstringverb}"
  jline c2r c1 '[12345,"payload"]'
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${nonstringverb}"
  expect_rc 1 "a frame whose verb is not a string is a malformed frame" \
    --journal "${nonstringverb}" "${base[@]}" || fail=1
  local objframe="${tmp}/objframe.ndjson"
  fx_begin "${objframe}"
  jline c2r c1 '{"EVENT":"not-an-array"}'
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${objframe}"
  expect_rc 1 "a frame that is a JSON object, not an array, is a malformed frame" \
    --journal "${objframe}" "${base[@]}" || fail=1

  # -------------------------------------------------------------------------
  # MALFORMED RECORDS (F1). THE PROBE THAT FOUND THE BUG, verbatim: a kind-3
  # contact list whose `id` is the number 0. Pre-fix, `ascii_downcase` on a
  # number aborted that record, jq dropped it and carried on, and the run
  # reported CLEAN — while the byte-identical well-formed event reported a
  # VIOLATION. The control below pins that equivalence: the SAME event, the
  # SAME position, differing only in whether a field has its contract type,
  # must reach the same verdict.
  # -------------------------------------------------------------------------
  local malformed_id="${tmp}/malformed-id.ndjson"
  fx_begin "${malformed_id}"
  jline c2r c1 "[\"EVENT\",$(ev_raw 3 0 "\"${PK_A}\"" "[[\"p\",\"${PK_B}\"]]")]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${malformed_id}"
  expect_rc 1 "a kind-3 whose id is a NUMBER is a finding, not a silent drop" \
    --journal "${malformed_id}" "${base[@]}" || fail=1
  expect_msg "id is number, not a string" "...naming the field and its wrong type" \
    --journal "${malformed_id}" "${base[@]}" || fail=1
  expect_no_msg "sig" "the malformed-record message never echoes the payload" \
    --journal "${malformed_id}" "${base[@]}" || fail=1

  local malformed_pubkey="${tmp}/malformed-pubkey.ndjson"
  fx_begin "${malformed_pubkey}"
  jline c2r c1 "[\"EVENT\",$(ev_raw 3 "\"eBAD\"" 12345 "[[\"p\",\"${PK_B}\"]]")]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${malformed_pubkey}"
  expect_rc 1 "a kind-3 whose pubkey is a NUMBER is a finding, not a silent drop" \
    --journal "${malformed_pubkey}" "${base[@]}" || fail=1
  # Each field's check is named, not just its exit code. Remove any ONE of them
  # and the outer try/catch still reports SOMETHING at the same exit code —
  # so an exit-code-only fixture cannot tell "the field was type-checked" from
  # "the decoder tripped over it and the catch tidied up".
  expect_msg "pubkey is number, not a string" "...naming the pubkey field check" \
    --journal "${malformed_pubkey}" "${base[@]}" || fail=1

  local malformed_tags="${tmp}/malformed-tags.ndjson"
  fx_begin "${malformed_tags}"
  jline c2r c1 "[\"EVENT\",$(ev_raw 3 "\"eBAD\"" "\"${PK_A}\"" '"not-an-array"')]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${malformed_tags}"
  expect_rc 1 "a kind-3 whose tags is a STRING is a finding, not a silent drop" \
    --journal "${malformed_tags}" "${base[@]}" || fail=1
  expect_msg "tags is string, not an array" "...naming the tags field check" \
    --journal "${malformed_tags}" "${base[@]}" || fail=1

  # A `kind` that is not a number. It would otherwise flow into the kind set as
  # a STRING and red as "kind \"445\" is not in the allow-list", which sends
  # triage after a publish path instead of after a malformed frame.
  local malformed_kind="${tmp}/malformed-kind.ndjson"
  fx_begin "${malformed_kind}"
  jline c2r c1 "[\"EVENT\",$(ev_raw '"445"' "\"eBAD\"" "\"${PK_EPH1}\"" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${malformed_kind}"
  expect_rc 1 "an event whose kind is a STRING is a malformed record" \
    --journal "${malformed_kind}" "${base[@]}" || fail=1
  expect_msg "kind is string, not a number" "...naming the kind field check" \
    --journal "${malformed_kind}" "${base[@]}" || fail=1

  # THE PRECEDENCE. A snapshot whose only send-side events are records the
  # decoder could not classify is NOT an empty snapshot — it is a snapshot full
  # of traffic nobody can vouch for. Routing it to META-FLOOR would reproduce
  # the silent drop one level up: the run would report "the scenario produced
  # nothing" while the journal holds frames that reached a relay.
  local onlymalformed="${tmp}/only-malformed.ndjson"
  fx_begin "${onlymalformed}"
  jline c2r c1 "[\"EVENT\",$(ev_raw 3 0 "\"${PK_A}\"" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev_raw 24242 0 "\"${PK_A}\"" '[["t","upload"]]')]"
  jsentinel c0
  expect_rc 1 "a snapshot of ONLY malformed records is a VIOLATION, not a META-FLOOR" \
    --journal "${onlymalformed}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1
  expect_msg "C3 malformed record" "...and the malformed finding is what is reported" \
    --journal "${onlymalformed}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # A tag ELEMENT that is not an array. The decoder used to `select(type ==
  # "array")` these away, so a tag nobody can read was simply not in the tag
  # set the allow-list is compared against.
  local malformed_tagelem="${tmp}/malformed-tagelem.ndjson"
  fx_begin "${malformed_tagelem}"
  jline c2r c1 "[\"EVENT\",$(ev_raw 445 "\"eBADTAG\"" "\"${PK_EPH1}\"" '[["h","cafebabe"],["expiration","1785886372"],"p:bbbb"]')]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${malformed_tagelem}"
  expect_rc 1 "a tag element that is not an array is a finding, not a drop" \
    --journal "${malformed_tagelem}" "${base[@]}" || fail=1
  # Named, because without the type check the string element reaches `.[0]`
  # and the outer try/catch reports a generic "could not classify" instead —
  # the same exit code by a different route, which is exactly the substitution
  # an exit-code-only fixture cannot see.
  expect_msg "tag element(s) are not a non-empty array with a string name" \
    "...naming the tag-element rule, not the generic catch" \
    --journal "${malformed_tagelem}" "${base[@]}" || fail=1

  # THE CONTROL for all four: byte-identical but well-formed, so the verdict
  # cannot be an artefact of the fixture's position or of the surrounding
  # healthy journal. Pre-fix this reported 1 while the malformed twin reported
  # 0 — the whole finding in one pair.
  local wellformed_twin="${tmp}/wellformed-twin.ndjson"
  fx_begin "${wellformed_twin}"
  jline c2r c1 "[\"EVENT\",$(ev 3 "eBAD" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  jq -c '.wire_seq = .wire_seq + 1' "${wellformed_twin}" >/dev/null
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${wellformed_twin}"
  expect_rc 1 "the well-formed twin of the malformed fixture also reds" \
    --journal "${wellformed_twin}" "${base[@]}" || fail=1

  # Only ONE event object per EVENT frame used to be read, so
  # `["EVENT",<445>,<3>]` reduced to its 445 and the kind-3 was clean.
  local twoevents="${tmp}/twoevents.ndjson"
  fx_begin "${twoevents}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eOK" "${PK_EPH1}" '[["h","cafebabe"],["expiration","1785886372"]]'),$(ev 3 "eHIDE" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${twoevents}"
  expect_rc 1 "a second event object in one EVENT frame is not hidden by the first" \
    --journal "${twoevents}" "${base[@]}" || fail=1
  expect_msg "kind 3 was SENT to a relay" "...and the hidden kind is the one reported" \
    --journal "${twoevents}" "${base[@]}" || fail=1

  # ...and the multiplicity itself is a finding even when BOTH objects are
  # allowed kinds, because a NIP-01 EVENT frame carries exactly one and a frame
  # that does not is not something Haven is known to construct. Without this
  # the rule is only ever reached alongside a kind violation that would red on
  # its own.
  local twoallowed="${tmp}/twoallowed.ndjson"
  fx_begin "${twoallowed}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eOK1" "${PK_EPH1}" '[["h","cafebabe"],["expiration","1785886372"]]'),$(ev 445 "eOK2" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${twoallowed}"
  expect_rc 1 "two ALLOWED event objects in one EVENT frame is still a finding" \
    --journal "${twoallowed}" "${base[@]}" || fail=1
  expect_msg "carries 2 event objects" "...naming the multiplicity rule alone" \
    --journal "${twoallowed}" "${base[@]}" || fail=1

  # -------------------------------------------------------------------------
  # SEND-SIDE (F4). Both fixtures are the probes that found the bug. Without
  # the `dir == "c2r"` restriction on the kind and tag sets, BOTH report clean.
  # -------------------------------------------------------------------------
  # A: Haven publishes 30443 and a REQ. The 445 and the 1059 arrive ONLY from
  # the relay. Every required kind is "observed" and the run was clean, which
  # is precisely the publish path the required-set check exists to prove is
  # alive.
  local inboundonly="${tmp}/inbound-only.ndjson"
  fx_begin "${inboundonly}"
  jconn c1
  jconn c2
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c2 "[\"EVENT\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline c2r c1 '["REQ","sub-kp",{"kinds":[30443],"limit":50}]'
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eIN1" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jline r2c c1 "[\"EVENT\",\"sub-w\",$(ev 1059 "eIN2" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jsentinel c0
  expect_rc 1 "inbound 445/1059 do NOT satisfy the required kind set" \
    --journal "${inboundonly}" "${base[@]}" || fail=1
  expect_msg "kind 445 is required by the allow-list and was never SENT" \
    "...naming the required-kind rule, send-side" \
    --journal "${inboundonly}" "${base[@]}" || fail=1
  expect_msg "advisory (NOT asserted)" \
    "...while the inbound half is still REPORTED, not discarded" \
    --journal "${inboundonly}" "${base[@]}" || fail=1

  # B: THE DAMNING ONE. Every 445 Haven sends has lost its NIP-40 expiration;
  # one inbound 445 still carries it. The allow-list calls this union-level
  # `expiration` requirement the sharpest check in the file, and an event a
  # PEER stamped was answering for it.
  local ttldropped="${tmp}/ttl-dropped.ndjson"
  fx_begin "${ttldropped}"
  jconn c1
  jconn c2
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c2 "[\"EVENT\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline c2r c1 '["REQ","sub-kp",{"kinds":[30443],"limit":50}]'
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" '[["h","cafebabe"]]')]"
  jline c2r c2 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" '[["h","cafebabe"]]')]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eIN" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jsentinel c0
  expect_rc 1 "an inbound 445 does NOT vouch for the TTL Haven stopped stamping" \
    --journal "${ttldropped}" "${base[@]}" || fail=1
  expect_msg "required tag \"expiration\"" "...naming the TTL rule" \
    --journal "${ttldropped}" "${base[@]}" || fail=1

  # C: the same argument at the FRAME-VERB layer. `frame_verbs.required` says a
  # healthy run subscribes; an inbound frame labelled REQ must not answer for
  # it, or "Haven's receive path is alive" becomes "somebody's receive path is
  # alive". Built from the no-REQ journal by adding an r2c REQ.
  # Built explicitly rather than by appending to the no-REQ journal: an append
  # lands ABOVE the sentinel, where it is outside the snapshot and the fixture
  # silently degenerates into a copy of the no-REQ case.
  local inboundreq="${tmp}/inbound-req.ndjson"
  fx_begin "${inboundreq}"
  jconn c1
  jconn c2
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c2 "[\"EVENT\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  # The ONLY REQ in the snapshot, and it is the relay's, not Haven's.
  jline r2c c1 '["REQ","sub-relay-side",{"kinds":[30443],"limit":50}]'
  jsentinel c0
  expect_rc 1 "an INBOUND REQ does not satisfy the required frame-verb set" \
    --journal "${inboundreq}" "${base[@]}" || fail=1
  expect_msg "frame verb \"REQ\" was never sent" \
    "...and the required-verb rule is the one that fires" \
    --journal "${inboundreq}" "${base[@]}" || fail=1

  # D: a snapshot whose send side is EMPTY while inbound traffic is plentiful.
  # "The snapshot contains events" must mean "Haven sent events" — otherwise a
  # client that never armed, on a relay that was chatty, reads as a sample.
  local inboundnosend="${tmp}/inbound-no-send.ndjson"
  fx_begin "${inboundnosend}"
  jconn c1
  jline c2r c1 '["REQ","sub-kp",{"kinds":[30443],"limit":50}]'
  jline r2c c1 "[\"EVENT\",\"sub-kp\",$(ev 30443 "eIN1" "${PK_B}" "${KP_TAGS}")]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eIN2" "${PK_EPH2}" '[["h","cafebabe"],["expiration","1785886372"]]')]"
  jline r2c c1 "[\"EVENT\",\"sub-w\",$(ev 1059 "eIN3" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jsentinel c0
  expect_rc 4 "a snapshot with only INBOUND events is a META-FLOOR, not a sample" \
    --journal "${inboundnosend}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1
  expect_msg "inbound frame(s) were recorded, but an event a relay sent to Haven is not evidence" \
    "...and the message says why the inbound frames do not count" \
    --journal "${inboundnosend}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # The converse control, so the restriction is not simply "ignore r2c and red
  # on everything": the healthy journal contains inbound 445 and 30443 frames
  # and still passes.
  expect_msg "advisory (NOT asserted): 2 relay->client EVENT frame(s)" \
    "the healthy journal's inbound traffic is reported and does not red" \
    --journal "${healthy}" "${base[@]}" || fail=1

  # -------------------------------------------------------------------------
  # REQ FILTERS (F7). REQ frames used to be reduced to their verb while the
  # summary printed `verbs [... REQ ...]`, which reads as if the frame had been
  # examined.
  # -------------------------------------------------------------------------
  local badfilter="${tmp}/badfilter.ndjson"
  fx_begin "${badfilter}"
  jline c2r c1 "[\"REQ\",\"sub-x\",{\"kinds\":[445],\"#h\":[\"cafebabe\"],\"search\":\"alice home\",\"#g\":[\"u4pruy\"]}]"
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${badfilter}"
  expect_rc 1 "a REQ filter key outside the allow-list is a finding" \
    --journal "${badfilter}" "${base[@]}" || fail=1
  expect_msg "filter key \"search\"" "...naming NIP-50 search" \
    --journal "${badfilter}" "${base[@]}" || fail=1
  expect_msg "filter key \"#g\"" "...and the geohash filter" \
    --journal "${badfilter}" "${base[@]}" || fail=1

  # The two REQ-shape rules get one fixture each: a REQ carrying a valid filter
  # BESIDE an unreadable element fires only the non-object rule, and a REQ with
  # no filter at all fires only the zero-filter rule. A single fixture with a
  # lone junk element fires both, and then no-opping either leaves the suite
  # green on the other.
  local badreqshape="${tmp}/badreqshape.ndjson"
  fx_begin "${badreqshape}"
  jline c2r c1 '["REQ","sub-x",{"kinds":[445],"#h":["cafebabe"]},"not-a-filter"]'
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${badreqshape}"
  expect_rc 1 "a REQ filter element that is not an object is a finding" \
    --journal "${badreqshape}" "${base[@]}" || fail=1
  expect_msg "filter element(s) that are not JSON objects" \
    "...naming the unreadable-element rule" \
    --journal "${badreqshape}" "${base[@]}" || fail=1
  expect_no_msg "carried NO filter" "...and not the zero-filter rule" \
    --journal "${badreqshape}" "${base[@]}" || fail=1

  local emptyreq="${tmp}/emptyreq.ndjson"
  fx_begin "${emptyreq}"
  jline c2r c1 '["REQ","sub-x"]'
  jq -c '.wire_seq = .wire_seq + 1' "${healthy}" >> "${emptyreq}"
  expect_rc 1 "a REQ carrying no filter at all is a finding" \
    --journal "${emptyreq}" "${base[@]}" || fail=1
  expect_msg "carried NO filter" "...naming the zero-filter rule" \
    --journal "${emptyreq}" "${base[@]}" || fail=1

  # -------------------------------------------------------------------------
  # THE SENTINEL BOUNDARY (F9). The token is matched as a FRAME, never as a
  # substring: any line merely containing it used to move the boundary up, and
  # a relay NOTICE echoing an unknown frame is such a line. Here a kind-3 sits
  # ABOVE the real marker with the echo above it — under substring matching the
  # boundary jumped past the kind-3 and the run red on traffic the drive never
  # bounded.
  # -------------------------------------------------------------------------
  local echoedtoken="${tmp}/echoed-token.ndjson"
  write_healthy "${echoedtoken}"
  jline c2r c9 "[\"EVENT\",$(ev 3 "eLATE" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  jline r2c c1 "[\"NOTICE\",\"unknown frame: ${SENTINEL}\"]"
  expect_rc 0 "a NOTICE echoing the token does not move the boundary" \
    --journal "${echoedtoken}" "${base[@]}" || fail=1
  expect_msg "anchored at wire_seq 22" "...the boundary is the marker FRAME, not the echo" \
    --journal "${echoedtoken}" "${base[@]}" || fail=1

  # The token present but never as a marker frame: a distinct META-FLOOR with a
  # distinct cause, and it must not silently become "no sentinel at all".
  local tokenincontent="${tmp}/token-in-content.ndjson"
  fx_begin "${tokenincontent}"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline r2c c1 "[\"NOTICE\",\"unknown frame: ${SENTINEL}\"]"
  expect_rc 4 "the token in content only is unanchored, not anchored" \
    --journal "${tokenincontent}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1
  expect_msg "no sentinel FRAME" "...and the two causes are told apart" \
    --journal "${tokenincontent}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # A well-formed marker frame recorded as `r2c` must NOT anchor. The proxy
  # intercepts the marker and never forwards it, so no relay can learn the
  # token and no relay can have sent one; a marker attributed to the relay is
  # the recorder describing something that did not happen, and letting it set
  # the boundary would hand an upstream party control of the snapshot.
  local r2csentinel="${tmp}/r2c-sentinel.ndjson"
  fx_begin "${r2csentinel}"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline r2c c1 "[\"HAVEN_WIRE_SENTINEL\",\"${SENTINEL}\"]"
  jline c2r c2 "[\"EVENT\",$(ev 3 "eLATE" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  expect_rc 4 "a marker recorded r2c does not anchor the read" \
    --journal "${r2csentinel}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1
  expect_msg "no sentinel FRAME" "...and it is reported as a token that is not a marker" \
    --journal "${r2csentinel}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 2 || fail=1

  # -------------------------------------------------------------------------
  # --exclude-conn (F3). It must actually narrow the attribution, and it must
  # not be able to hide the classes that are evaluated over every connection.
  # -------------------------------------------------------------------------
  # Excluding the connection PK_B published on turns a clean run into a
  # META-FLOOR: without that, the flag would be decorative.
  expect_rc 4 "--exclude-conn removes that connection from the floors" \
    --journal "${healthy}" "${base[@]}" --exclude-conn c2 || fail=1
  expect_msg "dropped from the EVENT-level attribution" \
    "...and the run PRINTS what it dropped" \
    --journal "${healthy}" "${base[@]}" --exclude-conn c2 || fail=1

  # ...and it cannot hide a null frame, which is evaluated over every
  # connection precisely because a partial exclusion must not be able to.
  local exclnull="${tmp}/exclnull.ndjson"
  jq -c 'if (.wire_seq == 21) then (.conn_id = "c5" | .frame = null | .raw_preview = "<binary>") else . end' \
    "${healthy}" > "${exclnull}"
  expect_rc 1 "--exclude-conn cannot hide an unrecognised frame" \
    --journal "${exclnull}" "${base[@]}" --exclude-conn c5 || fail=1

  # SELF-DECLARATION: a socket that emitted the intercepted marker needs no
  # flag. The lane can only name the ONE conn_id it greps out of the drive log,
  # while a scenario opens a TestRelay per group and mints a fresh conn_id on
  # every reconnect — so without this the harness's own traffic discharges the
  # participant floors and "the app transmitted" is not what green means.
  # The forbidden kind-3 makes the fixture unambiguous: attributed to Haven it
  # is a violation, so a clean verdict can only mean the socket was excluded.
  local declared="${tmp}/declared-harness.ndjson"
  write_healthy "${declared}"
  jconn c6
  jdeclare c6
  jline c2r c6 "[\"EVENT\",$(ev 3 "eHARNESS" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  jsentinel c0
  expect_rc 0 "a self-declared harness socket is excluded with no --exclude-conn" \
    --journal "${declared}" "${base[@]}" || fail=1
  expect_msg "2 self-declared harness socket(s)" \
    "...and the run names how many sockets declared themselves" \
    --journal "${declared}" "${base[@]}" || fail=1
  # ...and the declaration cannot hide the classes evaluated over EVERY
  # connection either: a null frame on a declared socket is still a finding.
  local declarednull="${tmp}/declared-harness-null.ndjson"
  write_healthy "${declarednull}"
  jconn c6
  jdeclare c6
  jline c2r c6 '["EVENT",{"kind":445}]'
  jq -c 'if (.frame == ["EVENT",{"kind":445}]) then (.frame = null | .raw_preview = "<binary>") else . end' \
    "${declarednull}" > "${declarednull}.tmp"
  mv "${declarednull}.tmp" "${declarednull}"
  FIXTURE_FILE="${declarednull}"
  jsentinel c0
  expect_rc 1 "a self-declared socket cannot hide an unrecognised frame either" \
    --journal "${declarednull}" "${base[@]}" || fail=1

  # ...and a declaration must not be able to MOVE the boundary. It shares the
  # intercepted verb with the snapshot marker but not the token, and
  # `sentinel_seq` matches `frame[1]` exactly — so a declaration emitted AFTER
  # the marker (a reconnect mid-teardown) must leave the anchor where it was,
  # and the violation above it must stay outside the snapshot. Without this the
  # attribution channel would silently become a second boundary source.
  local declaredlate="${tmp}/declared-after-sentinel.ndjson"
  write_healthy "${declaredlate}"
  jconn c6
  jdeclare c6
  jline c2r c6 "[\"EVENT\",$(ev 3 "eLATEHARNESS" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  expect_rc 0 "a declaration after the sentinel does not extend the snapshot" \
    --journal "${declaredlate}" "${base[@]}" || fail=1
  expect_msg "anchored at wire_seq 22" \
    "...the boundary is still the marker's, not the declaration's" \
    --journal "${declaredlate}" "${base[@]}" || fail=1

  # -------------------------------------------------------------------------
  # The SENTINEL actually truncates. This is the fixture that proves the
  # snapshot does something: a violation appended ABOVE the boundary — exactly
  # what a background wake would produce mid-read — must not be seen, while the
  # identical violation BELOW it must be caught. Without both halves the
  # sentinel could be inert and every other fixture would still pass.
  # -------------------------------------------------------------------------
  local afterSentinel="${tmp}/after-sentinel.ndjson"
  write_healthy "${afterSentinel}"
  jline c2r c9 "[\"EVENT\",$(ev 3 "eLATE" "${PK_A}" "[[\"p\",\"${PK_B}\"]]")]"
  expect_rc 0 "a violation ABOVE the sentinel is outside the snapshot" \
    --journal "${afterSentinel}" "${base[@]}" || fail=1
  # ...and the same event below the sentinel is caught (the badkind fixture
  # above), so the boundary is doing the work and not merely existing.

  # -------------------------------------------------------------------------
  # Allowed-but-not-required kinds must not be required. Drop kind 0 (the E2E
  # harness pre-seeds identity and skips onboarding, so no kind-0 is published)
  # and the run must still pass.
  # -------------------------------------------------------------------------
  local nokind0="${tmp}/nokind0.ndjson"
  jq -c 'select((.frame | tostring | test("\"kind\":0,")) | not)' "${healthy}" \
    > "${tmp}/nokind0.raw"
  renumber "${tmp}/nokind0.raw" "${nokind0}"
  expect_rc 0 "an allowed-but-not-required kind may be absent" \
    --journal "${nokind0}" "${base[@]}" || fail=1

  # An OPTIONAL tag may be absent. Kind 10002 allows `r` but does not require
  # it, because the NIP-65 unpublish tombstone is a zero-tag replaceable event.
  # Stripping it must PASS — this is the fixture that exact set equality
  # (`observed == allowed`) would false-red on, and it is the whole reason C4
  # is two one-directional checks instead of one equality.
  local nooptional="${tmp}/nooptional.ndjson"
  jq -c 'if (.frame | tostring | test("\"kind\":10002")) then
           .frame = (.frame | map(if (type == "object" and .kind == 10002)
                                  then .tags = []
                                  else . end))
         else . end' "${healthy}" > "${nooptional}"
  expect_rc 0 "an optional tag may be absent (set equality would false-red)" \
    --journal "${nooptional}" "${base[@]}" || fail=1

  # The same argument one level down, WITHIN a kind: the healthy journal's
  # kind-445 set contains a commit carrying `h` alone beside an application
  # message carrying `h`+`expiration`. A per-EVENT required-set would red on
  # the commit; the union-level check does not. Proven by construction in
  # `write_healthy`, and pinned here so a later edit cannot quietly drop the
  # commit-shaped event and leave the distinction untested.
  if ! grep -aq '\[\["h","cafebabe"\]\]' "${healthy}"; then
    echo "SELF-TEST FAIL: the healthy fixture no longer contains a kind-445 carrying" >&2
    echo "  \`h\` alone, so it no longer proves that a per-event required-set would" >&2
    echo "  false-red while the union-level one does not." >&2
    fail=1
  fi

  # -------------------------------------------------------------------------
  # USAGE (rc 2) — including the guard on the guard.
  # -------------------------------------------------------------------------
  expect_rc 2 "no arguments" || fail=1
  expect_rc 2 "no --journal" --sentinel "${SENTINEL}" --min-distinct-conns 2 || fail=1
  expect_rc 2 "no --sentinel (an unanchored read is refused)" \
    --journal "${healthy}" --min-distinct-conns 2 || fail=1
  expect_rc 2 "no participant floor (a vacuous C2 is refused)" \
    --journal "${healthy}" --sentinel "${SENTINEL}" || fail=1
  expect_rc 2 "a too-short sentinel token is refused" \
    --journal "${healthy}" --sentinel "abc" --min-distinct-conns 2 || fail=1

  # THE BYPASSABLE FLOOR. `-1` satisfied the mandatory-floor gate AND disabled
  # the check it was passed to enable, so it reported CLEAN on the exact
  # one-participant journal two cases above assert must be a META-FLOOR. `1` is
  # legal arithmetic that asserts nothing, and it had been filler in five
  # cases. A non-integer reached an arithmetic test under `set -u` and exited
  # 1 — an operator typo reading as a wire-privacy VIOLATION.
  expect_rc 2 "--min-distinct-conns -1 is refused, not silently disabling" \
    --journal "${onlyA}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns -1 || fail=1
  expect_rc 2 "--min-distinct-conns 1 is refused (implied by the meta-floor)" \
    --journal "${healthy}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 1 || fail=1
  expect_rc 2 "--min-distinct-conns 0 is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-conns 0 || fail=1
  expect_rc 2 "--min-distinct-publishers abc is a USAGE error, not a VIOLATION" \
    --journal "${healthy}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --min-distinct-publishers abc || fail=1
  expect_rc 2 "--participant that is not 64 hex is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" --allowlist "${allow}" \
    --participant "deadbeef" || fail=1

  # -------------------------------------------------------------------------
  # THE ALLOW-LIST IS DATA, AND DATA IS LINTED (F10). Nothing checked it: a
  # `kinds` that was an ARRAY passed the old two-key shape probe (`[]` is
  # truthy in jq) and aborted inside `evaluate` with an undocumented rc 5.
  # -------------------------------------------------------------------------
  expect_rc 3 "an absent allow-list is UNUSABLE, never a pass" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${tmp}/no-such.json" \
    --min-distinct-conns 2 || fail=1

  local al_array="${tmp}/al-kinds-array.json"
  jq -c '.kinds = [445]' "${allow}" > "${al_array}"
  expect_rc 3 "an allow-list whose \`kinds\` is an ARRAY is UNUSABLE, not rc 5" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_array}" \
    --min-distinct-conns 2 || fail=1
  # Named: without the type check the linter still reds, but by CRASHING on
  # `test` applied to an array index — the same exit code from an accident
  # rather than from a rule, which is the failure mode this fixture exists to
  # tell apart.
  expect_msg "\`kinds\` is array, not an object" \
    "...naming the shape rule, not a jq crash that happens to red" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_array}" \
    --min-distinct-conns 2 || fail=1

  # THE DISJOINTNESS INVARIANT. A kind in both `kinds` and
  # `_forbidden_by_omission` is permitted and forbidden at once, and which one
  # wins is an implementation detail of `evaluate` rather than a decision
  # anyone made. Disjoint today by care; now by construction.
  local al_both="${tmp}/al-both.json"
  jq -c '._forbidden_by_omission["445"] = "contradicts the kinds entry"' "${allow}" > "${al_both}"
  expect_rc 3 "a kind in BOTH kinds and _forbidden_by_omission is UNUSABLE" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_both}" \
    --min-distinct-conns 2 || fail=1
  expect_msg "permitted and forbidden at the same time" \
    "...and the linter names the contradiction" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_both}" \
    --min-distinct-conns 2 || fail=1

  # A `_forbidden_by_omission` key that is not a kind number. The disjointness
  # rule above compares that key set against `kinds`, so a key that is not a
  # kind number is silently outside the comparison — it documents a prohibition
  # that nothing enforces.
  local al_badforbidkey="${tmp}/al-badforbidkey.json"
  jq -c '._forbidden_by_omission["contact-list"] = "a note, not a kind"' "${allow}" > "${al_badforbidkey}"
  expect_rc 3 "a non-numeric _forbidden_by_omission key is UNUSABLE" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_badforbidkey}" \
    --min-distinct-conns 2 || fail=1
  expect_msg "is not a kind number" "...naming the key-shape rule" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_badforbidkey}" \
    --min-distinct-conns 2 || fail=1

  # A required tag the same kind does not allow: a rule that can never pass.
  local al_unsat="${tmp}/al-unsat.json"
  jq -c '.kinds["445"].tags.required += ["nosuchtag"]' "${allow}" > "${al_unsat}"
  expect_rc 3 "an allow-list requiring a tag it does not allow is UNUSABLE" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_unsat}" \
    --min-distinct-conns 2 || fail=1

  # An empty REQ filter-key set would make every REQ a violation.
  local al_nofilters="${tmp}/al-nofilters.json"
  jq -c 'del(.req_filters)' "${allow}" > "${al_nofilters}"
  expect_rc 3 "an allow-list with no req_filters section is UNUSABLE" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_nofilters}" \
    --min-distinct-conns 2 || fail=1
  expect_msg "the REQ filter-key check has no closed set to compare against" \
    "...naming the missing section, not a downstream symptom" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_nofilters}" \
    --min-distinct-conns 2 || fail=1
  # An EMPTY key list is a different fault from a missing section: it lints as
  # "every REQ is a violation", which would red the whole lane for a reason
  # that is not a privacy finding.
  local al_emptyfilters="${tmp}/al-emptyfilters.json"
  jq -c '.req_filters.allowed_keys = []' "${allow}" > "${al_emptyfilters}"
  expect_rc 3 "an allow-list with an EMPTY req_filters.allowed_keys is UNUSABLE" \
    --journal "${healthy}" "${base[@]:0:2}" --allowlist "${al_emptyfilters}" \
    --min-distinct-conns 2 || fail=1

  # -------------------------------------------------------------------------
  # A floor on the fixture COUNT, not just on their verdicts. Every assertion
  # in this file is a set operation that passes over an empty input, and the
  # self-test is no exception: deleting cases would leave it green while the
  # thing it certifies stopped being certified. If a case is genuinely retired,
  # lower this number in the same commit and say why.
  #
  # THE FLOOR IS EXACT, and the environment-conditional case is ACCOUNTED FOR
  # rather than absorbed by slack.
  #
  # The previous floor was a bare `CASES_RUN < 32` against exactly 32 calls,
  # one of which cannot run as uid 0: mode 000 does not stop root, so a root
  # runner skipped the unreadable-journal fixture and the suite then accused
  # itself of having had cases deleted. repo-guards.yml runs this, and a guard
  # that fails with a false accusation on a legitimate environment is a guard
  # people learn to ignore.
  #
  # The obvious fix — lower the floor and call the gap "headroom" — buys root
  # safety with a case that can be deleted in silence, which is the exact
  # property the floor exists to deny. So the skip is COUNTED instead: the sum
  # of run and skipped cases is invariant across environments, the floor equals
  # it exactly, and deleting any case still trips it. If a case is genuinely
  # retired, lower this number in the same commit and say why.
  # -------------------------------------------------------------------------
  readonly MIN_CASES=121
  if (( CASES_RUN + CASES_SKIPPED < MIN_CASES )); then
    echo "SELF-TEST FAIL: only $(( CASES_RUN + CASES_SKIPPED )) fixture(s) accounted for" >&2
    echo "  (${CASES_RUN} run + ${CASES_SKIPPED} skipped); at least ${MIN_CASES} expected." >&2
    echo "  Cases have been removed without lowering MIN_CASES — the self-test is" >&2
    echo "  now certifying less than it claims." >&2
    fail=1
  fi

  if (( fail )); then
    echo "check-wire-journal: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "check-wire-journal: self-test passed (${CASES_RUN} fixtures — healthy journal" \
       "clears; absent/empty/truncated/gapped/head-truncated journals, a lifecycle record" \
       "carrying traffic fields, and an allow-list that does not lint all fail as UNUSABLE;" \
       "unanchored, empty-snapshot, one-sided and ephemeral-key-inflated runs fail as" \
       "META-FLOOR; unexpected kinds (including kinds forbidden by omission), unexpected" \
       "tags, missing required kinds/tags, unknown REQ filter keys and MALFORMED records" \
       "fail as VIOLATIONs; inbound traffic never answers for a send-side assertion;" \
       "duplicate event ids, optional absences, an echoed sentinel token and traffic above" \
       "the sentinel do not)."
  return 0
}

main "$@"
