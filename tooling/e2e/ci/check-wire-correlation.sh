#!/usr/bin/env bash
#
# Correlation-and-containment (VALUE-layer) privacy oracle over the E2E wire
# journal.
#
# Backlog Workstream C, item C5. Consumes the NDJSON journal written by the
# recording WebSocket proxy (C1, `tooling/e2e/local-relay`).
#
# `check-wire-journal.sh` (C2/C3/C4) is the STRUCTURAL layer: which kinds and
# which tag NAMES may appear, asserted over the union of a kind's events. This
# file is the layer underneath it — the one that reads VALUES and the
# relationships between events:
#
#   C5.1  no ONE publisher sends two kind-445s with different `h` in one second
#   C5.2  REQ-filter allow-list (the multiplexed `#h` shape, and nothing wider)
#   C5.3  per-EVENT kind-445 tag shape ∈ { {h}, {h,expiration} }
#   C5.4  no `g` and no `alt` tag on any kind
#   C5.5  kind-1059 tag set is exactly {p}, exactly once
#   C5.6  publish-target containment, scoped PER KIND
#   C5.7  every kind-445 carries a FRESH EPHEMERAL author (Security Rule 2)
#   C5.8  the real MLS group id NEVER appears on the wire (Security Rule 4)
#   C5.9  a kind-445 carries no `p` (recipient) tag
#
# Almost every one of these is invisible to C4, and that is why it is a
# separate file rather than more entries in `wire_allowlist.json`. C4 asserts
# over the UNION of a kind's tag names, so it cannot see a second `h` on one
# event (C5.3), it never looks at a tag's value (C5.1, C5.4, C5.7, C5.8 pass
# its allow-list today), it never looks at REQ frames at all (C5.2), it has no
# concept of an endpoint (C5.6), and it has no concept of caller-supplied
# ground truth (C5.7's identity keys, C5.8's group id).
#
# C5.9 is the one exception, and it is stated rather than hidden: a `p` tag on
# a kind-445 is ALREADY rejected by C4's union allow-list and by C5.3's
# per-event tag shape, so C5.9 can never be the only thing that catches it.
# What it adds is the diagnosis — C5.3 reports "a third tag NAME", which does
# not tell a reader that circle membership just became queryable at the relay.
# The self-test therefore asserts C5.9's MESSAGE and not merely a red exit
# code, because the exit code alone cannot distinguish the two rules.
#
# # C5.1, C5.7 and C5.8 are SEND-SIDE, and say so
#
# C5.2-C5.6 read both directions, because the questions they ask have the same
# answer whoever put the frame on the socket. C5.1, C5.7, C5.8 and C5.9 do not:
# each asks what ONE DEVICE did, and an inbound frame is the RELAY's output —
# free to echo Haven's own event back, to carry another client's 445, or to be
# hostile. Asserting any of them over inbound traffic would manufacture
# findings, so they are scoped to `dir == "c2r"` and what is known about
# inbound is printed as `advisory (NOT asserted)`.
#
# # Attribution: a connection is the publisher, and harness sockets are nobody
#
# C5.1 goes one step further than direction, because it is the one invariant
# whose subject is a RELATIONSHIP between two events rather than a property of
# one. It partitions the sent traffic by CONNECTION and asks its question
# inside each partition.
#
# The journal is not single-tenant. One E2E process runs the app under test
# plus a dozen in-process `SyntheticUser` peers, each with its own relay
# client, and the harness's own `TestRelay` sockets on top — and on a
# `TestRelay` several simulated peers publish through ONE socket
# (`SyntheticUser.publishLocation` → `TestRelay.publishAndAwaitOk`). Asserted
# over the union, "two circles shared a second" says nothing about Haven: it
# reports two peers publishing 35 ms apart as a co-membership leak by the app,
# and reports it on essentially every run, because fifteen devices in a
# twenty-minute window collide by birthday. That was not a hypothetical — it
# is what this oracle did on its first three live-sync runs.
#
# So: harness sockets are excluded (they self-declare — see the exclusion note
# in `evaluate`), inbound is dropped, and what remains is partitioned per
# connection. A device that co-times two circles is still caught, on the one
# socket its relay client publishes over; two devices coinciding no longer
# manufactures a finding, because there is no shared device to infer.
#
# # Every invariant carries its own non-empty precondition, and fails closed
#
# Each assertion below passes trivially over an input that contains none of the
# events it reasons about, so each has a PRECONDITION that must be met before
# its clean verdict means anything, and an unmet precondition is a META-FLOOR
# failure (exit 4) rather than a pass.
#
# This is not hypothetical caution. The oracle this replaces
# (`_assertWirePrivacyInvariants`, `haven/integration_test/e2e/
# e2e_combined.dart:4258-4262`) asserts `isNotEmpty` over a kind-445 relay
# query. Application messages carry a 228-second NIP-40 expiration and commits
# carry none, so on a slow run the relay has already evicted every application
# message while the commits remain — and the check silently shrinks to the
# commit subset with `isNotEmpty` still satisfied. A degraded sample reported
# as a clean one.
#
# C5.1's precondition is where that trap bites hardest, so it is stated
# explicitly: it is NOT "≥2 distinct `h`", and it is not journal-wide either.
# Commits and proposals carry no inner timestamp and keep the wrap-time default
# (`transport-nostr-peeler/src/peeler.rs:166`), so two commits satisfy "≥2
# distinct `h`" while proving nothing whatever about the timestamp binding the
# invariant exists to police. And a collision is a statement about ONE device,
# so two circles served by two different devices cannot exhibit it however many
# messages they send. The precondition is therefore "ONE CONNECTION published
# an APPLICATION message (a 445 carrying `expiration`) for each of two distinct
# `h`" — i.e. the run actually put a device in the situation the decorrelation
# work exists for.
#
# That floor also fails closed on the way the attribution could rot: if the
# app's publishes ever split across connections, no single connection covers
# two groups and this META-FLOORs instead of quietly checking half the burst.
#
# # Why C5.1 asserts over commits too, even though only application messages
# # carry the binding
#
# The PRECONDITION excludes commits; the ASSERTION does not. Two 445s from one
# device in the same second with different `h` are linkable by an observer
# whichever kind of message they are — kind-445 events are signed by a fresh
# ephemeral key per message (Security Rule 2), so `created_at` is the ONLY
# thing on the outer event that can bind two of them, and it binds them
# regardless of what is inside. Note what this means for a finding: an
# observer cannot tell a commit from an application message here either, so a
# location publish that lands in the same second as a protocol commit for
# another circle is a real disclosure, not a technicality.
#
# # Why C5.2 permits the multiplexed `#h` REQ
#
# `haven-core/src/relay/live_sync/planes/group.rs:26-35` puts every circle's
# `hex(nostr_group_id)` into ONE `#h` filter, scoped per identical canonical
# relay set. That is a deliberate design decision, not a defect: the receiving
# relay is already in all those circles' routing sets, so it could infer the
# partition from the traffic anyway. But the REQ hands it over EXPLICITLY, so
# it is exactly the shape that must be pinned as ACCEPTED and must not widen.
# What this file forbids is anything broader: an author or recipient list in
# the same filter (which attaches NAMES to a partition no relay could name), a
# filter merging circles with different relay routing, or any filter key nobody
# has reasoned about.
#
# # Scope, stated honestly
#
# A send-side instrument. It says nothing about a hostile relay withholding,
# reordering or forging inbound events (eclipse, welcome suppression,
# stale-KeyPackage serving). C5.6's pools are CALLER-SUPPLIED ground truth: it
# proves containment against what the lane says it configured, not against what
# the app believes it configured.
#
# Usage:
#   bash tooling/e2e/ci/check-wire-correlation.sh \
#        --journal <path> [--journal <path>...] \
#        --sentinel <token> \
#        --pool <kind>=<url>[,<url>...] [--pool ...] \
#        [--discovery-relay <url>]... [--exclude-conn <conn_id>]... \
#        [--identity-pubkey <hex64>]... [--mls-group-id <hex>]... \
#        [--expect-mls-group-ids <n>]
#   bash tooling/e2e/ci/check-wire-correlation.sh --self-test
#
# The E2E harness (`TestRelay`) reaches the same proxied relays as the app, so
# its probes are in the journal too and are NOT Haven's privacy surface. The
# proxy's sentinel ack returns the emitting `conn_id` for exactly this reason;
# pass it as `--exclude-conn`. Exclusion can only remove evidence, so an
# over-broad one fails closed on the preconditions instead of reporting clean.
#
# Exit codes (same taxonomy as check-wire-journal.sh, deliberately):
#   0 = every named journal was usable, anchored, and every invariant both
#       held AND had its precondition met
#   1 = VIOLATION — a correlation or containment finding
#   2 = usage error
#   3 = UNUSABLE — a named journal was absent, unreadable, empty, contained a
#       line that is not a JSON object, was missing a contract field, or had a
#       duplicated / gapped / non-zero-based `wire_seq`. This run proves
#       nothing either way.
#   4 = META-FLOOR — the journal parsed, but proves too little: no sentinel, an
#       empty snapshot, or an invariant whose precondition was never met, which
#       makes that invariant's silence meaningless.

set -euo pipefail

readonly RC_CLEAN=0
readonly RC_VIOLATION=1
readonly RC_USAGE=2
readonly RC_UNUSABLE=3
readonly RC_METAFLOOR=4

SELF_PATH="${BASH_SOURCE[0]}"
readonly SELF_PATH

usage() {
  cat >&2 <<'EOF'
Usage:
  check-wire-correlation.sh --journal <path> [--journal <path>...] \
                            --sentinel <token> \
                            --pool <kind>=<url>[,<url>...] [--pool ...] \
                            [--discovery-relay <url>]... \
                            [--identity-pubkey <hex64>]... \
                            [--mls-group-id <hex>]... \
                            [--expect-mls-group-ids <n>]
  check-wire-correlation.sh --self-test

--pool declares the publish targets a kind is ALLOWED to reach (C5.6). At least
one is REQUIRED: without any, containment is unprovable and a clean verdict
would mean nothing. A kind that is SENT but has no pool is a META-FLOOR, never
a pass.

--discovery-relay marks an endpoint as read-only (REQ yes, EVENT never). A URL
may not appear both as a discovery relay and inside a pool.

--exclude-conn drops a connection from every assertion. Use it for the E2E
harness's own socket, whose conn_id the proxy returns in the sentinel ack: its
probes are not Haven's traffic. It can only remove evidence, so an over-broad
exclusion fails closed on the preconditions rather than reporting clean.
It is ADDITIVE to what the journal already declares: any connection that
emitted the intercepted sentinel verb is a harness socket by construction and
is excluded whether or not the lane names it.

--identity-pubkey declares a long-term account pubkey (64 hex) that no kind-445
may ever be signed by (C5.7). It is OPTIONAL and additive: the identity set is
also DERIVED from the journal, from the authors of kinds 0/10002/10050/30443,
which are identity-signed by protocol. Declare a key the run never puts on the
wire and C5.7 covers it too; declare none and the derived set still applies. If
BOTH are empty the identity arm is a META-FLOOR, never a pass.

--mls-group-id declares the real MLS group id (hex, >= 32 chars) that must
appear in NO tag of any published event (C5.8). It CANNOT be derived — its
absence from the wire is the very thing asserted — and it cannot live in
wire_allowlist.json, which is static while the id is minted per run. Publishing
kind-445s without declaring one is a META-FLOOR: the scan would have compared
the wire against nothing.

--expect-mls-group-ids is the lane's OWN count of how many ids the drive
announced, held against how many arrived. Nothing in the journal can tell a
needle set that shrank from a run that made fewer circles, so a set narrowed by
a rotated sidecar or a broken declaration leaves C5.8 looking exactly as busy
over fewer values. A mismatch either way is a META-FLOOR. Optional: without it
the completeness of the needle set is simply not checked, and the summary line
says so.
EOF
}

# ---------------------------------------------------------------------------
# Usability gate. Same posture as check-wire-journal.sh: each branch is a
# DIFFERENT operator failure, because "the journal is missing" and "the journal
# is clean" demand opposite responses.
# ---------------------------------------------------------------------------

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
    echo "UNUSABLE: ${f} [unreadable] — exists but permission denied; nothing was checked." >&2
    return "${RC_UNUSABLE}"
  fi
  if [[ ! -s "${f}" ]]; then
    echo "UNUSABLE: ${f} [empty] — 0 bytes; the recorder never wrote a frame." >&2
    return "${RC_UNUSABLE}"
  fi
  return "${RC_CLEAN}"
}

# journal_wellformed <path>
#
# `dir` is required only on TRAFFIC lines. C1's journal also emits `conn_open`
# / `conn_error` lifecycle records (`tooling/e2e/local-relay/src/journal.rs`
# "Record types"), and those carry no `dir` by design — demanding it
# unconditionally would report every real journal UNUSABLE. The contract's own
# discriminator is used: a traffic line is exactly a line that HAS a `frame`
# key (possibly null), which journal.rs guarantees is present on those lines
# and absent everywhere else.
journal_wellformed() {
  local f="$1" bad gaps

  bad="$(
    jq -R '
      (try (fromjson) catch null) as $o
      | if ($o | type) != "object" then "not a JSON object"
        elif ($o.wire_seq | type) != "number" then "missing/invalid wire_seq"
        elif ($o.wire_seq != ($o.wire_seq | floor)) or ($o.wire_seq < 0) then "wire_seq not a non-negative integer"
        elif ($o.conn_id | type) != "string" then "missing/invalid conn_id"
        elif ($o | has("frame")) and ($o.dir != "c2r" and $o.dir != "r2c") then "traffic line with missing/invalid dir"
        elif ($o | has("frame") | not) and (($o.type // "") | test("^conn_(open|error)$") | not) then "neither a traffic line (no frame key) nor a recognised lifecycle record"
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

# sentinel_seq <path> <token> — highest wire_seq of any line containing <token>.
sentinel_seq() {
  local f="$1" token="$2" hits
  hits="$(grep -aF -- "${token}" "${f}" || true)"
  [[ -z "${hits}" ]] && return 0
  printf '%s\n' "${hits}" | jq -s 'map(.wire_seq) | max'
}

# normalize <path> <boundary> — one compact JSON record per EVENT frame, per
# REQ frame, and per connection-lifecycle record at or below <boundary>.
#
# EVENT has two shapes: client->relay is `["EVENT", <event>]`, relay->client is
# `["EVENT", <subid>, <event>]` (NIP-01). Picking the first array member that
# is an object carrying a `kind` covers both without branching on direction.
# REQ is `["REQ", <subid>, <filter>...]` — note filters start at index 2, and a
# REQ may legitimately carry several.
#
# Unlike the structural oracle, tag VALUES are retained: C5.1 needs the `h`
# value to tell two groups apart, and C5.4 reports which kind carried a
# forbidden name. Nothing here is ever printed — see the header of the report
# section.
#
# EVERY token of a tag is kept, not the first two. The first two are still
# materialised by name (`(.[0] // "") | tostring`, likewise `.[1]`) so that a
# one-element tag keeps yielding `["h",""]` rather than `["h"]` — `tagVals`
# reads `.[1]` and the `select(. != "")` filters downstream of it would change
# meaning if that became `null`. Everything from index 2 on is then appended
# verbatim. C5.8 scans tag tokens for a leaked MLS group id and a truncation
# at index 1 would make any tag position beyond the first value a blind spot;
# it also feeds `bodyKey`, so two events differing only in a third token stay
# two events instead of collapsing into one that answers for both.
normalize() {
  local f="$1" boundary="$2"
  jq -c --argjson b "${boundary}" '
    select(.wire_seq <= $b)
    | . as $line
    | (($line.relay_url // "") | ascii_downcase) as $up
    | (($line.listen // "")    | ascii_downcase) as $lst
    | if ($line | has("frame") | not) then
        {t:"open", conn:$line.conn_id, up:$up, listen:$lst}
      elif ($line.frame == null) then
        # An unrecognised frame is C3s finding, reported there. C5 reasons about
        # decoded values and has nothing to say about bytes it cannot decode.
        empty
      elif (($line.frame | type) == "array") then
        ($line.frame[0]) as $verb
        | if ($verb | type) != "string" then empty
          elif $verb == "EVENT" then
            ( [ $line.frame[1:][] | select(type == "object") ]
              | map(select(has("kind"))) | first ) as $ev
            | if $ev == null then empty
              else
                {t:"event", seq:$line.wire_seq, dir:$line.dir, conn:$line.conn_id,
                 up:$up, listen:$lst,
                 id:(($ev.id // "") | ascii_downcase),
                 kind:$ev.kind,
                 pubkey:(($ev.pubkey // "") | ascii_downcase),
                 created_at:($ev.created_at // null),
                 tags:[ (($ev.tags // [])[] | select(type == "array")
                         | ( [ ((.[0] // "") | tostring), ((.[1] // "") | tostring) ]
                             + [ .[2:][] | tostring ] )) ]}
              end
          elif $verb == "REQ" then
            {t:"req", seq:$line.wire_seq, dir:$line.dir, conn:$line.conn_id,
             up:$up, listen:$lst,
             sub:(($line.frame[1] // "") | tostring),
             filters:[ $line.frame[2:][] | select(type == "object") ]}
          elif ($verb == "HAVEN_WIRE_SENTINEL" and $line.dir == "c2r") then
            # A HARNESS-SOCKET DECLARATION. The verb exists only in the E2E
            # harness (`TestRelay._declareHarnessSocket` /
            # `emitWireJournalSentinel`); the recording proxy intercepts it and
            # never forwards it, and `scripts/ci/check_wire_proxy_test_only.sh`
            # keeps the recorder vocabulary out of `haven/lib` and
            # `haven-core`. So a connection that emitted one IS a harness
            # socket, established from the journal rather than from a flag the
            # caller might forget. See the exclusion note in `evaluate`.
            {t:"harness", seq:$line.wire_seq, conn:$line.conn_id}
          else empty end
      else empty end
  ' -- "${f}"
}

# ---------------------------------------------------------------------------
# The assertions. jq rather than bash so the whole comparison runs on bash 3.2
# (the macOS runners hosting the iOS lanes have no associative arrays).
#
# evaluate <normalized-stream> <pools-json> <discovery-json> <exclude-json> \
#          <identity-pubkeys-json> <mls-group-ids-json> <mls-not-asserted-reason>
# Prints {"meta":[...],"violations":[...],"advisories":[...],"summary":{...}}
# ---------------------------------------------------------------------------
#
# The jq program is emitted from a QUOTED heredoc into a temp file rather than
# passed as a single-quoted bash argument. The failure messages below are the
# deliverable — they have to read as English naming an inference — and English
# contains apostrophes, every one of which would close a bash '...' literal.
# Rewriting the prose to dodge the shell would be letting the quoting decide
# what the guard is allowed to say.
evaluate() {
  local stream="$1" pools="$2" discovery="$3" exclude="$4" identity="$5" mlsids="$6"
  local mls_not_asserted="${7:-}" expect_mlsids="${8:-null}" prog
  prog="$(mktemp)"
  cat > "${prog}" <<'JQPROG'

    # --- helpers -----------------------------------------------------------
    def canon: ascii_downcase | sub("^wss?://";"") | sub("^https?://";"") | sub("/+$";"");
    def cardOf($v): if $v == null then 0
                    elif ($v | type) == "array" then ($v | length)
                    else 1 end;
    def tagVals($tags; $n): [ $tags[] | select(.[0] == $n) | .[1] ];
    def nameList($tags): [ $tags[] | .[0] ];
    def short($s): ($s // "") | .[0:12];

    # The de-duplication key: the event BODY, never the `id` alone.
    #
    # `id` is journal DATA. It is a value a hostile or buggy client chose and
    # this oracle re-read; nothing here verifies it against the NIP-01 hash of
    # the body it labels. Keying the de-dup on it would let two frames that
    # share an id but differ in kind, pubkey, created_at or tags collapse to
    # whichever the recorder saw FIRST, and that survivor would answer for
    # both — the one shape in which a determinism fix becomes a blindfold. It
    # takes C5.1, C5.3, C5.4 and C5.5 out at once, because each of them reads
    # only the survivor.
    #
    # Excluded on purpose: direction, connection, wire_seq and endpoint. Those
    # are exactly the axes along which ONE event legitimately repeats
    # (published to N relays, echoed to M subscribers), and folding them in
    # would turn every count in this file back into a multiset that flakes.
    #
    # An id-less frame collapses with nothing: `tostring` of the whole row is
    # unique per line, so a frame this oracle cannot identify is always
    # carried into the assertions rather than merged away.
    #
    # Three of the five components are load-bearing TODAY, and each has a
    # self-test fixture that fails when it is dropped: `tags` (C5.3/C5.4/C5.5),
    # `kind` (which assertion set an event is judged by at all) and
    # `created_at` (C5.1's entire subject). `id` and `pubkey` are inert against
    # the current six invariants — a collision on the other components leaves
    # every field they read identical, so dropping either hides nothing and
    # both survive mutation. They are kept because the key is the BODY: an
    # assertion added later that reads a pubkey (a signer reused across
    # circles, say) would otherwise be born blind, and finding that out costs
    # another round of this analysis.
    def bodyKey: if ((.id // "") == "") then ["noid", (. | tostring)]
                 else [.id, .kind, .pubkey, .created_at, (.tags | sort)] end;

    # C5.7's counting key, and deliberately NOT `bodyKey`. C5.7 asks "did one
    # ephemeral key sign two MESSAGES", and two frames wearing one `id` but
    # differing in their body are not two messages: at most one of them can be
    # the event that key actually signed, and the other is a forgery or a
    # corruption. Counting them as a key reuse would put a confident, wrong
    # name on a completely different defect.
    #
    # This is not the blindfold `bodyKey` exists to prevent, because nothing
    # goes unchecked: C5.3, C5.4 and C5.5 still read `$uniq`, so BOTH bodies
    # are judged on their own tags — only the reuse ARITHMETIC folds them, and
    # only where folding is the correct reading. An id-less frame still falls
    # back to the whole body, so a frame this oracle cannot identify is never
    # merged into another one.
    def evKey: if ((.id // "") == "") then ("noid:" + (. | tostring)) else .id end;

    ($discovery | map(canon)) as $DISC
    | ($pools | with_entries(.value |= map(canon))) as $POOL

    # --- endpoint resolution ------------------------------------------------
    # A traffic line names its own endpoint (C1 writes `relay_url` + `listen`
    # on every frame). A journal in the bare contract shape does not, so the
    # per-connection `conn_open` record is joined in as a fallback. Both forms
    # are supported because C5.6 is the one invariant that CANNOT be written at
    # all without an endpoint, and silently degrading to "no endpoint, no
    # finding" is the exact failure this workstream exists to stop.
    | ( reduce (.[] | select(.t == "open")) as $o
          ({}; .[$o.conn] = {up:$o.up, listen:$o.listen}) ) as $connEp

    # The E2E harness talks to the same proxied relays as the app under test
    # (TestRelay.firstWhere, collectN, publishAndAwaitOk), so its frames are in
    # this journal too — and they are NOT Haven-s privacy surface. Attributing
    # a harness probe to the app would manufacture findings; worse, normalising
    # its traffic as ordinary would teach a reader to ignore the real thing.
    #
    # A harness socket is worse than noise for C5.1, which reasons per
    # PUBLISHER: `SyntheticUser.publishLocation` puts every simulated peer-s
    # kind-445 on whichever `TestRelay` its scenario holds, so ONE connection
    # multiplexes several devices. Judged as a device it looks exactly like the
    # defect C5.1 hunts — two circles served in one second by one publisher —
    # when what happened is two peers publishing 35 ms apart.
    #
    # Two sources, unioned, because each covers what the other cannot:
    #   * --exclude-conn, fed from the proxy-s sentinel ack, which hands the
    #     caller the emitting `conn_id` (tooling/e2e/local-relay/src/
    #     frame.rs:137-146). Needs the drive to print the ack and the lane to
    #     grep it back out.
    #   * $harness, read straight out of the journal: every connection that
    #     EMITTED the intercepted sentinel verb declared itself, so a socket
    #     opened mid-run (a TestRelay reconnect mints a fresh conn_id) is
    #     covered without any host-side plumbing at all.
    #
    # This can only ever REMOVE evidence, never add it, so it is safe against a
    # caller who over-excludes: every precondition below is computed AFTER
    # exclusion, and a lane that excludes its way to an empty sample fails
    # closed as a META-FLOOR rather than reporting clean.
    # `. as $x` first: see the KNOWNKEYS note below — a bare `.` inside
    # `index(...)` binds to index-s input, not to the row.
    | ( [ .[] | select(.t == "harness") | .conn ] | unique ) as $harness
    | (( $excludeConns + $harness ) | unique) as $EXCL
    | [ .[] | . as $x | select(($EXCL | index($x.conn)) == null) ]
    | [ .[]
        | . as $r
        | ($connEp[$r.conn] // {up:"", listen:""}) as $fb
        | .up     = (if ($r.up // "") != "" then $r.up else $fb.up end)
        | .listen = (if ($r.listen // "") != "" then $r.listen else $fb.listen end)
        | .epKey  = (if (.up // "") != "" then (.up | canon)
                     elif (.listen // "") != "" then (.listen | canon)
                     else "" end)
        | .epName = (if (.up // "") != "" then .up
                     elif (.listen // "") != "" then .listen
                     else "<unknown endpoint>" end)
      ] as $rows

    | [ $rows[] | select(.t == "event") ] as $events
    | [ $rows[] | select(.t == "req" and .dir == "c2r") ] as $reqs

    # De-duplicate by BODY (see `bodyKey`): one event is legitimately published
    # to N relays and echoed to M subscribers, so every count in this journal
    # is nondeterministic and a count assertion would flake — but two DIFFERENT
    # bodies wearing one id are two events, and both are checked.
    | ( $events | group_by(bodyKey) | map(.[0]) ) as $uniq

    # C5.6 needs (event, endpoint) pairs, not events: the same event reaching
    # TWO endpoints is two containment facts. Fan-out of one event to N relays
    # under ONE id is the NORMAL publishing shape, and it is precisely the
    # shape in which a containment breach occurs — the copy that leaves the
    # pool carries the same id as the copies that stayed inside it. Dropping
    # `.epKey` from this key keeps only the first endpoint per body and reports
    # every other destination as if it had never been written to.
    | ( [ $events[] | select(.dir == "c2r") ]
        | group_by([bodyKey, .epKey])
        | map(.[0]) ) as $sent

    # C5.1 needs (event, CONNECTION) pairs, and neither `$uniq` nor `$sent`
    # is that. `$uniq` folds the connection away entirely (it is one of the
    # axes along which one event legitimately repeats), and `$sent` keys on the
    # ENDPOINT, so two sockets talking to the same relay — the app-s and a
    # peer-s — collapse into one row that then answers for both. The
    # connection is the only publisher boundary this journal has, so it has to
    # survive into the key.
    | ( [ $events[] | select(.dir == "c2r") ]
        | group_by([bodyKey, .conn])
        | map(.[0]) ) as $sentByConn

    | [ $uniq[] | select(.kind == 445) ] as $u445
    | [ $u445[] | select(nameList(.tags) | index("expiration")) ] as $u445app
    | [ $u445[] | select(nameList(.tags) | index("expiration") | not) ] as $u445nonapp
    | [ $uniq[] | select(.kind == 1059) ] as $u1059

    # --- the SEND-SIDE snapshot, for C5.7 / C5.8 / C5.9 --------------------
    #
    # C5.1-C5.6 read `$uniq`, which spans both directions, because the
    # questions they ask (is this timestamp shared, is this tag name allowed)
    # have the same answer whoever put the frame on the socket. The three
    # invariants below do NOT: each of them asks what HAVEN did, and an
    # inbound frame is the RELAY's output. A relay is free to echo a Haven
    # event back, to serve another client's 445, or to hand back anything at
    # all — none of which is evidence about the app under test, and every one
    # of which would be a false red if it were counted. So they are scoped to
    # `dir == "c2r"`, and what is known about inbound is reported as an
    # advisory that asserts nothing.
    #
    # De-duplicated by BODY and NOT by (body, endpoint): unlike C5.6, none of
    # these three asks where an event went, so one event published to N relays
    # must count once. Counting it per endpoint would make "no two 445s share
    # an author" fire on the first ordinary fan-out.
    | ( [ $events[] | select(.dir == "c2r") ]
        | group_by(bodyKey) | map(.[0]) ) as $uSent
    | [ $uSent[] | select(.kind == 445) ] as $s445

    # The kinds whose author IS the account's long-term identity key, per the
    # protocol table in CLAUDE.md: kind 0 (NIP-01 profile), 10002 (NIP-65),
    # 10050 (NIP-17 inbox) and 30443 (KeyPackage) are all signed by the
    # identity key. 445 and 1059 are signed by a fresh ephemeral key and 444
    # is unsigned, so none of those three can contribute.
    #
    # Deriving the set from the journal rather than only from a flag is what
    # keeps this honest: the identity keys ARE observable on the wire, so the
    # oracle can build its own ground truth and cannot be starved of it by a
    # caller who forgets a flag. `$uniq` (both directions) is read on purpose
    # — an inbound kind-0 from a peer names a real identity key too, and
    # learning it can only ever WIDEN the forbidden set. Widening cannot
    # manufacture a finding on its own: a finding still requires a c2r 445
    # signed by one of these keys.
    | ([0, 10002, 10050, 30443]) as $IDKINDS
    | ( ( [ $uniq[] | select(.kind as $k | $IDKINDS | index($k)) | .pubkey ]
          + ($identityPubkeys | map(ascii_downcase)) )
        | map(select(. != "")) | unique ) as $IDKEYS

    # The FLOOR set, deliberately narrower than the assertion set above.
    # $IDKEYS spans BOTH directions on purpose: a 445 signed by any key this run
    # saw on an identity-scoped event is a finding, including a peer's. But the
    # C5.7 assertion is scoped to c2r, so a floor discharged by an INBOUND key
    # proves nothing about it -- a peer keypackage arriving on r2c would satisfy
    # "we knew at least one identity key" while the local account's key was
    # never in the comparison at all, and a 445 signed by it would report clean.
    # The floor therefore requires a key this run saw the DEVICE use, or one the
    # lane declared.
    | ( ( [ $uSent[] | select(.kind as $k | $IDKINDS | index($k)) | .pubkey ]
          + ($identityPubkeys | map(ascii_downcase)) )
        | map(select(. != "")) | unique ) as $IDKEYS_SEND

    | ($mlsGroupIds | map(ascii_downcase) | unique) as $MLSIDS
    | ($expectMlsGroupIds) as $EXPECTMLS

    # ======================================================================
    # C5.1 — created_at collision across distinct `h`, PER PUBLISHER
    # ======================================================================
    # Scoped to `dir == "c2r"` and partitioned by the sending CONNECTION, for
    # the reason C5.7-C5.9 are scoped the same way: the question is what ONE
    # DEVICE did. A device that publishes to two circles in the same second
    # hands anyone holding both events a co-membership edge; two SEPARATE
    # devices whose publishes happen to land in the same second hand over
    # nothing, because there is no shared device to be inferred. Asserting
    # over the union of every publisher in the journal does not measure a
    # property of Haven at all — it measures how many simulated devices the
    # scenario ran and how fast, and in a lane that runs fifteen of them in one
    # process it is a birthday collision waiting to happen.
    #
    # The connection is the device boundary the journal has: the app under test
    # publishes through its own relay client, each in-process SyntheticUser
    # peer through its own, and the harness-s multiplexed sockets are excluded
    # above (a TestRelay carries several peers-  traffic and is nobody-s
    # device). Inbound frames are dropped for the same reason C5.7 drops them:
    # an r2c 445 is the RELAY-s output — Haven-s own event echoed back, another
    # client-s message, or an injection — and none of that is evidence about
    # what this app transmitted. What is known about the traffic this scoping
    # sets aside is printed as an advisory, never as silence.
    #
    # LIMIT, stated rather than hidden: co-timing that a device splits across
    # two relays lands on two connections and so in two partitions. The
    # per-endpoint META-FLOOR below refuses to report clean when the journal
    # carries more than one upstream, so the day a multi-relay lane runs C5
    # this fails LOUDLY and gets a real device channel rather than quietly
    # checking half of what it claims.
    | ( [ $sentByConn[] | select(.kind == 445) ] ) as $c51pool
    | ( [ $c51pool[] | select(nameList(.tags) | index("expiration")) ] ) as $c51app
    | ( [ $u445app[] | (tagVals(.tags; "h") | first) // "" ] | unique
        | map(select(. != "")) ) as $appH

    # The precondition is per CONNECTION, matching the assertion. A run in
    # which two circles published an application 445 but never the same device
    # cannot exhibit the leak, so its silence is not evidence — the whole point
    # of the decorrelation work is that ONE device serves several circles, and
    # only a device that did so can prove it kept them apart.
    #
    # Commits and proposals still do NOT count towards this floor: they carry
    # no inner timestamp and keep the wrap-time default
    # (transport-nostr-peeler/src/peeler.rs:166), so a device whose second
    # group emitted only commits would satisfy a naive ">=2 distinct h" floor
    # while proving nothing about the timestamp binding — which is exactly
    # where the leak lives.
    | ( [ $c51app[]
          | {conn:.conn, h:((tagVals(.tags; "h") | first) // "")}
          | select(.h != "") ]
        | group_by(.conn)
        | map({conn: .[0].conn, groups: ([ .[] | .h ] | unique | length)}) )
      as $c51byConn
    | ( [ $c51byConn[] | select(.groups >= 2) ] ) as $c51multi

    # The one shape a per-CONNECTION partition is blind to: two groups whose
    # kind-445s reached DISJOINT sets of relays. One device publishing to both
    # in the same second would then necessarily use two connections, so the
    # pair could never land in one partition and the collision would go
    # unreported. Overlapping relay sets are fine — the ordinary fan-out of one
    # circle to several relays does not hide anything, because both groups
    # still meet on the shared endpoint's connection.
    | ( [ $c51pool[]
          | {h: ((tagVals(.tags; "h") | first) // ""), ep: .epKey} ]
        | map(select(.h != "" and .ep != ""))
        | group_by(.h)
        | map({h: .[0].h, eps: ([ .[] | .ep ] | unique)}) ) as $c51groupEps
    | ( [ $c51groupEps[] as $a
          | $c51groupEps[] as $b
          | select($a.h < $b.h)
          | select((($a.eps) - (($a.eps) - ($b.eps))) | length == 0)
          | "\(short($a.h))…/\(short($b.h))…" ] ) as $c51blind

    # The ASSERTION spans every 445 the device sent, commits included: two 445s
    # in the same second under different `h` are linkable whichever kind of
    # message they carry. Kind-445s are signed by a fresh ephemeral key per
    # message (Security Rule 2), so `created_at` is the ONLY field on the outer
    # event that can bind two of them — and it binds them regardless of what is
    # inside.
    | ( [ $c51pool[]
          | select(.created_at != null)
          | {conn:.conn, ts:.created_at,
             h:((tagVals(.tags; "h") | first) // ""), id:.id}
          | select(.h != "") ]
        | group_by([.conn, .ts])
        | map(select(([ .[] | .h ] | unique | length) >= 2)) ) as $collisions

    # Array concatenation, never `\(a) + \(b)` over two `if … else empty end`
    # arms: `empty + "text"` is EMPTY in jq, so a stream-valued `+` would
    # DELETE the precondition message on exactly the runs that have one.
    | ( (if (($c51multi | length) == 0) then
          [ "C5.1 precondition: no single connection PUBLISHED an application kind-445 (a 445 carrying `expiration`) for two distinct groups below the sentinel — \($c51byConn | length) publishing connection(s), the widest covering \([ 0, ($c51byConn[] | .groups) ] | max) group(s), over \($appH | length) app-publishing group(s) in the journal as a whole. A created_at collision is a statement about ONE device serving two circles, so a run in which no device ever served two circles cannot exhibit it and its silence is not evidence. Commits and proposals do NOT count towards this floor: they carry no inner timestamp and keep the wrap-time default (transport-nostr-peeler/src/peeler.rs:166), so a device whose second group emitted only commits would satisfy a naive \">=2 distinct h\" floor while proving nothing about the timestamp binding — which is exactly where the leak lives. Either the scenario never put the app in two circles at once with location sharing live, or the publishes it made were split across connections — which would ALSO break the attribution this invariant is partitioned by. Fix the SCENARIO (or the attribution), not this floor." ]
         else [] end)
      + (if (($c51blind | length) > 0) then
          [ "C5.1 attribution: \($c51blind | length) pair(s) of groups published their kind-445s to DISJOINT relay sets (\($c51blind | join(", "))). This invariant partitions by CONNECTION to tell one device from another, and a device publishing to two such groups in the same second would necessarily do it over two connections — so that collision would sit in two partitions and go unreported. A clean verdict here would be a claim about pairs this run cannot see. Give the oracle a real device channel (a declared per-device identity), or keep the C5 lane on relay sets that overlap, rather than reading this run as a pass." ]
         else [] end) ) as $c51meta
    | [ ( $collisions[]
          | "C5.1 timestamp correlation: ONE publisher (connection \(.[0].conn)) published a kind-445 to \([ .[] | .h ] | unique | length) DIFFERENT groups at the same created_at (\(.[0].ts); h values \([ .[] | .h ] | unique | map(short(.)) | join(", "))). The peeler binds the outer event's created_at to the inner application message's timestamp (transport-nostr-peeler/src/peeler.rs:169-170, fed by cgka-engine/src/message_processor/send.rs:770-771), so anyone holding both events reads them as ONE publisher serving two circles — and that is the co-membership edge the whole h-tag design exists to withhold. The events need not have come from the same relay: created_at is inside the SIGNED event, so the correlation survives every relay hop, an archive, and any two operators comparing notes months later. Kind-445s are signed by a fresh ephemeral key per message, so created_at is the only thing that can bind two of them — which is why it must not." ) ] as $c51viol

    # ======================================================================
    # C5.2 — REQ-filter allow-list
    # ======================================================================
    # Closed world over filter KEYS as well as over their cardinality: a filter
    # field nobody has reasoned about cannot be shown not to carry identity or
    # location material. NIP-50 `search`, for one, puts plaintext query terms
    # on the wire, and it is rejected here by omission rather than by name.
    | ["ids","authors","kinds","since","until","limit","#a","#d","#e","#h","#p"] as $KNOWNKEYS
    | ( [ $reqs[] | .filters[] | select(has("#h")) ] ) as $hFilters

    # H(E): the union of every `#h` value REQ-ed at endpoint E, over the whole
    # snapshot. Used by the relay-set-homogeneity rule below.
    | ( reduce ($reqs[] | . as $r | $r.filters[] | select(has("#h"))
                | {ep:$r.epKey, vals:((.["#h"] // []) | if type == "array" then . else [.] end)})
          as $x ({}; .[$x.ep] = ((.[$x.ep] // []) + $x.vals | unique)) ) as $H

    | [ (if (($hFilters | length) == 0) then
          "C5.2 precondition: no REQ below the sentinel carried an `#h` filter, so the group-plane filter shape this invariant pins (haven-core/src/relay/live_sync/planes/group.rs:26-35, and the per-circle poll filter at haven/rust_builder/src/api.rs:8006) was never exercised. A clean C5.2 verdict over a snapshot containing no group subscription says nothing about how Haven subscribes."
         else empty end) ] as $c52meta

    | [ $reqs[]
        | . as $r
        | $r.filters[]
        | . as $f
        | (cardOf($f.authors)) as $nAuth
        | (cardOf($f["#p"]))   as $nP
        | ((($f["#h"] // []) | if type == "array" then . else [.] end) | unique) as $hs
        | ($hs | length) as $nH
        # The EFFECTIVE kind set, read at its WIDEST. `null` here means "every
        # kind", and it is what an ABSENT `kinds` resolves to: under NIP-01 a
        # filter constrains only on the fields it names, so a filter with no
        # `kinds` matches EVERY kind — strictly broader than the 445-only shape
        # this file blesses. Defaulting it to `[445]` would read the broadest
        # filter expressible as the narrowest interpretation available, which
        # is the fail-OPEN direction on the one axis a REQ can be widened
        # without adding a single character to the frame.
        #
        # `kinds: []` resolves to "every kind" too, for a different reason: it
        # is not portable. NIP-01 reads it as a condition no kind satisfies,
        # but relay implementations differ on whether an empty list constrains
        # at all, so what reaches the wire cannot be pinned to a set of kinds
        # from the journal alone — and an unpinnable constraint is read here as
        # no constraint.
        #
        # Only the kind-widening rule below reads this. The other five C5.2
        # rules key on filter KEY names, `authors`, `#p`, `ids` and `#h`, none
        # of which an absent `kinds` can narrow, so none of them can be
        # weakened by omitting it.
        | ( if ($f | has("kinds") | not) then null
            else ( ($f.kinds // []) | if type == "array" then . else [.] end
                   | if length == 0 then null else . end )
            end ) as $kindSet
        | (
            # `. as $k` before the lookup is load-bearing: in `$KNOWNKEYS |
            # index(.)` the argument is evaluated against index-s INPUT, so a
            # bare `.` there means "$KNOWNKEYS inside $KNOWNKEYS" (always 0) and
            # the rule would never fire. Bind first.
            ( ($f | keys)[]
              | . as $k
              | select(($KNOWNKEYS | index($k)) == null)
              | "C5.2 REQ filter: a REQ to \($r.epName) carried the filter key \"\($k)\", which is not in the allow-list. This is closed-world by design: a filter field nobody has reasoned about cannot be shown not to carry identity or location material — NIP-50 `search`, for instance, puts plaintext query terms on the wire, and a `#g` geohash filter would tell the relay which area the user is watching. Add it here WITH a rationale, or stop sending it." ),

            ( if $nAuth >= 2 then
                "C5.2 REQ filter: a REQ to \($r.epName) named \($nAuth) authors in ONE filter. A k-author filter hands the relay a k-clique of the user's social graph in a single query: it learns that those k people are connected through this user, and it learns it even if not one of them ever publishes anything. Kind 3 is forbidden as an EVENT for exactly this reason (tooling/e2e/wire_allowlist.json _forbidden_by_omission); the same information in a filter is the same disclosure in a different frame type. haven-core/src/profile/fetch.rs:342-347 uses singular .author() per REQ and must stay that way."
              else empty end ),

            ( if $nP >= 2 then
                "C5.2 REQ filter: a REQ to \($r.epName) named \($nP) `#p` values in ONE filter. That declares k people as a single correspondence set — the relay learns whose messages this user waits for, together, without decrypting anything. The inbox plane (haven-core/src/relay/live_sync/planes/inbox.rs:24-30) subscribes to the user's OWN pubkey and no other."
              else empty end ),

            # NOTE `else "" end`, never `else empty end` — and NOT because
            # `empty` would be swallowed at THIS spot. These three branches sit
            # inside an ARRAY constructor, where `empty` contributes zero
            # elements and is absorbed: the `join` still yields a string and
            # the message would survive. Stating otherwise would teach the next
            # reader a rule jq does not have.
            #
            # The real hazard is one level up. `$extra` is bound with `as`, and
            # a producer that yields `empty` makes every downstream string
            # yield empty too — `(empty) as $x | "msg \($x)"` prints NOTHING,
            # so the finding disappears with no trace and no exit code. The
            # array wrapper is the only thing standing between these branches
            # and that position, and one refactor (dropping the `[...]`, or an
            # `.[]`) removes it. Keeping every branch string-valued means the
            # expression cannot produce `empty` at all, wrapper or no wrapper.
            ( if $nH >= 2 and ($nAuth > 0 or $nP > 0 or (cardOf($f.ids)) > 0) then
                ( [ (if $nAuth > 0 then "an author list" else "" end),
                    (if $nP > 0 then "a `#p` recipient list" else "" end),
                    (if (cardOf($f.ids)) > 0 then "an `ids` list" else "" end) ]
                  | map(select(. != "")) | join(" and ") ) as $extra
                | "C5.2 REQ filter: a multi-`#h` filter (\($nH) groups) to \($r.epName) ALSO carried \($extra). The multiplexed `#h` REQ is ACCEPTED on its own because the receiving relay is already in all those circles' routing sets — it hands over the co-membership partition, but only to a relay that could infer it from the traffic anyway. Binding that partition to an author list, a recipient list or an id list in the SAME filter attaches names to a partition no relay could otherwise name, which is a strictly new disclosure."
              else empty end ),

            ( if $nH >= 2 and (($kindSet == null) or (($kindSet | map(select(. != 445)) | length) > 0)) then
                "C5.2 REQ filter: a multi-`#h` filter (\($nH) groups) to \($r.epName) requested \(if $kindSet == null then "EVERY kind — it declares no usable `kinds` constraint, and an absent (or empty, hence unpinnable) `kinds` matches every kind under NIP-01" else "kinds \($kindSet | tojson)" end) rather than kind 445 alone. The accepted shape multiplexes the GROUP plane; widening it to other kinds under the same `#h` set asks one relay to correlate the circle partition with a second event class. An omitted `kinds` is read here as the WIDEST set and never the narrowest: a filter that subscribes to everything is a superset of every shape this file has blessed, so reading it as \"445 only\" would let the broadest filter expressible pass as the one shape that was reasoned about."
              else empty end ),

            ( if $nH >= 2 then
                ( ($H | keys)[]
                  | . as $other
                  | (($H[$other] // []) | map(select(. as $v | $hs | index($v))) | length) as $overlap
                  | if $overlap > 0 and $overlap < $nH then
                      "C5.2 REQ filter: a multi-`#h` filter to \($r.epName) merged groups with DIFFERENT relay routing — \($overlap) of its \($nH) `#h` values are also subscribed at \($other), and the remaining \($nH - $overlap) never are. The accepted shape multiplexes only circles that share an identical canonical relay set (group.rs:1-5); a filter spanning two relay sets tells \($r.epName) about a circle it does not serve, and turns a partition each relay could have inferred locally into one that only a client holding both could have built."
                    else empty end )
              else empty end )
          )
      ] as $c52viol

    # ======================================================================
    # C5.3 — per-EVENT kind-445 tag shape
    # ======================================================================
    | [ (if (($u445app | length) == 0) then
          "C5.3 precondition: no kind-445 carrying `expiration` (an APPLICATION message) was observed below the sentinel, so the two-tag arm of the allow-list was never exercised. A commit-only journal proves nothing about the shape of the messages that actually carry location."
         else empty end),
        (if (($u445nonapp | length) == 0) then
          "C5.3 precondition: no kind-445 WITHOUT `expiration` (a commit or proposal) was observed below the sentinel, so the single-tag arm of the allow-list was never exercised. The allow-list has two arms and this run exercised one."
         else empty end) ] as $c53meta

    | [ $u445[]
        | . as $e
        | (nameList(.tags)) as $names
        | ($names | unique) as $set
        | ([ $names[] | select(. == "h") ] | length) as $nh
        | ([ $names[] | select(. == "expiration") ] | length) as $nexp
        | (
            ( if ($set != ["h"] and $set != ["expiration","h"]) then
                "C5.3 kind-445 tag shape: event \(short(.id))… carried tag names \($set | tojson). The only two shapes the peeler can emit are {h} for a commit or proposal and {h,expiration} for an application message (transport-nostr-peeler/src/peeler.rs:145-161). A third tag NAME gives a relay a per-message selector it can use to partition group traffic without decrypting any of it. This check is per-EVENT on purpose: the union-level tag check (C4) sees the same allowed names across the kind and cannot tell which event carried what."
              else empty end ),
            ( if $nh != 1 then
                "C5.3 kind-445 tag shape: event \(short(.id))… carried \($nh) `h` tags. Exactly one is correct; a SECOND `h` binds two groups together inside a single signed event, which is a stronger disclosure than any timestamp coincidence and one that no union-level tag check (C4) can see, because the NAME set is unchanged."
              else empty end ),
            ( if $nexp > 1 then
                "C5.3 kind-445 tag shape: event \(short(.id))… carried \($nexp) `expiration` tags. Duplicated NIP-40 claims are ambiguous to a relay, and the peeler pushes at most one (peeler.rs:156-161)."
              else empty end )
          )
      ] as $c53viol

    # ======================================================================
    # C5.4 — no `g`, no `alt`, on any kind
    # ======================================================================
    | [ (if (($u445 | length) == 0) then
          "C5.4 precondition: no kind-445 event was observed below the sentinel. The builder this guards (haven-core/src/nostr/event.rs:203) mints kind-445s, so with none in the snapshot its silence proves nothing."
         else empty end),
        (if (($uniq | length) == 0) then
          "C5.4 precondition: the snapshot contains no events at all."
         else empty end) ] as $c54meta

    | [ $uniq[]
        | . as $e
        | (nameList(.tags) | unique) as $set
        | (
            ( if ($set | index("g")) then
                "C5.4 forbidden tag: a kind-\($e.kind) event carried a `g` tag. That is a truncated geohash — coarse location in CLEARTEXT on the outer event, which every relay can index and query by `#g` without touching the ciphertext, and which every relay the event is broadcast to retains. haven-core/src/nostr/event.rs:203-227 is a live builder that stamps one; it is `pub(crate)` with only #[cfg(test)] callers today, and this is the tripwire for it becoming reachable."
              else empty end ),
            ( if ($set | index("alt")) then
                "C5.4 forbidden tag: a kind-\($e.kind) event carried an `alt` tag. haven-core/src/nostr/event.rs:217 pushes `alt` UNCONDITIONALLY — not only on geohash-bearing events — so were that builder ever reachable it would fingerprint EVERY Haven kind-445, letting a relay operator separate Haven's traffic from every other Marmot client's on the same relay and count its users, while decrypting nothing."
              else empty end )
          )
      ] as $c54viol

    # ======================================================================
    # C5.5 — kind-1059 tag set is exactly {p}, exactly once
    # ======================================================================
    | [ (if (($u1059 | length) == 0) then
          "C5.5 precondition: no kind-1059 gift wrap was observed below the sentinel, so the invitation-delivery tag set was never exercised. A run that issues no invitation cannot vouch for how invitations look on the wire."
         else empty end) ] as $c55meta

    | [ $u1059[]
        | . as $e
        | (nameList(.tags)) as $names
        | ($names | unique) as $set
        | ([ $names[] | select(. == "p") ] | length) as $np
        | (
            ( if ($set != ["p"]) then
                "C5.5 kind-1059 tag set: gift wrap \(short(.id))… carried \($set | tojson) rather than exactly {p}. A NIP-40 `expiration` here is a plaintext retention claim, and — because ordinary NIP-17 DM gift wraps carry none — it also DISTINGUISHES Haven invitations from every other 1059 in the relay's stream, letting an operator pick Haven users out of the crowd and date each invitation, all without unwrapping anything. It would also falsify the shipped privacy copy, which tells the user invitations carry no expiry. Production wraps via MDK's wrap_welcome_with_metadata with empty extra tags, so a tag appearing here means the peeler changed."
              else empty end ),
            ( if $np != 1 then
                "C5.5 kind-1059 tag set: gift wrap \(short(.id))… carried \($np) `p` tags. A gift wrap addresses exactly one recipient; a second names two people as invited TOGETHER, which reconstructs part of the circle roster the wrapping exists to hide."
              else empty end )
          )
      ] as $c55viol

    # ======================================================================
    # C5.6 — publish-target containment, scoped PER KIND
    # ======================================================================
    # A flat URL allow-list would false-green here. The discovery plane
    # (haven-core/src/relay/discovery.rs:20-21) is never a publish target, yet
    # it is a strict SUPERSET of the account seed (discovery.rs:38-41) — so
    # every account-plane URL is also a discovery URL, and one flat list
    # containing both would accept a write to a public indexer.
    | ( [ $sent[] | select(.epKey == "") ] ) as $unrouted
    | ( [ $sent[] | .kind ] | unique ) as $sentKinds
    | [ (if (($sent | length) == 0) then
          "C5.6 precondition: no client->relay EVENT was observed below the sentinel, so there were no publish targets to contain."
         else empty end),
        (if (($unrouted | length) > 0) then
          "C5.6 precondition: \($unrouted | length) sent EVENT(s) could not be resolved to an endpoint — the journal lines carry neither `relay_url`/`listen` nor a `conn_open` record for their connection. Containment cannot be asserted against an unknown destination, and reporting no finding would report \"we did not look\" as \"nothing left the pool\"."
         else empty end),
        ( $sentKinds[]
          | . as $k
          | if ($POOL | has($k | tostring) | not) then
              "C5.6 precondition: kind \($k) was PUBLISHED below the sentinel but no --pool was declared for it, so its publish targets cannot be bounded. Declare the pool (445 -> the circle's relays, 1059 -> the recipient's kind-10050 inbox relays, 30443 -> the account NIP-65 (10002) relays, 0 -> resolve_profile_pool, 10002/10050 -> the account plane) or stop publishing the kind."
            else empty end ) ] as $c56meta

    | [ $sent[]
        | . as $s
        | ($POOL[$s.kind | tostring]) as $pool
        | (
            ( if ($s.epKey != "") and ($DISC | index($s.epKey)) then
                "C5.6 publish containment: a kind-\($s.kind) EVENT was PUBLISHED to \($s.epName), a declared DISCOVERY relay. haven-core/src/relay/discovery.rs:20-21 states the discovery plane is never a publish target and never carries the local user's writes: it is a curated set of PUBLIC indexers, queried read-only precisely so that resolving somebody else's pubkey never exposes the local user. A write there attaches this user's identity, and this event, to a public indexer — and note that a flat URL allow-list could not have caught it, because the discovery set is a strict SUPERSET of the account seed (discovery.rs:38-41), so every legitimate account-plane URL is also a discovery URL. REQ yes; EVENT never."
              else empty end ),
            ( if ($s.epKey != "") and ($pool != null) and (($pool | index($s.epKey)) == null) and (($DISC | index($s.epKey)) == null) then
                "C5.6 publish containment: a kind-\($s.kind) EVENT was PUBLISHED to \($s.epName), which is not in the declared pool for that kind (\($pool | tojson)). Each kind has its OWN pool for a reason — a kind-445 belongs only to its circle's relays, a 1059 only to the recipient's inbox relays, a 30443 only to the account's NIP-65 relays — so an event reaching a relay outside its kind's pool hands that operator both the event and the pubkey that signed it, on a plane it was never routed to."
              else empty end )
          )
      ] as $c56viol

    # ======================================================================
    # C5.7 — a FRESH EPHEMERAL author on every kind-445 (Security Rule 2)
    # ======================================================================
    # Two obligations under one heading, because "fresh ephemeral key per
    # message" is two claims: the key is EPHEMERAL (never a long-term identity
    # key) and it is FRESH (never reused by a second message). Either alone is
    # satisfiable while the rule is broken — a key used once but equal to the
    # identity key attributes the message to the account, and a never-identity
    # key reused across two messages links those two messages to one another.
    #
    # `$IDKEYS` is the derived-plus-declared identity set; `$s445` is the
    # send-side, body-de-duplicated 445 set. Both are computed above.
    | ( $s445 | group_by(.pubkey)
        | map(select((.[0].pubkey // "") != ""))
        | map(select((map(evKey) | unique | length) >= 2)) ) as $reused

    | [ (if (($s445 | length) < 2) then
          "C5.7 precondition: only \($s445 | length) distinct kind-445 was PUBLISHED below the sentinel, so \"no two kind-445s share an author\" is vacuously true — with fewer than two messages there is no pair to compare and the freshness half of Security Rule 2 was never tested. This is a META-FLOOR and not a pass: an ephemeral key that is reused on every single message would produce exactly this verdict in a run that published once. Make the scenario publish at least two group messages below the sentinel."
         else empty end),
        (if (($IDKEYS_SEND | length) == 0) then
          "C5.7 precondition: no identity-signed event (kind 0, 10002, 10050 or 30443) was SENT below the sentinel and no --identity-pubkey was declared, so \"no kind-445 was signed by a long-term identity key\" was compared against a set containing no key this device is known to sign with, and could not have failed for the account under test. An INBOUND identity key does not discharge this: C5.7 is scoped to dir==c2r, so a key that only ever arrived from the relay can never match a c2r 445 author. Publish one identity-scoped event from the device in the scenario, or declare the account pubkey(s) with --identity-pubkey."
         else empty end) ] as $c57meta

    | [ ( $s445[]
          | . as $e
          | select(($e.pubkey // "") == "")
          | "C5.7 ephemeral author: kind-445 \(short($e.id))… was PUBLISHED carrying no author pubkey at all. Security Rule 2 requires a fresh keypair per group message, and an event with no author does not carry one — either the recorder decoded a frame this oracle cannot reason about, or the publish path emitted an unsigned 445. Neither is a shape whose privacy properties anyone has established." ),

        # `. as $e` before the lookup, then `$IDKEYS | index($e.pubkey)`. The
        # repo-wide `index(.)` trap: index's argument is evaluated against
        # index's own INPUT, so `$IDKEYS | index(.pubkey)` would ask for
        # "$IDKEYS.pubkey inside $IDKEYS" — `null` every time, and the rule
        # would never fire while looking exactly like it does now.
        ( $s445[]
          | . as $e
          | select((($e.pubkey // "") != "") and (($IDKEYS | index($e.pubkey)) != null))
          | "C5.7 ephemeral author: kind-445 \(short($e.id))… was signed by \(short($e.pubkey))…, which this run also saw signing an identity-scoped event (kind 0/10002/10050/30443) or which was declared with --identity-pubkey. Security Rule 2 requires a NEW keypair for each group message precisely so the outer event carries no stable handle: signing with the account key attributes every one of that circle's messages to a named person, at every relay, forever, without decrypting a byte — and it also re-links that person to every other kind this key signs, which is the whole social graph the group plane is built to keep apart." ),

        ( $reused[]
          | . as $g
          | "C5.7 ephemeral author: one pubkey (\(short($g[0].pubkey))…) signed \($g | map(evKey) | unique | length) DIFFERENT kind-445 events (ids \($g | map(short(.id)) | unique | join(", "))). A reused author is a stable per-sender handle on the outer event: the relay cannot read the messages, but it can group them, count them, time them and — the moment any one of them is deanonymised by other means — retroactively attribute all of the others. Fan-out is not this: the same event on N relays and echoed to M subscribers is de-duplicated by body before this rule runs, so reaching it takes two genuinely different messages." ) ] as $c57viol

    # ======================================================================
    # C5.8 — the real MLS group id is NEVER on the wire (Security Rule 4)
    # ======================================================================
    # # How the oracle learns the id, and why it cannot infer it
    #
    # The real MLS group id is generated per circle at runtime and never
    # leaves the device by design, so it is by construction absent from the
    # journal — which is exactly the thing being asserted, and also the reason
    # this file cannot derive it the way it derives `$IDKEYS`. There is no
    # observable it could be recovered from without breaking the invariant
    # first. It is therefore CALLER-SUPPLIED ground truth (`--mls-group-id`),
    # in the same posture as C5.6's `--pool`: the check proves absence of the
    # value the lane says it created.
    #
    # It cannot live in `wire_allowlist.json` either. That file is checked in
    # and static; the id is minted fresh on every run, so a declaration there
    # would either be a stale constant matching nothing, or a value that must
    # be rewritten before every run to stay meaningful.
    #
    # # An undeclared id is a META-FLOOR, not a silent pass
    #
    # A caller who publishes kind-445s has, by definition, created a circle
    # and knows its MLS group id. If none is declared while 445s were sent,
    # the scan compared the wire against nothing at all, and reporting that as
    # "no leak found" is the precise failure this workstream exists to remove.
    #
    # # Stated limits
    #
    # This is a HEX-SUBSTRING scan over decoded tag tokens of client->relay
    # events. It does not see `content` (ciphertext, and not normalised here),
    # nor an id re-encoded as base64, bech32 or raw bytes. Proving absence in
    # EVERY encoding is C6's job — `tooling/e2e/ci/check-wire-canaries.dart`
    # plants a value the run knows and requires it to be absent under each
    # encoding. C5.8 is the cheap, always-on half: it catches the leak that
    # actually happens, which is the id going out in a tag verbatim because a
    # builder reached for the wrong field.
    #
    # # A NON-EMPTY needle set is not the same as a COMPLETE one
    #
    # Everything above turns on `$MLSIDS` being non-empty, and nothing in the
    # journal can say whether it is COMPLETE: an id the host never received is
    # indistinguishable from a circle the run never created. A needle set that
    # silently shrank — a sidecar rotated under the recorder, a declaration that
    # never reached it, an announce call site deleted — leaves this scan looking
    # exactly as busy as a full one, over fewer values, and the run reports
    # clean. `--expect-mls-group-ids` is the lane's own count of what the drive
    # announced, held against what arrived. It is the only ground truth for
    # completeness that exists outside this file, and it is OPTIONAL: a lane
    # that does not supply it gets no cross-check, and the summary line says so
    # rather than implying one ran.
    | [ (if ($EXPECTMLS != null) and ($EXPECTMLS != ($MLSIDS | length)) then
          "C5.8 ground truth: the lane announced \($EXPECTMLS) MLS group id(s) but \($MLSIDS | length) reached this scan. C5.8 is a search for values it cannot derive, so its needle set IS its coverage: fewer needles than the run created means some circle's whole traffic went unscanned while every other verdict here still reported clean, and MORE means the set carries values this run never minted (a sidecar that was not rotated), which can never be found and cannot fail. Fix the channel — drive announcement -> proxy interception -> sidecar -> this flag — rather than the count; the two numbers are produced independently on purpose, and neither is worth trusting alone."
         else empty end),
        (if (($MLSIDS | length) == 0) and (($s445 | length) > 0)
             and ($mlsNotAsserted == "") then
          "C5.8 precondition: \($s445 | length) kind-445(s) were PUBLISHED below the sentinel but no --mls-group-id was declared, so the scan for a leaked MLS group id compared the wire against an empty set of values and could not have failed. The real group id cannot be derived from the journal — its absence there is the very thing being asserted — so it must be supplied by the lane that created the circle (CircleFfi.mlsGroupId, hex-encoded). Declare it or stop asserting Security Rule 4 here."
         else empty end),
        (if (($MLSIDS | length) > 0) and (($s445 | length) == 0) then
          "C5.8 precondition: an MLS group id was declared but no kind-445 was PUBLISHED below the sentinel. Kind-445 is the kind that carries a group routing value in a tag, so a snapshot with none of them contains none of the events that could have leaked the real id, and a clean verdict describes the sample rather than the app."
         else empty end) ] as $c58meta

    # Every token of every tag of every SENT event, of every kind — not just
    # 445. Security Rule 4 says the real group id is never published, full
    # stop: a 1059 or a 30443 carrying it discloses the same value to the same
    # operator. `contains` is a substring test on purpose, so an id embedded
    # in a longer token (a composite `d` slot, a URL query) is caught too;
    # main() refuses a declared id shorter than 32 hex chars, without which a
    # short value would match by coincidence and drown the check in noise.
    | [ $uSent[]
        | . as $e
        | .tags[]
        | . as $tag
        | ($tag | to_entries[])
        | . as $tok
        | $MLSIDS[]
        | . as $mid
        | select(($tok.value | ascii_downcase | contains($mid)))
        | if (($tag[0] == "h") and ($tok.key == 1) and (($tok.value | ascii_downcase) == $mid)) then
            "C5.8 group-id privacy: kind-\($e.kind) event \(short($e.id))… routes by an `h` tag whose value IS the real MLS group id. Security Rule 4 permits only `nostr_group_id` on the wire; the two must be different values, and here they are the same one. Treat this as id ALIASING in the layer that mints the routing value, not as a stray tag: if the two ids are equal then every h-tag scan anywhere in this repo — including the rest of C5.8 — passes vacuously while the real id is broadcast on every single group message, and the relay gains a permanent, cross-epoch handle on the MLS group itself."
          else
            "C5.8 group-id privacy: kind-\($e.kind) event \(short($e.id))… PUBLISHED the real MLS group id inside its `\($tag[0])` tag at position \($tok.key). Only `nostr_group_id` may appear on the wire (Security Rule 4). The real id is the identifier the MLS group keeps across every epoch change, so a relay that sees it once can link the whole group's traffic together for the group's entire lifetime — through key rotations, membership changes and any later change of the nostr_group_id, which is the one thing rotating the public handle is supposed to prevent."
          end ] as $c58viol

    # ======================================================================
    # C5.9 — no `p` tag on a kind-445 (recipient privacy)
    # ======================================================================
    # A NAMED diagnosis layered over a generic one, and honest about it: a `p`
    # on a 445 also trips C5.3 (per-event tag shape) and C4's union-level
    # allow-list, so this rule cannot be the only thing standing between the
    # repo and the leak, and it is not claimed to be. What it adds is the
    # reason: C5.3 reports "a third tag NAME", which tells a reader that
    # something is out of shape without telling them that circle membership
    # just became queryable at the relay. The two messages are asserted
    # separately in the self-test for exactly that reason.
    | [ (if (($s445 | length) == 0) then
          "C5.9 precondition: no kind-445 was PUBLISHED below the sentinel, so the recipient-privacy rule had no group message to read. Group messages are the only kind whose routing this rule constrains, and a snapshot without any says nothing about how they route."
         else empty end) ] as $c59meta

    | [ $s445[]
        | . as $e
        | select((nameList(.tags) | index("p")) != null)
        | "C5.9 recipient privacy: kind-445 \(short($e.id))… was PUBLISHED carrying a `p` (recipient) tag. A group message must route by its `h` tag ALONE. A `p` tag hands the relay an indexed, queryable membership edge: it can answer \"who receives this circle's messages\" with a single REQ, reconstruct the roster over time, and do it without decrypting anything — which undoes the ephemeral author key on the same event, since that key exists precisely to leave the relay with no participant names to join on."
      ] as $c59viol

    # ======================================================================
    # Inbound: reported, never asserted
    # ======================================================================
    # Everything C5.7 asks is a question about the SENDER, and inbound frames
    # are the relay's output — a relay may echo Haven's own event back (whose
    # author then legitimately repeats), serve another client's 445, or return
    # anything at all. Any of those would be a false red if asserted, so what
    # is known is printed and labelled instead. It is printed rather than
    # dropped because "we did not look" and "there was nothing to see" must
    # not read the same in a log a human is scanning for a reason a lane went
    # green.
    | ( [ $events[] | select(.dir == "r2c" and .kind == 445) ]
        | group_by(bodyKey) | map(.[0]) ) as $in445
    | [ (if (($in445 | length) > 0) then
          ( ([ $in445[] | .pubkey ] | unique | map(select(. != ""))) as $inAuth
            | ( [ $in445[] | . as $e | select((($e.pubkey // "") != "") and (($IDKEYS | index($e.pubkey)) != null)) ] | length ) as $inId
            | "\($in445 | length) inbound kind-445(s) below the sentinel, \($inAuth | length) distinct author key(s), \($inId) of them signed by a key this run also saw on an identity-scoped event. NOT asserted: an inbound frame is the relay's output, not Haven's, so a repeat or an identity-keyed author there may be the relay echoing Haven's own event, another client's traffic, or a hostile injection — none of which is evidence about the app under test. C5.7 is scoped to dir==c2r for that reason." )
         else "no inbound kind-445 was observed below the sentinel; nothing is claimed either way about what a relay returns." end)
      ,
        # The attribution C5.1 rests on, printed on every run — a reader must
        # be able to see WHICH publishers were judged and how wide each one's
        # circle set was, without re-deriving it from the journal.
        ( "C5.1 attribution: \($c51byConn | length) connection(s) published an application kind-445 below the sentinel, \($c51multi | length) of them to more than one group (widest \([ 0, ($c51byConn[] | .groups) ] | max) group(s)); \($EXCL | length) connection(s) excluded from EVENT attribution (\($harness | length) self-declared harness socket(s), \($excludeConns | length) named by the lane). A connection is the only publisher boundary this journal has; co-timing BETWEEN connections is not asserted, because two devices coinciding in one second discloses no shared device." )
      ] as $advisories

    | {
        meta: ($c51meta + $c52meta + $c53meta + $c54meta + $c55meta + $c56meta
               + $c57meta + $c58meta + $c59meta),
        violations: ($c51viol + $c52viol + $c53viol + $c54viol + $c55viol + $c56viol
                     + $c57viol + $c58viol + $c59viol),
        advisories: ($advisories
          + (if ($mlsNotAsserted != "") and (($s445 | length) > 0) then
               [ "C5.8 NOT ASSERTED (declared by the lane): \($mlsNotAsserted). \($s445 | length) kind-445(s) were published below the sentinel and were NOT scanned for a leaked real MLS group id, because the lane declared it cannot supply one. Security Rule 4 is therefore asserted for this run ONLY by the in-drive _assertWirePrivacyInvariants, which is narrower: it reads back a single circle's kind-445 stream and says nothing about 1059/30443/10002/0. This line is printed on EVERY run by design — it is the record that an invariant was skipped, not an absence to be inferred." ]
             else [] end)),
        summary: {
          event_frames: ($events | length),
          unique_events: ($uniq | length),
          req_frames: ($reqs | length),
          k445: ($u445 | length),
          k445_app: ($u445app | length),
          k445_commit: ($u445nonapp | length),
          k1059: ($u1059 | length),
          app_groups: ($appH | length),
          h_filters: ($hFilters | length),
          sent_pairs: ($sent | length),
          sent_445: ($s445 | length),
          sent_445_authors: ([ $s445[] | .pubkey ] | unique | map(select(. != "")) | length),
          identity_keys: ($IDKEYS | length),
          mls_ids: ($MLSIDS | length),
          mls_ids_expected: $EXPECTMLS,
          in_445: ($in445 | length),
          publishing_conns: ($c51byConn | length),
          multi_circle_conns: ($c51multi | length),
          excluded_conns: ($EXCL | length),
          harness_conns: ($harness | length),
          endpoints: ([ $rows[] | .epKey ] | unique | map(select(. != "")))
        }
      }
JQPROG
  jq -s \
    --argjson pools "${pools}" \
    --argjson discovery "${discovery}" \
    --argjson excludeConns "${exclude}" \
    --argjson identityPubkeys "${identity}" \
    --argjson mlsGroupIds "${mlsids}" \
    --argjson expectMlsGroupIds "${expect_mlsids}" \
    --arg mlsNotAsserted "${mls_not_asserted}" \
    -f "${prog}" -- "${stream}"
  local rc=$?
  rm -f "${prog}"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local sentinel=""
  local -a journals=()
  local pool_lines="" disc_lines="" excl_lines="" idpk_lines="" mlsid_lines=""
  MLS_NOT_ASSERTED=""
  # `null` until a lane declares one: an absent cross-check must read as absent,
  # never as a comparison against zero.
  EXPECT_MLS_IDS="null"

  if [[ $# -lt 1 ]]; then
    usage
    exit "${RC_USAGE}"
  fi
  if [[ "$1" == "--self-test" ]]; then
    self_test
    exit $?
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --journal)
        [[ $# -ge 2 ]] || { echo "ERROR: --journal needs a value" >&2; usage; exit "${RC_USAGE}"; }
        journals+=("$2"); shift 2 ;;
      --sentinel)
        [[ $# -ge 2 ]] || { echo "ERROR: --sentinel needs a value" >&2; usage; exit "${RC_USAGE}"; }
        sentinel="$2"; shift 2 ;;
      --pool)
        [[ $# -ge 2 ]] || { echo "ERROR: --pool needs a value" >&2; usage; exit "${RC_USAGE}"; }
        if [[ "$2" != *=* ]]; then
          echo "ERROR: --pool expects <kind>=<url>[,<url>...], got: $2" >&2
          usage; exit "${RC_USAGE}"
        fi
        local pk pv url
        pk="${2%%=*}"; pv="${2#*=}"
        if [[ ! "${pk}" =~ ^[0-9]+$ ]]; then
          echo "ERROR: --pool kind must be an integer, got: ${pk}" >&2
          usage; exit "${RC_USAGE}"
        fi
        if [[ -z "${pv}" ]]; then
          # An empty pool would be read as "this kind may reach nothing", which
          # is a legitimate thing to want but not expressible by accident: a
          # typo'd `--pool 445=` must not silently become the strictest rule in
          # the file.
          echo "ERROR: --pool ${pk}= has no URLs. Omit the flag to leave the kind" >&2
          echo "       undeclared (a META-FLOOR if it is published)." >&2
          usage; exit "${RC_USAGE}"
        fi
        while IFS= read -r url; do
          [[ -n "${url}" ]] && pool_lines+="${pk}"$'\t'"${url}"$'\n'
        done <<< "$(printf '%s' "${pv}" | tr ',' '\n')"
        shift 2 ;;
      --discovery-relay)
        [[ $# -ge 2 ]] || { echo "ERROR: --discovery-relay needs a value" >&2; usage; exit "${RC_USAGE}"; }
        disc_lines+="$2"$'\n'; shift 2 ;;
      --exclude-conn)
        [[ $# -ge 2 ]] || { echo "ERROR: --exclude-conn needs a value" >&2; usage; exit "${RC_USAGE}"; }
        excl_lines+="$2"$'\n'; shift 2 ;;
      --identity-pubkey)
        [[ $# -ge 2 ]] || { echo "ERROR: --identity-pubkey needs a value" >&2; usage; exit "${RC_USAGE}"; }
        if [[ ! "$2" =~ ^[0-9a-fA-F]{64}$ ]]; then
          echo "ERROR: --identity-pubkey expects 64 hex characters (a 32-byte x-only" >&2
          echo "       Nostr pubkey), got: $2" >&2
          echo "       An npub or a truncated key would silently never match any author" >&2
          echo "       in the journal, which turns C5.7's identity arm off while looking" >&2
          echo "       exactly like it is on." >&2
          usage; exit "${RC_USAGE}"
        fi
        idpk_lines+="$2"$'\n'; shift 2 ;;
      --mls-group-id-not-asserted)
        # The DECLARED, LOUD alternative to supplying the id. It does not make
        # C5.8 conditional -- a conditional check is a silent pass, and this
        # oracle's whole premise is that "we did not look" and "there was
        # nothing to see" must never render the same. It converts C5.8's
        # precondition from a META-FLOOR into an advisory printed on EVERY run,
        # and the flag itself is a visible token in the workflow diff that has
        # to be DELETED when the id channel lands. Time-boxed by review, not by
        # the script.
        [[ $# -ge 2 ]] || { echo "ERROR: --mls-group-id-not-asserted needs a reason" >&2; usage; exit "${RC_USAGE}"; }
        if [[ -z "${2// /}" ]]; then
          echo "ERROR: --mls-group-id-not-asserted needs a NON-EMPTY reason." >&2
          echo "       The reason is the whole point: it is what a reader sees" >&2
          echo "       instead of the assertion, and what review deletes later." >&2
          usage; exit "${RC_USAGE}"
        fi
        MLS_NOT_ASSERTED="$2"; shift 2 ;;
      --mls-group-id)
        [[ $# -ge 2 ]] || { echo "ERROR: --mls-group-id needs a value" >&2; usage; exit "${RC_USAGE}"; }
        if [[ ! "$2" =~ ^[0-9a-fA-F]+$ ]]; then
          # Length and a fixed label only. A partly-corrupted sidecar line is
          # hex-plus-junk, and echoing it would put a fragment of a Rule-4
          # value into a public job log. The two sibling rejections below
          # already print ${#2} for exactly this reason.
          echo "ERROR: --mls-group-id expects hex; got a ${#2}-char non-hex value (withheld)." >&2
          echo "       C5.8 scans hex tokens on the wire; a value in any other encoding" >&2
          echo "       cannot match one and would disable the scan silently." >&2
          usage; exit "${RC_USAGE}"
        fi
        if (( ${#2} % 2 != 0 )); then
          echo "ERROR: --mls-group-id has an odd number of hex characters (${#2}); it is" >&2
          echo "       not a whole number of bytes and cannot be the id the app minted." >&2
          usage; exit "${RC_USAGE}"
        fi
        # A SUBSTRING scan against a short needle finds itself everywhere. 32
        # hex chars (16 bytes) is already far past the point where a chance hit
        # inside an unrelated 64-hex token is credible; below it the check would
        # produce noise indistinguishable from a real leak, and a reviewer who
        # learns to dismiss its findings has lost the check either way.
        #
        # The floor is EXACT. OpenMLS mints a 16-BYTE group id
        # (openmls/src/group/mod.rs:73, rng.random_vec(16)) = 32 hex chars, so
        # every real id sits precisely here with zero headroom. Do NOT raise it
        # "for safety": that rejects every id the app creates and hard-fails
        # every lane. 128 bits is what the coincidence argument needs.
        if (( ${#2} < 32 )); then
          echo "ERROR: --mls-group-id must be at least 32 hex characters (got ${#2})." >&2
          echo "       C5.8 is a substring scan; a short needle matches unrelated tokens" >&2
          echo "       by coincidence and reports leaks that are not there." >&2
          usage; exit "${RC_USAGE}"
        fi
        mlsid_lines+="$2"$'\n'; shift 2 ;;
      --expect-mls-group-ids)
        # The lane's own count of what the drive announced, held against what
        # arrived. Independently produced (the drive prints a running count as
        # it announces; the ids travel a separate control channel into a
        # sidecar), which is the whole value: a needle set that silently shrank
        # leaves C5.8 looking exactly as busy over fewer values.
        [[ $# -ge 2 ]] || { echo "ERROR: --expect-mls-group-ids needs a value" >&2; usage; exit "${RC_USAGE}"; }
        if [[ ! "$2" =~ ^[0-9]+$ ]]; then
          echo "ERROR: --expect-mls-group-ids expects a non-negative integer, got: $2" >&2
          echo "       An unparsed count (an empty grep, a stray word) must not become" >&2
          echo "       a comparison that silently matches anything." >&2
          usage; exit "${RC_USAGE}"
        fi
        EXPECT_MLS_IDS="$2"; shift 2 ;;
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
    usage; exit "${RC_USAGE}"
  fi
  # The vacuity guard on C5.6: with no pool declared, every publish is
  # unbounded and the containment verdict would be an opinion.
  if [[ -z "${pool_lines}" ]]; then
    echo "ERROR: no --pool declared. C5.6 cannot bound a publish target without" >&2
    echo "       caller-supplied ground truth, and a containment check with no" >&2
    echo "       pools would report clean having compared nothing." >&2
    usage; exit "${RC_USAGE}"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "UNUSABLE: jq is not installed; the wire journal cannot be parsed." >&2
    exit "${RC_UNUSABLE}"
  fi

  local pools_json disc_json excl_json overlap
  pools_json="$(printf '%s' "${pool_lines}" | jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t"))
    | reduce .[] as $p ({}; .[$p[0]] = (((.[$p[0]] // []) + [$p[1]]) | unique))')"
  disc_json="$(printf '%s' "${disc_lines}" | jq -R -s '
    split("\n") | map(select(length > 0)) | unique')"
  excl_json="$(printf '%s' "${excl_lines}" | jq -R -s '
    split("\n") | map(select(length > 0)) | unique')"
  local idpk_json mlsid_json
  idpk_json="$(printf '%s' "${idpk_lines}" | jq -R -s '
    split("\n") | map(select(length > 0) | ascii_downcase) | unique')"
  mlsid_json="$(printf '%s' "${mlsid_lines}" | jq -R -s '
    split("\n") | map(select(length > 0) | ascii_downcase) | unique')"

  # A URL that is both a discovery relay and a publish target is a contradiction
  # in the caller's own model, and resolving it silently either way would make
  # the discovery rule or the pool rule dead. Refuse instead.
  overlap="$(jq -n --argjson p "${pools_json}" --argjson d "${disc_json}" '
    def canon: ascii_downcase | sub("^wss?://";"") | sub("^https?://";"") | sub("/+$";"");
    ($d | map(canon)) as $D
    | [ $p | to_entries[] | .key as $k | .value[] | select((. | canon) as $c | $D | index($c))
        | "kind \($k) -> \(.)" ] | join("; ")')"
  if [[ -n "${overlap}" && "${overlap}" != '""' ]]; then
    overlap="${overlap%\"}"; overlap="${overlap#\"}"
    if [[ -n "${overlap}" ]]; then
      echo "ERROR: a URL is declared BOTH as a --discovery-relay and inside a --pool:" >&2
      echo "       ${overlap}" >&2
      echo "       The discovery plane is never a publish target (haven-core/src/relay/" >&2
      echo "       discovery.rs:20-21). Declaring it as both would make one of the two" >&2
      echo "       rules dead, and this check exists because the discovery set is a" >&2
      echo "       strict superset of the account seed, so the confusion is easy to make." >&2
      usage; exit "${RC_USAGE}"
    fi
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
      echo "META-FLOOR: ${j} [no sentinel] — the token was never recorded, so the" >&2
      echo "            read cannot be anchored and a background wake could have" >&2
      echo "            appended to the file mid-check." >&2
      metafloor=1
      continue
    fi
    echo "wire-correlation: ${j} anchored at wire_seq ${boundary}" >&2
    normalize "${j}" "${boundary}" >> "${stream}"
  done

  if (( unusable )); then
    echo >&2
    echo "ERROR: the wire journal could not be checked (see UNUSABLE line(s) above)." >&2
    echo "       An absent, empty, truncated or gapped journal is NOT a clean one." >&2
    exit "${RC_UNUSABLE}"
  fi
  if (( metafloor )); then
    echo >&2
    echo "ERROR: the wire journal could not be anchored (see META-FLOOR line(s) above)." >&2
    exit "${RC_METAFLOOR}"
  fi

  # Declaring BOTH is a contradiction: one says "here is the ground truth",
  # the other says "no ground truth exists". Refusing is not pedantry -- the
  # silent resolution would be to honour the id and ignore the declaration,
  # which leaves a stale not-asserted token in the workflow claiming the
  # invariant is skipped while it is actually running.
  if [[ -n "${MLS_NOT_ASSERTED}" && -n "${mlsid_lines}" ]]; then
    echo "ERROR: --mls-group-id and --mls-group-id-not-asserted are mutually exclusive." >&2
    echo "       Supplying the id ASSERTS Security Rule 4; declaring the" >&2
    echo "       non-assertion says it cannot be asserted. Pick one." >&2
    exit "${RC_USAGE}"
  fi

  local verdict
  verdict="$(evaluate "${stream}" "${pools_json}" "${disc_json}" "${excl_json}" \
                      "${idpk_json}" "${mlsid_json}" "${MLS_NOT_ASSERTED}" \
                      "${EXPECT_MLS_IDS}")"

  local n_meta n_viol n_events
  n_meta="$(printf '%s' "${verdict}" | jq '.meta | length')"
  n_viol="$(printf '%s' "${verdict}" | jq '.violations | length')"
  n_events="$(printf '%s' "${verdict}" | jq '.summary.event_frames')"

  printf '%s' "${verdict}" | jq -r '
    "wire-correlation summary: \(.summary.unique_events) unique event(s) from " +
    "\(.summary.event_frames) EVENT frame(s) and \(.summary.req_frames) REQ frame(s); " +
    "445 total \(.summary.k445) (app \(.summary.k445_app) / commit \(.summary.k445_commit)) " +
    "over \(.summary.app_groups) app-publishing group(s); 1059 \(.summary.k1059); " +
    "\(.summary.h_filters) #h filter(s); \(.summary.sent_pairs) (event,endpoint) publish pair(s); " +
    "sent 445 \(.summary.sent_445) under \(.summary.sent_445_authors) distinct author key(s); " +
    "\(.summary.identity_keys) known identity key(s); \(.summary.mls_ids) declared MLS group id(s)" +
    # Named only when it RAN. A reader must never have to infer from a count
    # alone whether anything held it against the number of circles the run made.
    (if .summary.mls_ids_expected == null then " (completeness NOT cross-checked)"
     else " (lane announced \(.summary.mls_ids_expected) — cross-checked)" end) + "; " +
    "\(.summary.publishing_conns) publishing connection(s) of which \(.summary.multi_circle_conns) served >1 group; " +
    "\(.summary.excluded_conns) connection(s) excluded (\(.summary.harness_conns) self-declared harness); " +
    "endpoints \(.summary.endpoints)"' >&2

  # Printed before the findings, and never mapped to an exit code. An advisory
  # is what the oracle knows and deliberately does not assert; suppressing it
  # would make "we did not look" and "there was nothing to see" read the same.
  printf '%s' "${verdict}" | jq -r '.advisories[] | "advisory (NOT asserted): " + .' >&2

  if (( n_meta > 0 )); then
    printf '%s' "${verdict}" | jq -r '.meta[] | "META-FLOOR: " + .' >&2
  fi
  if (( n_viol > 0 )); then
    printf '%s' "${verdict}" | jq -r '.violations[] | "VIOLATION: " + .' >&2
  fi

  # PRECEDENCE, matching check-wire-journal.sh: a real finding outranks a thin
  # sample, EXCEPT when the snapshot is empty, where every "finding" would be
  # derivative of having no evidence at all.
  if (( n_events == 0 )); then
    echo >&2
    echo "ERROR: the sentinel-anchored snapshot contains NO events at all — this run" >&2
    echo "       proves nothing about what Haven put on the wire." >&2
    exit "${RC_METAFLOOR}"
  fi
  if (( n_viol > 0 )); then
    echo >&2
    echo "ERROR: ${n_viol} wire-correlation violation(s) — what Haven put on the relay" >&2
    echo "       is linkable, or reached a relay outside its kind's pool." >&2
    exit "${RC_VIOLATION}"
  fi
  if (( n_meta > 0 )); then
    echo >&2
    echo "ERROR: ${n_meta} precondition failure(s) — the journal is readable but one or" >&2
    echo "       more invariants never had anything to assert over, so their silence" >&2
    echo "       is not evidence. Fix the SCENARIO, not this file." >&2
    exit "${RC_METAFLOOR}"
  fi

  # The success banner must never name an invariant that did not run. A reader
  # greps exactly this line to conclude "green => the rule held", so listing
  # C5.8 here while an advisory three lines above says it was not scanned is a
  # false statement in the one place it does the most damage.
  if [[ -n "${MLS_NOT_ASSERTED}" ]]; then
    echo "wire-correlation: clean on EIGHT of nine — C5.1 per-publisher timestamp separation," \
         "C5.2 REQ-filter allow-list, C5.3 per-event 445 tag shape, C5.4 no g/alt," \
         "C5.5 1059 == {p}, C5.6 per-kind publish containment, C5.7 fresh ephemeral" \
         "445 author and C5.9 no p-tag on a 445 all hold, and all eight had a" \
         "non-empty sample. C5.8 (no real MLS group id on the wire) was NOT" \
         "ASSERTED — see the advisory above. This run is NOT evidence for" \
         "Security Rule 4."
  else
    echo "wire-correlation: clean — C5.1 per-publisher timestamp separation, C5.2 REQ-filter" \
         "allow-list, C5.3 per-event 445 tag shape, C5.4 no g/alt, C5.5 1059 == {p}," \
         "C5.6 per-kind publish containment, C5.7 fresh ephemeral 445 author," \
         "C5.8 no real MLS group id on the wire and C5.9 no p-tag on a 445 all hold," \
         "and all nine had a non-empty sample."
  fi
  exit "${RC_CLEAN}"
}

# ---------------------------------------------------------------------------
# Self-test. Hermetic: pure bash + jq, no network, no toolchain, no relay.
#
# Every invariant gets BOTH halves demanded by the charter:
#   * a fixture proving it goes red on the leak it guards, and
#   * a fixture proving it goes red (META-FLOOR) on an EMPTY relevant subset,
#     because an assertion that cannot tell "held" from "never ran" is the
#     failure mode this whole workstream exists to remove.
# ---------------------------------------------------------------------------

CASES_RUN=0

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

# expect_msg <substring> <description> <args...> — the verdict must NAME the
# inference. A guard whose message says "unexpected tag" tells a reader nothing
# about why it matters, and these messages are the deliverable as much as the
# exit code is, so they are asserted rather than assumed.
expect_msg() {
  local needle="$1" desc="$2"
  shift 2
  local out
  CASES_RUN=$(( CASES_RUN + 1 ))
  out="$(bash "${SELF_PATH}" "$@" 2>&1 || true)"
  if ! printf '%s' "${out}" | grep -qF -- "${needle}"; then
    echo "SELF-TEST FAIL: ${desc} — verdict did not contain: ${needle}" >&2
    return 1
  fi
  return 0
}

# expect_no_msg <substring> <description> <args...> — the verdict must NOT name
# this inference. Needed for two things nothing else in this file can express:
# that a send-side rule stayed SILENT on inbound traffic (an absence, which
# `expect_rc` cannot distinguish from a rule that is simply switched off), and
# that C5.9's named diagnosis is genuinely its own — a `p` tag on a 445 also
# trips C5.3, so a red exit code proves nothing about which rule spoke.
#
# The run must have reached `evaluate` for the absence to mean anything. A
# usage error, a missing journal or a syntax error would all produce output
# containing no needle, and the assertion would pass having proven that the
# oracle never ran. The summary line is emitted immediately after `evaluate`
# returns, so requiring it is what turns "did not say it" into "looked and did
# not say it".
expect_no_msg() {
  local needle="$1" desc="$2"
  shift 2
  local out
  CASES_RUN=$(( CASES_RUN + 1 ))
  out="$(bash "${SELF_PATH}" "$@" 2>&1 || true)"
  if ! printf '%s' "${out}" | grep -qF -- "wire-correlation summary:"; then
    echo "SELF-TEST FAIL: ${desc} — the oracle never reached evaluate(), so the" >&2
    echo "  absence of \"${needle}\" proves nothing." >&2
    return 1
  fi
  if printf '%s' "${out}" | grep -qF -- "${needle}"; then
    echo "SELF-TEST FAIL: ${desc} — verdict contained what it must not: ${needle}" >&2
    return 1
  fi
  return 0
}

# ---- fixture builders -----------------------------------------------------
# `wire_seq` is stamped by the builder. Hand-numbering would make a fixture's
# own sequence a source of accidental UNUSABLE verdicts and mask its subject.

FIXTURE_SEQ=0
FIXTURE_FILE=""
FIXTURE_UP=""
FIXTURE_LISTEN=""

fx_begin() {
  FIXTURE_FILE="$1"; FIXTURE_SEQ=0
  FIXTURE_UP="${2:-ws://127.0.0.1:7777}"
  FIXTURE_LISTEN="${3:-127.0.0.1:7788}"
  : > "${FIXTURE_FILE}"
}

# jline <dir> <conn> <frame-json> [upstream] [listen]
# Emits a line in C1's REAL shape (type + relay_url + listen), because that is
# what a production journal looks like — a fixture in a shape the recorder does
# not emit would certify the wrong thing.
jline() {
  local dir="$1" conn="$2" frame="$3"
  local up="${4:-${FIXTURE_UP}}" lst="${5:-${FIXTURE_LISTEN}}"
  printf '{"wire_seq":%d,"type":"frame","conn_id":"%s","ts_ms":%d,"dir":"%s","relay_url":"%s","listen":"%s","frame":%s,"raw_len":%d}\n' \
    "${FIXTURE_SEQ}" "${conn}" $(( 1785886144000 + FIXTURE_SEQ )) "${dir}" "${up}" "${lst}" "${frame}" "${#frame}" \
    >> "${FIXTURE_FILE}"
  FIXTURE_SEQ=$(( FIXTURE_SEQ + 1 ))
}

# jline_bare <dir> <conn> <frame-json> — the bare contract shape: no `type`, no
# `relay_url`, no `listen`. Endpoint resolution must fall back to `conn_open`.
jline_bare() {
  local dir="$1" conn="$2" frame="$3"
  printf '{"wire_seq":%d,"conn_id":"%s","ts_ms":%d,"dir":"%s","frame":%s,"raw_len":%d}\n' \
    "${FIXTURE_SEQ}" "${conn}" $(( 1785886144000 + FIXTURE_SEQ )) "${dir}" "${frame}" "${#frame}" \
    >> "${FIXTURE_FILE}"
  FIXTURE_SEQ=$(( FIXTURE_SEQ + 1 ))
}

# jopen <conn> [upstream] [listen] — a conn_open lifecycle record.
jopen() {
  local conn="$1" up="${2:-${FIXTURE_UP}}" lst="${3:-${FIXTURE_LISTEN}}"
  printf '{"wire_seq":%d,"type":"conn_open","conn_id":"%s","ts_ms":%d,"relay_url":"%s","listen":"%s"}\n' \
    "${FIXTURE_SEQ}" "${conn}" $(( 1785886144000 + FIXTURE_SEQ )) "${up}" "${lst}" \
    >> "${FIXTURE_FILE}"
  FIXTURE_SEQ=$(( FIXTURE_SEQ + 1 ))
}

# ev <kind> <id> <pubkey> <tags-json> [created_at]
ev() {
  printf '{"id":"%s","kind":%s,"pubkey":"%s","created_at":%s,"tags":%s,"content":"","sig":"%s"}' \
    "$2" "$1" "$3" "${5:-1785886144}" "$4" "$(printf 'f%.0s' {1..128})"
}

renumber() {
  jq -c -n '[inputs] | to_entries | map(.value.wire_seq = .key | .value) | .[]' -- "$1" > "$2"
}

readonly PK_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly PK_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
readonly PK_EPH1="1111111111111111111111111111111111111111111111111111111111111111"
readonly PK_EPH2="2222222222222222222222222222222222222222222222222222222222222222"
readonly PK_EPH3="3333333333333333333333333333333333333333333333333333333333333333"
readonly PK_EPH4="4444444444444444444444444444444444444444444444444444444444444444"
# Kept distinct from PK_EPH1-4 on purpose: C5.7 forbids one ephemeral key from
# signing two kind-445s, so a fixture that reuses a key the healthy base
# already spent would go red on C5.7 while claiming to be about something else.
readonly PK_EPH5="5555555555555555555555555555555555555555555555555555555555555555"
readonly PK_EPH6="6666666666666666666666666666666666666666666666666666666666666666"
readonly PK_EPH7="7777777777777777777777777777777777777777777777777777777777777777"
readonly PK_EPH8="8888888888888888888888888888888888888888888888888888888888888888"
readonly PK_EPH9="9999999999999999999999999999999999999999999999999999999999999999"
readonly SENTINEL="HAVEN_WIRE_SENTINEL:corrselftest01"

# Two circles' hex nostr_group_ids.
readonly H1="cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"
readonly H2="d00dfeedd00dfeedd00dfeedd00dfeedd00dfeedd00dfeedd00dfeedd00dfeed"
readonly H3="beefcafebeefcafebeefcafebeefcafebeefcafebeefcafebeefcafebeefcafe"

# The two circles' REAL MLS group ids — the values C5.8 requires to be absent.
# Deliberately unrelated to H1/H2 and to each other: the whole point of
# Security Rule 4 is that the routing handle and the real id are different
# values, and a fixture whose two ids shared a prefix would let a substring
# scan pass by accident on the wrong one.
readonly MLS1="7a1c93e05b48d2f6a0e17c4b9d3f8265aa11bb22cc33dd44ee55ff6600778899"
readonly MLS2="3f8e2d1c0b9a8776655443322110ffeeddccbbaa99887766554433221100aabb"

readonly RELAY_A="ws://127.0.0.1:7777"
readonly RELAY_B="ws://127.0.0.1:7779"
readonly DISCOVERY="ws://127.0.0.1:7999"

# The real kind-30443 tag set, copied from
# haven-core/src/relay/maintenance/key_package.rs:479-486.
readonly KP_TAGS='[["d","haven-kp-0"],["mls_protocol_version","1.0"],["i","0001"],["mls_ciphersuite","0x0001"],["mls_extensions","0x0002"],["mls_proposals","0x0003"],["app_components","0x8005"]]'

# The sentinel exchange the recorder actually performs: the drive emits
# `["HAVEN_WIRE_SENTINEL", <token>]` (never forwarded upstream) and the proxy
# answers `["HAVEN_WIRE_SENTINEL_ACK", <token>, <wire_seq>, <conn_id>]`. Shapes
# copied from `tooling/e2e/local-relay/src/frame.rs:51,64,137-146`. An invented
# shape here would let C5.2's filter allow-list reject the real marker while
# the self-test stayed green — the unfaithful-test-double trap.
sentinel_frame() {
  printf '["HAVEN_WIRE_SENTINEL","%s"]' "${SENTINEL}"
}

# emit_sentinel <conn> [bare] — ONLY the client→relay marker.
#
# Fixtures emit it on `c0`, a connection that carries NOTHING ELSE, because
# that is the real topology: the marker comes off the drive's own `TestRelay`
# socket (`TestRelay._declareHarnessSocket` / `emitWireJournalSentinel`), never
# off the relay client the app under test publishes through. Emitting it on the
# publishing connection — as these fixtures did while the sentinel was only an
# anchor — now declares that connection a HARNESS socket and drops every event
# on it from attribution, which is the correct reading of that journal and the
# wrong shape for a fixture about the app.
#
# The proxy's `HAVEN_WIRE_SENTINEL_ACK` is deliberately NOT emitted here: the
# ack is generated by the proxy and pushed straight onto the client sink
# (`tooling/e2e/local-relay/src/proxy.rs:339-345` sends it via `client_tx`),
# so it never passes through either recording pump and never reaches
# `journal.record`. A fixture containing an ack line would be an unfaithful
# double — it would certify this oracle against a journal shape the recorder
# cannot produce, which is how a self-test comes to prove something other than
# what it claims.
emit_sentinel() {
  local conn="$1" bare="${2:-}"
  if [[ -n "${bare}" ]]; then
    jline_bare c2r "${conn}" "$(sentinel_frame)"
  else
    jline c2r "${conn}" "$(sentinel_frame)"
  fi
}

# emit_declaration <conn> — a HARNESS-SOCKET DECLARATION, verbatim.
#
# Same intercepted verb, deliberately NOT the run's token
# (`TestRelay._harnessSocketDeclaration`). Attribution keys on the verb; the
# payload is what keeps a declaration from answering for the snapshot boundary
# or for a pending sentinel ack.
emit_declaration() {
  jline c2r "$1" '["HAVEN_WIRE_SENTINEL","HAVEN_WIRE_CONN"]'
}

# write_healthy <path> — a journal a healthy two-circle scenario produces.
#
# Deliberately contains every shape that would break a naive oracle:
#   * the SAME event id on two relays and echoed to a subscriber (a multiset
#     assertion would trip);
#   * a commit carrying `h` alone beside an application message carrying
#     `h`+`expiration` (C5.3 needs BOTH arms present);
#   * TWO circles each publishing an application message, at DIFFERENT
#     created_at (C5.1's precondition met, its assertion held);
#   * a multiplexed two-value `#h` REQ (C5.2's accepted shape);
#   * a REQ to the discovery relay, and no EVENT to it (C5.6's read-only rule).
write_healthy() {
  fx_begin "$1"
  jopen c1
  jopen c2
  jline c2r c1 "[\"EVENT\",$(ev 0 "e00" "${PK_A}" '[]')]"
  jline r2c c1 '["OK","e00",true,""]'
  jline c2r c1 "[\"EVENT\",$(ev 10002 "e02" "${PK_A}" "[[\"r\",\"${RELAY_A}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev 10050 "e03" "${PK_A}" "[[\"relay\",\"${RELAY_A}\"]]")]"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c2 "[\"EVENT\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline c2r c1 "[\"REQ\",\"sub-kp\",{\"kinds\":[30443],\"authors\":[\"${PK_B}\"],\"limit\":5}]"
  jline r2c c1 "[\"EVENT\",\"sub-kp\",$(ev 30443 "e05" "${PK_B}" "${KP_TAGS}")]"
  jline r2c c1 '["EOSE","sub-kp"]'
  # Read-only discovery query: REQ yes, EVENT never.
  jopen c8 "${DISCOVERY}" "127.0.0.1:7998"
  jline c2r c8 "[\"REQ\",\"sub-disc\",{\"kinds\":[10002],\"authors\":[\"${PK_B}\"],\"limit\":1}]" "${DISCOVERY}" "127.0.0.1:7998"
  jline r2c c8 '["EOSE","sub-disc"]' "${DISCOVERY}" "127.0.0.1:7998"
  # Invitation.
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  # The multiplexed group-plane REQ: two circles, one filter, one relay set.
  jline c2r c1 "[\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"],\"since\":1785886000}]"
  # Circle 1: a commit (`h` only) and an application message (`h`+expiration).
  jline c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"]]" 1785886100)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  # Circle 2: an application message at a DIFFERENT second.
  jline c2r c1 "[\"EVENT\",$(ev 445 "e10" "${PK_EPH3}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  # The same event, published to a second relay and echoed to a subscriber.
  jline c2r c2 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  jline r2c c2 "[\"EVENT\",\"sub-h\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  jline c2r c1 '["CLOSE","sub-kp"]'
  emit_sentinel c0
}

# The pools every fixture below is judged against. 445/1059/30443/0/10002/10050
# are each scoped to their own plane, exactly as C5.6 requires.
pool_args() {
  printf '%s\n' \
    --pool "445=${RELAY_A},${RELAY_B}" \
    --pool "1059=${RELAY_A},${RELAY_B}" \
    --pool "30443=${RELAY_A}" \
    --pool "0=${RELAY_A}" \
    --pool "10002=${RELAY_A}" \
    --pool "10050=${RELAY_A}"
}

# The caller-supplied ground truth every fixture below is judged against:
# both accounts' identity keys (C5.7) and both circles' real MLS group ids
# (C5.8).
#
# The identity keys are declared even though the healthy fixture also PUTS
# them on the wire (as kind-0/10002/10050/30443 authors), so the derived set
# and the declared set agree. That is on purpose: several fixtures below are
# minimal journals carrying only 445s and a 1059, which contain no
# identity-signed event at all, and without the declaration those would
# META-FLOOR on C5.7's identity arm for a reason that has nothing to do with
# what they exist to prove. The derived path is exercised on its own by the
# `c57noid` fixture, which declares nothing and relies on the journal alone.
id_args() {
  printf '%s\n' \
    --identity-pubkey "${PK_A}" \
    --identity-pubkey "${PK_B}" \
    --mls-group-id "${MLS1}" \
    --mls-group-id "${MLS2}"
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

  local -a POOLS=()
  while IFS= read -r a; do POOLS+=("${a}"); done < <(pool_args)
  local -a IDS=()
  while IFS= read -r a; do IDS+=("${a}"); done < <(id_args)
  local -a base=(--sentinel "${SENTINEL}" "${POOLS[@]}" --discovery-relay "${DISCOVERY}" "${IDS[@]}")

  # -------------------------------------------------------------------------
  # POSITIVE CONTROL. Without it an oracle hard-coded to red looks correct on
  # every fixture below.
  # -------------------------------------------------------------------------
  local healthy="${tmp}/healthy.ndjson"
  write_healthy "${healthy}"
  expect_rc 0 "healthy two-circle journal passes" --journal "${healthy}" "${base[@]}" || fail=1

  # THE MULTISET TRAP, with a journal of its own rather than a second run of
  # the positive control. e09 is re-sent and re-echoed until this journal's
  # multiset and its SET differ by four frames — the shape a real lane produces
  # when an event is published to several relays and returned to several
  # subscriptions. A body-keyed de-dup collapses all of them; any assertion
  # that ever counts instead of setting reds here, and this is the only
  # fixture that would tell it apart from the positive control.
  local multiset="${tmp}/multiset.ndjson"
  write_healthy "${multiset}"
  local e09body
  e09body="$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)"
  jline c2r c1 "[\"EVENT\",${e09body}]"
  jline c2r c2 "[\"EVENT\",${e09body}]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",${e09body}]"
  jline r2c c2 "[\"EVENT\",\"sub-h\",${e09body}]"
  emit_sentinel c0
  expect_rc 0 "one event repeated across connections and subscriptions de-duplicates to one" \
    --journal "${multiset}" "${base[@]}" || fail=1

  # ...and de-duplication must never HIDE a finding. `id` is journal DATA: a
  # value the publishing client chose, which nothing in this file checks
  # against the body it labels, so a hostile or buggy client controls it. Two
  # DIFFERENT bodies under ONE id — a clean application 445, then one carrying
  # a second `h`, a `g` and an `alt` — is the shape that turns a determinism
  # fix into a blindfold: keyed on the id alone, the clean body arrives first,
  # survives the collapse, and answers for the other. C5.3 and C5.4 both go
  # blind at once, four findings deleted by the de-dup rather than by any
  # assertion being wrong.
  local idcollision="${tmp}/id-collision.ndjson"
  write_healthy "${idcollision}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eDUP" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886500\"]]" 1785886200)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eDUP" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"h\",\"${H2}\"],[\"g\",\"u4pru\"],[\"alt\",\"Encrypted group message\"]]" 1785886200)]"
  emit_sentinel c0
  expect_rc 1 "two bodies under one event id are both checked, not collapsed" \
    --journal "${idcollision}" "${base[@]}" || fail=1
  expect_msg 'carried 2 `h` tags' \
    "the second body under a shared id is reached by C5.3, not answered for by the first" \
    --journal "${idcollision}" "${base[@]}" || fail=1
  expect_msg 'C5.4 forbidden tag: a kind-445 event carried a `g` tag' \
    "the second body under a shared id is reached by C5.4 as well" \
    --journal "${idcollision}" "${base[@]}" || fail=1

  # The de-dup key's KIND component, isolated. Two frames agreeing on id,
  # pubkey, created_at and tags but not on kind: a kind-0 first, then a gift
  # wrap naming TWO recipients. Drop `kind` from the key and the kind-0
  # survives, the 1059 is merged into it, and C5.5 never sees the two-`p`
  # wrap — while its PRECONDITION stays satisfied by the healthy fixture's own
  # gift wrap, so the run reports clean rather than META-FLOOR. That is the
  # dangerous shape: a hidden finding wearing a met precondition.
  local kindcollapse="${tmp}/id-collision-kind.ndjson"
  write_healthy "${kindcollapse}"
  jline c2r c1 "[\"EVENT\",$(ev 0 "eGHOST" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"],[\"p\",\"${PK_A}\"]]" 1785886210)]"
  jline c2r c1 "[\"EVENT\",$(ev 1059 "eGHOST" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"],[\"p\",\"${PK_A}\"]]" 1785886210)]"
  emit_sentinel c0
  expect_rc 1 "a gift wrap sharing everything but its KIND with another event is still checked" \
    --journal "${kindcollapse}" "${base[@]}" || fail=1
  expect_msg 'carried 2 `p` tags' \
    "C5.5 reaches the 1059, not the kind-0 that shares its id" \
    --journal "${kindcollapse}" "${base[@]}" || fail=1

  # The de-dup key's CREATED_AT component, isolated, and the one that guards
  # C5.1 directly. Two 445s agreeing on id, kind, pubkey and tags, differing
  # only in `created_at` (identical `expiration` included, or the difference
  # would be in the tags and this fixture would prove the tag component over
  # again) — the second landing on the same second as the
  # healthy fixture's OTHER circle. Drop `created_at` from the key and the
  # innocent timestamp survives, the colliding one is merged away, and the
  # correlation C5.1 exists to find is deleted by the de-dup.
  local tscollapse="${tmp}/id-collision-created-at.ndjson"
  write_healthy "${tscollapse}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eTS" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886389\"]]" 1785886200)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eTS" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  emit_sentinel c0
  expect_rc 1 "a 445 sharing everything but its CREATED_AT with another event is still checked" \
    --journal "${tscollapse}" "${base[@]}" || fail=1
  expect_msg "at the same created_at (1785886161" \
    "C5.1 reaches the colliding timestamp, not the innocent one that shares its id" \
    --journal "${tscollapse}" "${base[@]}" || fail=1

  # -------------------------------------------------------------------------
  # UNUSABLE (rc 3) — the recorder broke.
  # -------------------------------------------------------------------------
  local absent="${tmp}/never-written.ndjson"
  local empty="${tmp}/empty.ndjson"
  local truncated="${tmp}/truncated.ndjson"
  local gapped="${tmp}/gapped.ndjson"

  : > "${empty}"
  head -c $(( $(wc -c < "${healthy}") - 40 )) "${healthy}" > "${truncated}"
  grep -v '"wire_seq":5,' "${healthy}" > "${gapped}"

  expect_rc 3 "absent journal"              --journal "${absent}"    "${base[@]}" || fail=1
  expect_rc 3 "empty journal"               --journal "${empty}"     "${base[@]}" || fail=1
  expect_rc 3 "journal truncated mid-line"  --journal "${truncated}" "${base[@]}" || fail=1
  expect_rc 3 "journal with a dropped line" --journal "${gapped}"    "${base[@]}" || fail=1
  expect_rc 3 "one good journal never vouches for a missing one" \
    --journal "${healthy}" --journal "${absent}" "${base[@]}" || fail=1

  # A `conn_open` record carries no `dir` BY DESIGN (journal.rs Record types).
  # The healthy fixture contains three of them, so this is already proven by
  # the positive control — pinned explicitly because the sibling oracle's
  # well-formedness gate demands `dir` unconditionally and would report every
  # real journal UNUSABLE.
  if ! grep -aq '"type":"conn_open"' "${healthy}"; then
    echo "SELF-TEST FAIL: the healthy fixture no longer contains a conn_open record," >&2
    echo "  so it no longer proves that a dir-less lifecycle line is well-formed." >&2
    fail=1
  fi

  # -------------------------------------------------------------------------
  # META-FLOOR (rc 4) — anchoring.
  # -------------------------------------------------------------------------
  local nosentinel="${tmp}/nosentinel.ndjson"
  grep -v 'HAVEN_WIRE_SENTINEL' "${healthy}" > "${tmp}/nosentinel.raw"
  renumber "${tmp}/nosentinel.raw" "${nosentinel}"
  expect_rc 4 "journal with no sentinel cannot be anchored" \
    --journal "${nosentinel}" "${base[@]}" || fail=1

  # The sentinel actually truncates: a violation ABOVE the boundary — exactly
  # what a background wake appends mid-read — must not be seen.
  local afterSentinel="${tmp}/after-sentinel.ndjson"
  write_healthy "${afterSentinel}"
  jline c2r c9 "[\"EVENT\",$(ev 445 "eLATE" "${PK_EPH4}" "[[\"h\",\"${H3}\"],[\"g\",\"u4pru\"]]" 1785886144)]"
  expect_rc 0 "a violation ABOVE the sentinel is outside the snapshot" \
    --journal "${afterSentinel}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.1 — created_at collision
  # =========================================================================
  # THE LEAK: two circles' application messages in the same second. This is the
  # shape `location_sharing_provider.dart`'s `Future.wait` and
  # `background_location_task.dart`'s shared `_dueTracker` seed produce today.
  local c51leak="${tmp}/c51-leak.ndjson"
  write_healthy "${c51leak}"
  fx_begin "${c51leak}.tmp"
  jq -c 'if (.frame | tostring | test("e10")) then
           .frame = (.frame | map(if (type == "object" and .kind == 445)
                                  then .created_at = 1785886144 else . end))
         else . end' "${c51leak}" > "${c51leak}.tmp"
  mv "${c51leak}.tmp" "${c51leak}"
  expect_rc 1 "C5.1 two circles publishing in the SAME second is a violation" \
    --journal "${c51leak}" "${base[@]}" || fail=1
  expect_msg "co-membership edge" "C5.1 names the inference, not the field" \
    --journal "${c51leak}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, first form: only one circle ever published an application
  # message, so a collision could not have been observed.
  local c51one="${tmp}/c51-one-circle.ndjson"
  jq -c 'select((.frame | tostring | test("e10")) | not)' "${healthy}" > "${tmp}/c51one.raw"
  renumber "${tmp}/c51one.raw" "${c51one}"
  expect_rc 4 "C5.1 precondition: one app-publishing circle proves nothing" \
    --journal "${c51one}" "${base[@]}" || fail=1

  # THE ANTI-VACUITY TRAP, and the reason the precondition is not ">=2 distinct
  # h": circle 2 emits only a COMMIT. A naive floor counting distinct `h` over
  # all 445s sees two groups and passes; commits carry no inner timestamp and
  # keep the wrap-time default (peeler.rs:166), so this journal proves nothing
  # about the binding. It MUST be a META-FLOOR.
  local c51commitonly="${tmp}/c51-commit-only.ndjson"
  jq -c 'if (.frame | tostring | test("e10")) then
           .frame = (.frame | map(if (type == "object" and .kind == 445)
                                  then .tags = [.tags[0]] else . end))
         else . end' "${healthy}" > "${c51commitonly}"
  expect_rc 4 "C5.1 anti-vacuity: a second group present only as a COMMIT is not a sample" \
    --journal "${c51commitonly}" "${base[@]}" || fail=1
  expect_msg "peeler.rs:166" "C5.1 precondition cites why commits do not count" \
    --journal "${c51commitonly}" "${base[@]}" || fail=1

  # TWO DEVICES, ONE SECOND — the false finding this invariant used to
  # manufacture. Two SEPARATE connections publish to two different circles at
  # the same created_at. No device served both, so there is no co-membership
  # edge to infer and this must NOT be a violation. The healthy base still
  # supplies a connection (c1) that served two circles, so the precondition is
  # met and the clean verdict is a real one rather than an empty sample.
  local c51two="${tmp}/c51-two-devices.ndjson"
  write_healthy "${c51two}"
  jopen c3
  jopen c4
  jline c2r c3 "[\"EVENT\",$(ev 445 "eDEV1" "${PK_EPH5}" "[[\"h\",\"${H3}\"],[\"expiration\",\"1785886500\"]]" 1785886228)]"
  jline c2r c4 "[\"EVENT\",$(ev 445 "eDEV2" "${PK_EPH6}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886500\"]]" 1785886228)]"
  emit_sentinel c0
  expect_rc 0 "C5.1 two DIFFERENT devices coinciding in one second is not a finding" \
    --journal "${c51two}" "${base[@]}" || fail=1
  expect_no_msg "C5.1 timestamp correlation" \
    "C5.1 examined the coincidence and stayed silent rather than being switched off" \
    --journal "${c51two}" "${base[@]}" || fail=1

  # ...and the same two events on ONE connection still are. Same second, same
  # two circles, one publisher: this is the leak, and the per-connection
  # partition must not have blunted it.
  local c51same="${tmp}/c51-one-device.ndjson"
  write_healthy "${c51same}"
  jopen c3
  jline c2r c3 "[\"EVENT\",$(ev 445 "eDEV1" "${PK_EPH5}" "[[\"h\",\"${H3}\"],[\"expiration\",\"1785886500\"]]" 1785886228)]"
  jline c2r c3 "[\"EVENT\",$(ev 445 "eDEV2" "${PK_EPH6}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886500\"]]" 1785886228)]"
  emit_sentinel c0
  expect_rc 1 "C5.1 ONE device publishing to two circles in one second is still a violation" \
    --journal "${c51same}" "${base[@]}" || fail=1
  expect_msg "connection c3" "C5.1 names the publisher it attributed the collision to" \
    --journal "${c51same}" "${base[@]}" || fail=1

  # INBOUND: two groups delivered to a subscriber in one second. An r2c frame is
  # the RELAY's output — its timing is the relay's, not Haven's — so C5.1 must
  # be silent, and provably silent rather than merely outvoted.
  local c51in="${tmp}/c51-inbound.ndjson"
  write_healthy "${c51in}"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eIN1" "${PK_EPH7}" "[[\"h\",\"${H3}\"],[\"expiration\",\"1785886500\"]]" 1785886229)]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eIN2" "${PK_EPH8}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886500\"]]" 1785886229)]"
  emit_sentinel c0
  expect_rc 0 "C5.1 two inbound 445s in one second are the relay's output, not Haven's" \
    --journal "${c51in}" "${base[@]}" || fail=1
  expect_no_msg "C5.1 timestamp correlation" \
    "C5.1 read the inbound pair and stayed silent rather than being switched off" \
    --journal "${c51in}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, second form — the one the per-connection partition
  # introduces. Two circles DID publish application messages, but never the
  # same device, so no run of this scenario could have exhibited the leak. A
  # journal-wide ">=2 app-publishing groups" floor would call this a sample;
  # it is not one, and it must META-FLOOR.
  local c51split="${tmp}/c51-split-devices.ndjson"
  jq -c 'if (.frame | tostring | test("e10")) then .conn_id = "c6" else . end' \
    "${healthy}" > "${c51split}"
  expect_rc 4 "C5.1 precondition: two circles served by two different devices is not a sample" \
    --journal "${c51split}" "${base[@]}" || fail=1
  expect_msg "no single connection PUBLISHED" \
    "C5.1 names the per-device floor rather than reporting a journal-wide one" \
    --journal "${c51split}" "${base[@]}" || fail=1

  # THE ATTRIBUTION LIMIT, declared rather than hidden: two circles whose 445s
  # reached DISJOINT relay sets can never share a connection, so a co-timed
  # pair would land in two partitions and go unseen. That is not a pass.
  local c51disjoint="${tmp}/c51-disjoint-relays.ndjson"
  write_healthy "${c51disjoint}"
  jopen c5 "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c5 "[\"EVENT\",$(ev 445 "eFAR" "${PK_EPH9}" "[[\"h\",\"${H3}\"],[\"expiration\",\"1785886500\"]]" 1785886231)]" "${RELAY_B}" "127.0.0.1:7790"
  emit_sentinel c0
  expect_rc 4 "C5.1 refuses to report clean when two groups' relay sets are disjoint" \
    --journal "${c51disjoint}" "${base[@]}" || fail=1
  expect_msg "DISJOINT relay sets" "C5.1 names the pairs its partition cannot see" \
    --journal "${c51disjoint}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.2 — REQ-filter allow-list
  # =========================================================================
  # THE ACCEPTED SHAPE is in the healthy fixture (two `#h`, one relay set), so
  # the positive control already proves it is not rejected. Pin it explicitly:
  if ! grep -aq "\"#h\":\[\"${H1}\",\"${H2}\"\]" "${healthy}"; then
    echo "SELF-TEST FAIL: the healthy fixture no longer carries a multiplexed two-value" >&2
    echo "  #h REQ, so it no longer proves the ACCEPTED group-plane shape passes." >&2
    fail=1
  fi

  # THE LEAK, form 1: a multi-author filter.
  local c52auth="${tmp}/c52-authors.ndjson"
  jq -c "if (.frame | tostring | test(\"sub-kp\\\\\\\"\")) and ((.frame | tostring | test(\"REQ\"))) then
           .frame = [\"REQ\",\"sub-kp\",{\"kinds\":[30443],\"authors\":[\"${PK_A}\",\"${PK_B}\"],\"limit\":5}]
         else . end" "${healthy}" > "${c52auth}"
  expect_rc 1 "C5.2 a two-author filter is a social-graph disclosure" \
    --journal "${c52auth}" "${base[@]}" || fail=1
  expect_msg "k-clique" "C5.2 names the clique inference, not the field name" \
    --journal "${c52auth}" "${base[@]}" || fail=1

  # THE LEAK, form 2: a two-value `#p` filter.
  local c52p="${tmp}/c52-p.ndjson"
  jq -c "if (.frame | tostring | test(\"sub-kp\")) and (.frame[0] == \"REQ\") then
           .frame = [\"REQ\",\"sub-kp\",{\"kinds\":[1059],\"#p\":[\"${PK_A}\",\"${PK_B}\"],\"limit\":50}]
         else . end" "${healthy}" > "${c52p}"
  expect_rc 1 "C5.2 a two-recipient #p filter is a correspondence-set disclosure" \
    --journal "${c52p}" "${base[@]}" || fail=1
  expect_msg "correspondence set" "C5.2 names the correspondence-set inference" \
    --journal "${c52p}" "${base[@]}" || fail=1

  # THE LEAK, form 3: the accepted multi-`#h` shape joined to a SINGLE author.
  # Single-valued, so neither the multi-author nor the multi-`#p` rule fires —
  # this fixture exercises the join rule and nothing else, which is the only
  # way to prove that rule is alive. One author is enough: it puts a NAME on a
  # partition the relay could otherwise only see as opaque group ids.
  local c52join="${tmp}/c52-join.ndjson"
  jq -c "if (.frame | tostring | test(\"sub-h\")) and (.frame[0] == \"REQ\") then
           .frame = [\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"],\"authors\":[\"${PK_A}\"]}]
         else . end" "${healthy}" > "${c52join}"
  expect_rc 1 "C5.2 the accepted #h shape may not be joined to an identity, even a single one" \
    --journal "${c52join}" "${base[@]}" || fail=1
  expect_msg "attaches names to a partition" "C5.2 names the join inference" \
    --journal "${c52join}" "${base[@]}" || fail=1

  # THE LEAK, form 3: a filter spanning two relay sets. Circle 3 is subscribed
  # ONLY at relay B; merging it into relay A's multiplexed filter tells relay A
  # about a circle it does not serve.
  local c52span="${tmp}/c52-span.ndjson"
  write_healthy "${c52span}"
  jopen c5 "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c5 "[\"REQ\",\"sub-b\",{\"kinds\":[445],\"#h\":[\"${H3}\"],\"since\":1785886000}]" "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c1 "[\"REQ\",\"sub-h2\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H3}\"],\"since\":1785886000}]"
  emit_sentinel c0
  expect_rc 1 "C5.2 a filter merging two relay sets is a violation" \
    --journal "${c52span}" "${base[@]}" || fail=1
  expect_msg "DIFFERENT relay routing" "C5.2 names the relay-set widening" \
    --journal "${c52span}" "${base[@]}" || fail=1

  # ...and the same two circles on the SAME relay set must NOT red, or the rule
  # would forbid the design it exists to permit. Circles 1 and 2 are routed to
  # BOTH relays, so the multiplexed filter is identical on each and neither
  # relay learns anything the other does not already serve.
  local c52ok="${tmp}/c52-ok.ndjson"
  write_healthy "${c52ok}"
  jopen c5 "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c5 "[\"REQ\",\"sub-b\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"],\"since\":1785886000}]" "${RELAY_B}" "127.0.0.1:7790"
  emit_sentinel c0
  expect_rc 0 "C5.2 two circles sharing a relay set multiplex legitimately over two relays" \
    --journal "${c52ok}" "${base[@]}" || fail=1

  # THE LEAK, form 4: the accepted `#h` set, widened to a second event class.
  # No identity field, so only the kind rule can fire.
  local c52kinds="${tmp}/c52-kinds.ndjson"
  jq -c "if (.frame | tostring | test(\"sub-h\")) and (.frame[0] == \"REQ\") then
           .frame = [\"REQ\",\"sub-h\",{\"kinds\":[445,1059],\"#h\":[\"${H1}\",\"${H2}\"]}]
         else . end" "${healthy}" > "${c52kinds}"
  expect_rc 1 "C5.2 the accepted #h shape may not be widened past kind 445" \
    --journal "${c52kinds}" "${base[@]}" || fail=1

  # THE LEAK, form 4b: the SAME widening, expressed by omission. Under NIP-01 a
  # filter constrains only on the fields it names, so a filter with no `kinds`
  # matches EVERY kind — strictly broader than form 4 above, and the form that
  # reads as innocent because the widening is a field that is not there. Any
  # default other than "every kind" reads the broadest filter expressible as
  # the narrowest shape this file blesses, which is fail-OPEN on the one axis
  # a REQ widens without adding a character to the frame.
  local c52nokinds="${tmp}/c52-no-kinds.ndjson"
  jq -c "if (.frame | tostring | test(\"sub-h\")) and (.frame[0] == \"REQ\") then
           .frame = [\"REQ\",\"sub-h\",{\"#h\":[\"${H1}\",\"${H2}\"]}]
         else . end" "${healthy}" > "${c52nokinds}"
  expect_rc 1 "C5.2 a multi-#h filter with NO kinds subscribes to every kind and is refused" \
    --journal "${c52nokinds}" "${base[@]}" || fail=1
  expect_msg "matches every kind under NIP-01" \
    "C5.2 reads an absent kinds at its WIDEST, and says so" \
    --journal "${c52nokinds}" "${base[@]}" || fail=1

  # ...and `kinds: []` the same way, for a different reason: NIP-01 reads it as
  # a condition no kind satisfies, but relay implementations disagree on
  # whether an empty list constrains at all, so the journal alone cannot pin
  # what reached the wire. An unpinnable constraint is read here as none.
  local c52emptykinds="${tmp}/c52-empty-kinds.ndjson"
  jq -c "if (.frame | tostring | test(\"sub-h\")) and (.frame[0] == \"REQ\") then
           .frame = [\"REQ\",\"sub-h\",{\"kinds\":[],\"#h\":[\"${H1}\",\"${H2}\"]}]
         else . end" "${healthy}" > "${c52emptykinds}"
  expect_rc 1 "C5.2 an EMPTY kinds list is unpinnable, so it is read as every kind" \
    --journal "${c52emptykinds}" "${base[@]}" || fail=1

  # THE LEAK, form 5: a filter key nobody has reasoned about (NIP-50 search).
  local c52key="${tmp}/c52-key.ndjson"
  jq -c 'if (.frame | tostring | test("sub-h")) and (.frame[0] == "REQ") then
           .frame[2].search = "alice"
         else . end' "${healthy}" > "${c52key}"
  expect_rc 1 "C5.2 an unrecognised filter key is closed out" \
    --journal "${c52key}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET: REQs exist, but none carries `#h`, so the group-plane
  # shape this invariant pins was never exercised.
  local c52nohd="${tmp}/c52-no-h.ndjson"
  jq -c 'select((.frame | tostring | test("\"#h\"")) | not)' "${healthy}" > "${tmp}/c52nohd.raw"
  renumber "${tmp}/c52nohd.raw" "${c52nohd}"
  expect_rc 4 "C5.2 precondition: a snapshot with no #h REQ proves nothing" \
    --journal "${c52nohd}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.3 — per-event 445 tag shape
  # =========================================================================
  # THE LEAK, form 1: a SECOND `h` on one event. C4's union-level tag check
  # cannot see this at all — the NAME set is unchanged.
  local c53dup="${tmp}/c53-dup-h.ndjson"
  jq -c "if (.frame | tostring | test(\"e08\")) then
           .frame = [\"EVENT\", $(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"],[\"h\",\"${H2}\"]]" 1785886100)]
         else . end" "${healthy}" > "${c53dup}"
  expect_rc 1 "C5.3 a second h tag binds two groups in one event" \
    --journal "${c53dup}" "${base[@]}" || fail=1
  expect_msg "no union-level tag check (C4) can see" "C5.3 says why C4 cannot catch it" \
    --journal "${c53dup}" "${base[@]}" || fail=1

  # THE LEAK, form 2: a third tag name.
  local c53third="${tmp}/c53-third.ndjson"
  jq -c "if (.frame | tostring | test(\"e09\")) then
           .frame = [\"EVENT\", $(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"],[\"client\",\"haven\"]]" 1785886144)]
         else . end" "${healthy}" > "${c53third}"
  expect_rc 1 "C5.3 a third tag name is a per-message selector" \
    --journal "${c53third}" "${base[@]}" || fail=1
  expect_msg "partition group traffic without decrypting" "C5.3 names the selector inference" \
    --journal "${c53third}" "${base[@]}" || fail=1

  # THE LEAK, form 3: a duplicated NIP-40 claim. The tag-NAME set is unchanged
  # ({expiration,h}), so only the cardinality rule can fire — which is what
  # makes this fixture a proof that the rule is alive rather than shadowed.
  local c53dupexp="${tmp}/c53-dup-exp.ndjson"
  jq -c "if (.frame | tostring | test(\"e09\")) then
           .frame = [\"EVENT\", $(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"],[\"expiration\",\"1785890000\"]]" 1785886144)]
         else . end" "${healthy}" > "${c53dupexp}"
  expect_rc 1 "C5.3 a duplicated expiration is an ambiguous retention claim" \
    --journal "${c53dupexp}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, arm 1: no application message — the two-tag arm untested.
  local c53nocommitapp="${tmp}/c53-no-app.ndjson"
  jq -c 'if (.frame | tostring | test("\"kind\":445")) then
           .frame = (.frame | map(if (type == "object" and .kind == 445)
                                  then .tags = [.tags[0]] else . end))
         else . end' "${healthy}" > "${c53nocommitapp}"
  expect_rc 4 "C5.3 precondition: a commit-only snapshot leaves the app arm untested" \
    --journal "${c53nocommitapp}" "${base[@]}" || fail=1
  # A commit-only journal also trips C5.1s floor, so the exit code alone does
  # not prove C5.3 noticed. Assert C5.3s OWN message: without this the fixture
  # would pass on somebody elses precondition.
  expect_msg "C5.3 precondition: no kind-445 carrying" \
    "C5.3 app-arm precondition fires in its own name, not on C5.1s coat-tails" \
    --journal "${c53nocommitapp}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, arm 2: no commit — the single-tag arm untested.
  local c53noc="${tmp}/c53-no-commit.ndjson"
  jq -c 'select((.frame | tostring | test("e08")) | not)' "${healthy}" > "${tmp}/c53noc.raw"
  renumber "${tmp}/c53noc.raw" "${c53noc}"
  expect_rc 4 "C5.3 precondition: an app-only snapshot leaves the commit arm untested" \
    --journal "${c53noc}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.4 — no g, no alt
  # =========================================================================
  local c54g="${tmp}/c54-g.ndjson"
  jq -c "if (.frame | tostring | test(\"e08\")) then
           .frame = [\"EVENT\", $(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"],[\"g\",\"u4pru\"]]" 1785886100)]
         else . end" "${healthy}" > "${c54g}"
  expect_rc 1 "C5.4 a g tag is cleartext coarse location" \
    --journal "${c54g}" "${base[@]}" || fail=1
  expect_msg "index and query by \`#g\`" "C5.4 names the relay-side geohash query" \
    --journal "${c54g}" "${base[@]}" || fail=1

  local c54alt="${tmp}/c54-alt.ndjson"
  jq -c "if (.frame | tostring | test(\"e08\")) then
           .frame = [\"EVENT\", $(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"],[\"alt\",\"Encrypted group message\"]]" 1785886100)]
         else . end" "${healthy}" > "${c54alt}"
  expect_rc 1 "C5.4 an alt tag fingerprints every Haven 445" \
    --journal "${c54alt}" "${base[@]}" || fail=1
  # The secondary note that makes `alt` worse than it looks: event.rs:217 pushes
  # it UNCONDITIONALLY, so it would mark every 445, not only geohash ones.
  expect_msg "UNCONDITIONALLY" "C5.4 records that alt is not gated on the geohash" \
    --journal "${c54alt}" "${base[@]}" || fail=1

  # Both fixtures above put the forbidden tag on a kind-445, where C5.3s
  # per-event shape rule ALSO fires — so their exit code alone does not prove
  # C5.4 noticed, which is why each asserts C5.4s own message. This third
  # fixture removes the ambiguity entirely: a `g` tag on a kind-10002, where no
  # other rule in this file applies. C5.4 says "any kind" and this is what
  # holds it to that.
  local c54other="${tmp}/c54-other-kind.ndjson"
  jq -c "if (.frame | tostring | test(\"e02\")) then
           .frame = [\"EVENT\", $(ev 10002 "e02" "${PK_A}" "[[\"r\",\"${RELAY_A}\"],[\"g\",\"u4pru\"]]")]
         else . end" "${healthy}" > "${c54other}"
  expect_rc 1 "C5.4 a g tag on a NON-445 kind is caught too (the rule is any-kind)" \
    --journal "${c54other}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET: no kind-445 at all.
  local c54no445="${tmp}/c54-no-445.ndjson"
  jq -c 'select((.frame | tostring | test("\"kind\":445")) | not)' "${healthy}" > "${tmp}/c54no.raw"
  renumber "${tmp}/c54no.raw" "${c54no445}"
  expect_rc 4 "C5.4 precondition: no 445 in the snapshot proves nothing about the builder" \
    --journal "${c54no445}" "${base[@]}" || fail=1
  # ...in C5.4s own name: dropping every 445 also trips C5.1s and C5.3s floors.
  expect_msg "C5.4 precondition: no kind-445 event was observed" \
    "C5.4 precondition fires in its own name, not on another invariants coat-tails" \
    --journal "${c54no445}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.5 — 1059 tag set is exactly {p}
  # =========================================================================
  local c55exp="${tmp}/c55-expiration.ndjson"
  jq -c "if (.frame | tostring | test(\"e07\")) then
           .frame = [\"EVENT\", $(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"],[\"expiration\",\"1788478144\"]]")]
         else . end" "${healthy}" > "${c55exp}"
  expect_rc 1 "C5.5 an expiration on a gift wrap is a Haven fingerprint" \
    --journal "${c55exp}" "${base[@]}" || fail=1
  expect_msg "DISTINGUISHES Haven invitations" "C5.5 names the NIP-17 distinguishability inference" \
    --journal "${c55exp}" "${base[@]}" || fail=1

  local c55twop="${tmp}/c55-two-p.ndjson"
  jq -c "if (.frame | tostring | test(\"e07\")) then
           .frame = [\"EVENT\", $(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"],[\"p\",\"${PK_A}\"]]")]
         else . end" "${healthy}" > "${c55twop}"
  expect_rc 1 "C5.5 two p tags name two people as invited together" \
    --journal "${c55twop}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET: no gift wrap at all.
  local c55no="${tmp}/c55-none.ndjson"
  jq -c 'select((.frame | tostring | test("\"kind\":1059")) | not)' "${healthy}" > "${tmp}/c55no.raw"
  renumber "${tmp}/c55no.raw" "${c55no}"
  expect_rc 4 "C5.5 precondition: a run that issues no invitation cannot vouch for one" \
    --journal "${c55no}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.6 — publish-target containment
  # =========================================================================
  # THE LEAK, form 1: a 445 published to a relay outside its kind's pool.
  local c56out="${tmp}/c56-outside.ndjson"
  write_healthy "${c56out}"
  jopen c6 "ws://127.0.0.1:7900" "127.0.0.1:7901"
  jline c2r c6 "[\"EVENT\",$(ev 445 "eOUT" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886500\"]]" 1785886200)]" "ws://127.0.0.1:7900" "127.0.0.1:7901"
  emit_sentinel c0
  expect_rc 1 "C5.6 a 445 outside its circle's relays is a violation" \
    --journal "${c56out}" "${base[@]}" || fail=1

  # THE LEAK, form 1b — the FAN-OUT shape, which is how a containment breach
  # actually reaches the wire. Publishing sends ONE event to every relay in a
  # set, so the copy that escapes the pool carries the SAME id as the copies
  # that stayed inside it, and it is sent SECOND. Every other fixture here
  # gives each endpoint its own id, so this is the only one that exercises the
  # `.epKey` component of the (event, endpoint) key: drop it and the first,
  # legitimate destination answers for the second, and a 445 reaching an
  # unrouted relay reports CLEAN.
  local c56fan="${tmp}/c56-fanout.ndjson"
  write_healthy "${c56fan}"
  local fanbody
  fanbody="$(ev 445 "eFAN" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886500\"]]" 1785886200)"
  jopen c6 "ws://127.0.0.1:7900" "127.0.0.1:7901"
  jline c2r c1 "[\"EVENT\",${fanbody}]"
  jline c2r c6 "[\"EVENT\",${fanbody}]" "ws://127.0.0.1:7900" "127.0.0.1:7901"
  emit_sentinel c0
  expect_rc 1 "C5.6 one event id fanned out to an in-pool AND an out-of-pool relay is a violation" \
    --journal "${c56fan}" "${base[@]}" || fail=1
  # Named endpoint, not just the rule: the finding must be about the copy that
  # LEFT the pool. A message naming 127.0.0.1:7777 would mean the pair the
  # oracle kept was the legitimate one and the breach was inferred elsewhere.
  expect_msg "PUBLISHED to ws://127.0.0.1:7900, which is not in the declared pool" \
    "C5.6 names the endpoint the fan-out escaped to, not the one it legitimately reached" \
    --journal "${c56fan}" "${base[@]}" || fail=1

  # ...and the same fan-out entirely INSIDE the pool must NOT red, or the
  # (event, endpoint) key would forbid the publishing shape it exists to
  # police: one id, two endpoints, two containment facts, both contained.
  local c56fanok="${tmp}/c56-fanout-ok.ndjson"
  write_healthy "${c56fanok}"
  jopen c5 "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c1 "[\"EVENT\",${fanbody}]"
  jline c2r c5 "[\"EVENT\",${fanbody}]" "${RELAY_B}" "127.0.0.1:7790"
  emit_sentinel c0
  expect_rc 0 "C5.6 one event id fanned out across two IN-pool relays is contained, not a finding" \
    --journal "${c56fanok}" "${base[@]}" || fail=1

  # The OTHER half of the (event, endpoint) key, and the reason its event half
  # is the BODY rather than the id. Two events sharing an id reach ONE
  # endpoint: an in-pool 445 first, then a 30443 — a kind whose pool is the
  # account's NIP-65 relays and does NOT include this one. Keyed on the id,
  # the 445 arrives first, survives, and answers for a KeyPackage published to
  # a relay it was never routed to. Endpoint-scoping alone does not save this:
  # both frames share the endpoint too.
  local c56idkind="${tmp}/c56-shared-id-two-kinds.ndjson"
  write_healthy "${c56idkind}"
  jopen c5 "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c5 "[\"EVENT\",$(ev 445 "eSHARED" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886500\"]]" 1785886200)]" "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c5 "[\"EVENT\",$(ev 30443 "eSHARED" "${PK_A}" "${KP_TAGS}")]" "${RELAY_B}" "127.0.0.1:7790"
  emit_sentinel c0
  expect_rc 1 "C5.6 a second KIND under one event id at one endpoint is contained on its own terms" \
    --journal "${c56idkind}" "${base[@]}" || fail=1
  expect_msg "a kind-30443 EVENT was PUBLISHED to ${RELAY_B}" \
    "C5.6 reports the KeyPackage, not the 445 that shares its id" \
    --journal "${c56idkind}" "${base[@]}" || fail=1

  # THE LEAK, form 2: an EVENT to a DISCOVERY relay. This is the one a flat URL
  # allow-list false-greens, because the discovery set is a strict superset of
  # the account seed.
  local c56disc="${tmp}/c56-discovery.ndjson"
  write_healthy "${c56disc}"
  jline c2r c8 "[\"EVENT\",$(ev 30443 "eDISC" "${PK_A}" "${KP_TAGS}")]" "${DISCOVERY}" "127.0.0.1:7998"
  emit_sentinel c0
  expect_rc 1 "C5.6 an EVENT to a discovery relay is a violation" \
    --journal "${c56disc}" "${base[@]}" || fail=1
  expect_msg "REQ yes; EVENT never" "C5.6 names the read-only discovery rule" \
    --journal "${c56disc}" "${base[@]}" || fail=1

  # ...and the discovery relay is genuinely exercised read-only in the healthy
  # fixture, so the rule is not passing merely because nothing touched it.
  if ! grep -aq 'sub-disc' "${healthy}"; then
    echo "SELF-TEST FAIL: the healthy fixture no longer REQs the discovery relay, so" >&2
    echo "  C5.6's read-only rule is untested in the passing direction." >&2
    fail=1
  fi

  # THE EMPTY SUBSET, form 1: a kind is published with no pool declared. Note
  # the sibling's mistake this avoids — an undeclared kind must not silently
  # pass, it must say the containment was never bounded.
  local -a partial=(--sentinel "${SENTINEL}" --pool "445=${RELAY_A},${RELAY_B}")
  expect_rc 4 "C5.6 precondition: a published kind with no pool is unbounded, not clean" \
    --journal "${healthy}" "${partial[@]}" || fail=1
  expect_msg "cannot be bounded" "C5.6 says the target was never bounded" \
    --journal "${healthy}" "${partial[@]}" || fail=1

  # THE EMPTY SUBSET, form 2: no client->relay EVENT at all.
  local c56noev="${tmp}/c56-no-events.ndjson"
  fx_begin "${c56noev}"
  jopen c1
  jline c2r c1 "[\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"]}]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "e10" "${PK_EPH3}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"]]" 1785886100)]"
  jline r2c c1 "[\"EVENT\",\"sub-p\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  emit_sentinel c0
  expect_rc 4 "C5.6 precondition: a receive-only snapshot has no publish targets" \
    --journal "${c56noev}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, form 3: sent events that cannot be resolved to an
  # endpoint. This is the branch that would otherwise report "we did not look"
  # as "nothing left the pool".
  local c56blind="${tmp}/c56-blind.ndjson"
  fx_begin "${c56blind}"
  jline_bare c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"]]" 1785886100)]"
  jline_bare c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  jline_bare c2r c1 "[\"EVENT\",$(ev 445 "e10" "${PK_EPH3}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  jline_bare c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline_bare c2r c1 "[\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"]}]"
  emit_sentinel c0 bare
  expect_rc 4 "C5.6 precondition: an endpoint-less journal cannot bound containment" \
    --journal "${c56blind}" "${base[@]}" || fail=1

  # ...and the SAME journal with `conn_open` records resolves and passes, which
  # is what proves the fallback join works rather than the check being inert.
  local c56join="${tmp}/c56-join.ndjson"
  fx_begin "${c56join}"
  jopen c1
  jline_bare c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"]]" 1785886100)]"
  jline_bare c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  jline_bare c2r c1 "[\"EVENT\",$(ev 445 "e10" "${PK_EPH3}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  jline_bare c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline_bare c2r c1 "[\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"]}]"
  emit_sentinel c0 bare
  expect_rc 0 "C5.6 a conn_open record resolves a journal in the bare contract shape" \
    --journal "${c56join}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.7 — fresh ephemeral author on every kind-445
  # =========================================================================
  # Two arg sets that DROP one declaration each. They are what prove the two
  # halves of the identity set are independently live: with `--identity-pubkey`
  # removed, only the journal-derived keys can fire the rule; with it present
  # and a key the journal never shows, only the declaration can.
  local -a base_nodecl=(--sentinel "${SENTINEL}" "${POOLS[@]}" \
    --discovery-relay "${DISCOVERY}" --mls-group-id "${MLS1}" --mls-group-id "${MLS2}")

  # THE LEAK, form 1: a 445 signed by a long-term identity key. PK_A publishes
  # this journal's kind-0, 10002, 10050 and 30443, so it is an identity key by
  # observation and not by declaration — which is what `base_nodecl` isolates.
  local c57idk="${tmp}/c57-identity-author.ndjson"
  write_healthy "${c57idk}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eIDK" "${PK_A}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886500\"]]" 1785886200)]"
  emit_sentinel c0
  expect_rc 1 "C5.7 a 445 signed by an identity key is a violation" \
    --journal "${c57idk}" "${base[@]}" || fail=1
  expect_msg "attributes every one of that circle's messages to a named person" \
    "C5.7 names the attribution, not the field" \
    --journal "${c57idk}" "${base[@]}" || fail=1
  # The DERIVED half alone: no --identity-pubkey at all, and the rule still
  # fires because kind 0/10002/10050/30443 are identity-signed by protocol.
  # Without this case the derived set could rot to `[]` and every identity
  # finding would still appear, carried entirely by the declaration.
  expect_rc 1 "C5.7 the identity set derived from kind-0/10002/10050/30443 authors fires on its own" \
    --journal "${c57idk}" "${base_nodecl[@]}" || fail=1

  # THE LEAK, form 2: a key the JOURNAL never shows as identity-signing, named
  # by the caller. The pair is the whole experiment — the same journal must be
  # clean without the declaration and red with it, or the flag is decoration.
  local c57decl="${tmp}/c57-declared-identity.ndjson"
  write_healthy "${c57decl}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eDECL" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886520\"]]" 1785886250)]"
  emit_sentinel c0
  expect_rc 0 "C5.7 an undeclared, never-identity-signing key is an ordinary ephemeral author" \
    --journal "${c57decl}" "${base[@]}" || fail=1
  expect_rc 1 "C5.7 --identity-pubkey arms the rule for a key the journal never reveals" \
    --journal "${c57decl}" "${base[@]}" --identity-pubkey "${PK_EPH4}" || fail=1

  # THE LEAK, form 3: one ephemeral key, two DIFFERENT messages. This is the
  # freshness half, and the one a single-445 run cannot test at all.
  local c57reuse="${tmp}/c57-key-reuse.ndjson"
  write_healthy "${c57reuse}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eR1" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886600\"]]" 1785886240)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eR2" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886601\"]]" 1785886241)]"
  emit_sentinel c0
  expect_rc 1 "C5.7 one ephemeral key signing two different 445s is a violation" \
    --journal "${c57reuse}" "${base[@]}" || fail=1
  expect_msg "stable per-sender handle on the outer event" \
    "C5.7 names what a reused author gives the relay" \
    --journal "${c57reuse}" "${base[@]}" || fail=1

  # ...and the SAME two events INBOUND must not red. A relay is free to return
  # anything; attributing its output to the app would manufacture findings on
  # every echo. This is the fixture that pins the send-side scoping, and
  # `expect_no_msg` is the only way to state it — an rc of 0 alone cannot tell
  # "the rule looked and stayed silent" from "the rule is switched off".
  local c57in="${tmp}/c57-inbound-reuse.ndjson"
  write_healthy "${c57in}"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eR1" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886600\"]]" 1785886240)]"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eR2" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886601\"]]" 1785886241)]"
  emit_sentinel c0
  expect_rc 0 "C5.7 an author repeated across two INBOUND 445s is not Haven's traffic" \
    --journal "${c57in}" "${base[@]}" || fail=1
  expect_no_msg "C5.7 ephemeral author" \
    "C5.7 stays silent on inbound frames rather than being merely outvoted" \
    --journal "${c57in}" "${base[@]}" || fail=1
  expect_msg "NOT asserted" "the inbound sample is reported as an advisory, not dropped" \
    --journal "${c57in}" "${base[@]}" || fail=1

  # THE LEAK, form 4: a 445 with no author at all. The direct negation of
  # "carries a fresh ephemeral pubkey" — and the shape a pubkey-blind grouping
  # would silently fold into one bucket with every other author-less event.
  local c57nopk="${tmp}/c57-no-pubkey.ndjson"
  write_healthy "${c57nopk}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eNOPK" "" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886620\"]]" 1785886260)]"
  emit_sentinel c0
  expect_rc 1 "C5.7 a 445 carrying no author pubkey is a violation" \
    --journal "${c57nopk}" "${base[@]}" || fail=1
  expect_msg "carrying no author pubkey at all" "C5.7 names the missing author" \
    --journal "${c57nopk}" "${base[@]}" || fail=1

  # THE MULTISET TRAP, aimed at C5.7's arithmetic specifically. ONE event
  # published to two relays and echoed to two subscriptions is four frames
  # sharing one author, and the ONLY thing separating that from form 3 above
  # is the body de-duplication. Drop it — or key C5.7 on (body, endpoint) the
  # way C5.6 must be keyed — and every ordinary fan-out becomes a key reuse.
  local c57fan="${tmp}/c57-fanout.ndjson"
  write_healthy "${c57fan}"
  local c57body
  c57body="$(ev 445 "eFANK" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886640\"]]" 1785886270)"
  jopen c5 "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c1 "[\"EVENT\",${c57body}]"
  jline c2r c5 "[\"EVENT\",${c57body}]" "${RELAY_B}" "127.0.0.1:7790"
  jline r2c c1 "[\"EVENT\",\"sub-h\",${c57body}]"
  jline r2c c5 "[\"EVENT\",\"sub-h\",${c57body}]" "${RELAY_B}" "127.0.0.1:7790"
  emit_sentinel c0
  expect_rc 0 "C5.7 one 445 fanned out to two relays and echoed twice is one message, not four" \
    --journal "${c57fan}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, first form — and the one the charter calls out by name.
  # With exactly ONE kind-445 below the sentinel, "no two share an author" is
  # true because there is no pair, and a client that reused a single key
  # forever would produce precisely this verdict. META-FLOOR, never a pass.
  local c57one="${tmp}/c57-single-445.ndjson"
  fx_begin "${c57one}"
  jopen c1
  jline c2r c1 "[\"EVENT\",$(ev 0 "e00" "${PK_A}" '[]')]"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "e04" "${PK_A}" "${KP_TAGS}")]"
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"]}]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  emit_sentinel c0
  expect_rc 4 "C5.7 precondition: a single 445 makes author-uniqueness vacuous" \
    --journal "${c57one}" "${base[@]}" || fail=1
  expect_msg "vacuously true" "C5.7 precondition says the silence is not evidence" \
    --journal "${c57one}" "${base[@]}" || fail=1

  # ...and the floor must LIFT once a second message exists, or it is not a
  # floor but a permanent red that would train a reader to ignore it. Same
  # journal plus a second circle's application message and a commit, which is
  # also what C5.1's and C5.3's own preconditions need.
  local c57two="${tmp}/c57-two-445.ndjson"
  cp "${c57one}" "${c57two}"
  FIXTURE_FILE="${c57two}"; FIXTURE_SEQ=6
  jline c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"]]" 1785886100)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e10" "${PK_EPH3}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  emit_sentinel c0
  renumber "${c57two}" "${c57two}.r" && mv "${c57two}.r" "${c57two}"
  expect_rc 0 "C5.7 the single-445 floor lifts as soon as a second message exists" \
    --journal "${c57two}" "${base[@]}" || fail=1

  # ...and it must NOT lift on a FAN-OUT. The same single message published to
  # two relays is two (event, endpoint) pairs and still one message, so a
  # `$s445` keyed the way C5.6's `$sent` must be keyed would count two, clear
  # the floor and report the run as having tested author freshness — over a
  # journal containing exactly one message and therefore no pair to compare.
  # The floor would then be satisfiable by adding a relay, which is the one
  # way a META-FLOOR can be defeated without publishing anything new.
  #
  # rc alone cannot see this (C5.1 and C5.3 META-FLOOR on this journal too, so
  # it is rc 4 either way); the C5.7 message is the discriminator.
  local c57fanfloor="${tmp}/c57-fanout-floor.ndjson"
  cp "${c57one}" "${c57fanfloor}"
  FIXTURE_FILE="${c57fanfloor}"; FIXTURE_SEQ=7
  jopen c5 "${RELAY_B}" "127.0.0.1:7790"
  jline c2r c5 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]" \
    "${RELAY_B}" "127.0.0.1:7790"
  emit_sentinel c0
  renumber "${c57fanfloor}" "${c57fanfloor}.r" && mv "${c57fanfloor}.r" "${c57fanfloor}"
  expect_rc 4 "C5.7 precondition: a fan-out of ONE message does not clear the two-message floor" \
    --journal "${c57fanfloor}" "${base[@]}" || fail=1
  expect_msg "vacuously true" \
    "C5.7 counts messages, not (message, endpoint) pairs — a second relay is not a second message" \
    --journal "${c57fanfloor}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, second form: nothing identity-signed anywhere, and no
  # declaration either, so the forbidden set is empty and the identity arm was
  # compared against nothing. The pair below is the proof — the same journal
  # passes the moment the caller supplies the ground truth.
  local c57noid="${tmp}/c57-no-identity.ndjson"
  fx_begin "${c57noid}"
  jopen c1
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"]}]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e08" "${PK_EPH1}" "[[\"h\",\"${H1}\"]]" 1785886100)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e09" "${PK_EPH2}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e10" "${PK_EPH3}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  emit_sentinel c0
  expect_rc 4 "C5.7 precondition: an empty identity set makes the identity arm vacuous" \
    --journal "${c57noid}" "${base_nodecl[@]}" || fail=1
  expect_msg "no key this device is known to sign with" \
    "C5.7 precondition names the empty comparison set" \
    --journal "${c57noid}" "${base_nodecl[@]}" || fail=1

  expect_rc 0 "C5.7 --identity-pubkey supplies the ground truth an identity-free journal lacks" \
    --journal "${c57noid}" "${base[@]}" || fail=1

  # The floor must be SEND-SIDE. An inbound identity-scoped event supplies a key
  # to $IDKEYS, but C5.7 asserts over c2r only, so that key can never match a
  # 445 author -- the floor would be discharged while the account under test was
  # never in the comparison. Journal: one r2c 30443 authored by PK_B (a peer
  # keypackage fetch, the only identity-scoped event), and a c2r 445 signed by
  # PK_A, the LOCAL identity key. Before this was send-side scoped, that run
  # reported CLEAN -- a Security Rule 2 break attributing every group message
  # in the circle to a named account.
  local c57inbound="${tmp}/c57-inbound-only.ndjson"
  fx_begin "${c57inbound}"
  jopen c1
  jline r2c c1 "[\"EVENT\",\"sub-kp\",$(ev 30443 "e20" "${PK_B}" "[]")]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e21" "${PK_A}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886372\"]]" 1785886144)]"
  jline c2r c1 "[\"EVENT\",$(ev 445 "e22" "${PK_EPH2}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886389\"]]" 1785886161)]"
  emit_sentinel c0
  expect_rc 4 "C5.7 floor is NOT discharged by an inbound-only identity key" \
    --journal "${c57inbound}" "${base_nodecl[@]}" || fail=1
  expect_msg "An INBOUND identity key does not discharge this" \
    "C5.7 precondition says why an inbound key cannot count" \
    --journal "${c57inbound}" "${base_nodecl[@]}" || fail=1


  # =========================================================================
  # C5.8 — the real MLS group id never on the wire
  # =========================================================================
  local -a base_nomls=(--sentinel "${SENTINEL}" "${POOLS[@]}" \
    --discovery-relay "${DISCOVERY}" --identity-pubkey "${PK_A}" --identity-pubkey "${PK_B}")

  # THE LEAK, form 1 — ID ALIASING. The `h` tag's value IS the real MLS group
  # id, which is the failure the Dart assertion guarded with an explicit
  # precondition: if the two ids are ever the same value, every h-tag scan in
  # the repo passes while the real id ships on every group message. It must
  # report as aliasing and not as a stray tag, because the fix is in the layer
  # that mints the routing value.
  local c58alias="${tmp}/c58-alias.ndjson"
  write_healthy "${c58alias}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "eALIAS" "${PK_EPH4}" "[[\"h\",\"${MLS1}\"],[\"expiration\",\"1785886700\"]]" 1785886210)]"
  emit_sentinel c0
  expect_rc 1 "C5.8 an h tag whose value is the real MLS group id is a violation" \
    --journal "${c58alias}" "${base[@]}" || fail=1
  expect_msg "id ALIASING" "C5.8 diagnoses aliasing rather than reporting a stray tag" \
    --journal "${c58alias}" "${base[@]}" || fail=1

  # THE LEAK, form 2: a tag token BEYOND index 1. This is the fixture that
  # certifies the normalize() change — truncating tags at two elements, which
  # is what this file did before C5.8 existed, makes every tag position from
  # the third on a blind spot, and no other case here would notice.
  local c58deep="${tmp}/c58-deep-token.ndjson"
  write_healthy "${c58deep}"
  jline c2r c1 "[\"EVENT\",$(ev 0 "eLEAK3" "${PK_A}" "[[\"client\",\"haven\",\"${MLS2}\"]]" 1785886220)]"
  emit_sentinel c0
  expect_rc 1 "C5.8 a leak in a tag's THIRD token is caught, not truncated away" \
    --journal "${c58deep}" "${base[@]}" || fail=1
  expect_msg 'tag at position 2' "C5.8 names the token position it found the id in" \
    --journal "${c58deep}" "${base[@]}" || fail=1

  # THE LEAK, form 3: the id EMBEDDED in a longer token, on a kind that is not
  # 445 at all. Security Rule 4 is not scoped to group messages, and an
  # equality test rather than a substring test would miss a composite slot
  # name — the exact shape a `d` tag built by string concatenation produces.
  local c58sub="${tmp}/c58-substring.ndjson"
  write_healthy "${c58sub}"
  jline c2r c1 "[\"EVENT\",$(ev 30443 "eKPLEAK" "${PK_A}" "[[\"d\",\"haven-kp-0-${MLS1}\"],[\"mls_protocol_version\",\"1.0\"]]")]"
  emit_sentinel c0
  expect_rc 1 "C5.8 an id embedded in a longer token on a non-445 kind is a violation" \
    --journal "${c58sub}" "${base[@]}" || fail=1
  expect_msg 'inside its `d` tag at position 1' "C5.8 names the tag the id was embedded in" \
    --journal "${c58sub}" "${base[@]}" || fail=1

  # ...and an INBOUND frame carrying the id is not Haven publishing it. A relay
  # that returns the value has not made Haven leak it, and reading it as a
  # send-side finding would be a false red on any run against a hostile or
  # merely noisy relay.
  local c58in="${tmp}/c58-inbound.ndjson"
  write_healthy "${c58in}"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "eINLEAK" "${PK_EPH4}" "[[\"h\",\"${MLS1}\"],[\"expiration\",\"1785886720\"]]" 1785886230)]"
  emit_sentinel c0
  expect_rc 0 "C5.8 an inbound frame carrying the id is the relay's output, not Haven's" \
    --journal "${c58in}" "${base[@]}" || fail=1
  expect_no_msg "C5.8 group-id privacy" \
    "C5.8 looked at the inbound frame and stayed silent rather than being switched off" \
    --journal "${c58in}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET, first form — and the decision this check turns on. The id
  # cannot be derived (its absence from the wire is the assertion), so with no
  # declaration the scan compared the journal against nothing. Publishing 445s
  # without declaring one is a META-FLOOR, never a clean bill of health.
  expect_rc 4 "C5.8 precondition: 445s published with no --mls-group-id declared" \
    --journal "${healthy}" "${base_nomls[@]}" || fail=1
  expect_msg "compared the wire against an empty set of values" \
    "C5.8 precondition says the scan had nothing to look for" \
    --journal "${healthy}" "${base_nomls[@]}" || fail=1

  # ...and the DECLARED alternative. A lane that genuinely cannot supply the id
  # may say so, loudly. This must NOT behave like a conditional check: the run
  # goes green so the other eight verdicts are readable, but the skip is on the
  # record of every run rather than inferable from an absence.
  expect_rc 0 "a declared non-assertion clears C5.8's precondition" \
    --journal "${healthy}" "${base_nomls[@]}" \
    --mls-group-id-not-asserted "no host-side channel for CircleFfi.mlsGroupId yet" || fail=1
  expect_msg "C5.8 NOT ASSERTED (declared by the lane)" \
    "the declared non-assertion is PRINTED, not silently honoured" \
    --journal "${healthy}" "${base_nomls[@]}" \
    --mls-group-id-not-asserted "no host-side channel for CircleFfi.mlsGroupId yet" || fail=1
  expect_msg "no host-side channel for CircleFfi.mlsGroupId yet" \
    "the declared REASON reaches the log verbatim" \
    --journal "${healthy}" "${base_nomls[@]}" \
    --mls-group-id-not-asserted "no host-side channel for CircleFfi.mlsGroupId yet" || fail=1

  # The SUCCESS BANNER is the line a reader greps to conclude "green => the rule
  # held". Listing C5.8 there while an advisory above says it was never scanned
  # is a false statement in the highest-traffic place, so the banner must drop
  # to eight-of-nine and say so. Without these two fixtures the banner fix is
  # itself unverified -- which is the defect it exists to repair.
  expect_msg "clean on EIGHT of nine" \
    "the success banner drops to eight-of-nine when C5.8 is not asserted" \
    --journal "${healthy}" "${base_nomls[@]}" \
    --mls-group-id-not-asserted "no channel yet" || fail=1
  expect_msg "NOT evidence for Security Rule 4" \
    "the banner states outright that the run does not evidence Rule 4" \
    --journal "${healthy}" "${base_nomls[@]}" \
    --mls-group-id-not-asserted "no channel yet" || fail=1
  # ...and the nine-of-nine claim is still made when C5.8 really did run.
  expect_msg "all nine had a non-empty sample" \
    "the full banner survives when the id IS declared" \
    --journal "${healthy}" "${base_nomls[@]}" --mls-group-id "${MLS1}" || fail=1
  # The skip must be attributable to the lane, never inferable from silence: if
  # no 445 was published there is nothing to skip and nothing to announce.
  expect_rc 2 "declaring the id AND its non-assertion is refused" \
    --journal "${healthy}" "${base_nomls[@]}" \
    --mls-group-id "${MLS1}" \
    --mls-group-id-not-asserted "contradictory" || fail=1
  expect_rc 2 "an empty non-assertion reason is refused" \
    --journal "${healthy}" "${base_nomls[@]}" \
    --mls-group-id-not-asserted "   " || fail=1

  # THE NEEDLE SET THAT SHRANK. Every fixture above turns on the set being
  # NON-EMPTY, and no journal can say whether it is COMPLETE — an id the host
  # never received looks exactly like a circle the run never made. The healthy
  # fixture creates two circles, so declaring one of them is the whole defect:
  # one circle's traffic goes unscanned while all nine verdicts still report
  # clean. This is the case the lane's independent count exists to catch, and
  # WITHOUT the cross-check it is proven here to be green.
  expect_rc 0 "a HALVED needle set is green when nothing cross-checks it" \
    --journal "${healthy}" "${base_nomls[@]}" --mls-group-id "${MLS1}" || fail=1
  expect_rc 4 "...and a META-FLOOR the moment the lane declares what it announced" \
    --journal "${healthy}" "${base_nomls[@]}" --mls-group-id "${MLS1}" \
    --expect-mls-group-ids 2 || fail=1
  expect_msg "the lane announced 2 MLS group id(s) but 1 reached this scan" \
    "the mismatch names BOTH counts, so a reader can tell which half broke" \
    --journal "${healthy}" "${base_nomls[@]}" --mls-group-id "${MLS1}" \
    --expect-mls-group-ids 2 || fail=1
  # The COMPLETE set must still pass, or the check above would also be
  # satisfied by a flag that reds every run.
  expect_rc 0 "a needle set matching the lane's count passes" \
    --journal "${healthy}" "${base[@]}" --expect-mls-group-ids 2 || fail=1
  # The OTHER direction is a finding too, and a different one: more ids than the
  # run announced means the sidecar was never rotated, so C5.8 is scanning for a
  # previous run's values — needles that cannot be found and cannot fail.
  expect_rc 4 "MORE ids than the lane announced is a META-FLOOR, not a pass" \
    --journal "${healthy}" "${base[@]}" --expect-mls-group-ids 1 || fail=1
  expect_msg "values this run never minted" \
    "the over-count names the stale-sidecar reading rather than reporting a shortfall" \
    --journal "${healthy}" "${base[@]}" --expect-mls-group-ids 1 || fail=1
  # A count that did not parse must never become a comparison that matches
  # anything: an empty grep in a lane is exactly how that arrives.
  expect_rc 2 "a non-numeric --expect-mls-group-ids is refused" \
    --journal "${healthy}" "${base[@]}" --expect-mls-group-ids "" || fail=1
  expect_rc 2 "a negative --expect-mls-group-ids is refused" \
    --journal "${healthy}" "${base[@]}" --expect-mls-group-ids "-1" || fail=1
  # A lane that supplies no count gets no cross-check — and the summary must SAY
  # so rather than let a reader infer completeness from a bare number.
  expect_msg "completeness NOT cross-checked" \
    "an absent cross-check is stated, not left to be inferred from the count" \
    --journal "${healthy}" "${base[@]}" || fail=1
  expect_msg "(lane announced 2 — cross-checked)" \
    "...and a cross-check that RAN is named in the same place" \
    --journal "${healthy}" "${base[@]}" --expect-mls-group-ids 2 || fail=1

  # THE EMPTY SUBSET, second form: an id was declared but no group message was
  # ever published, so none of the events that could carry it are in the
  # sample and a clean verdict would describe the journal, not the app.
  local c58no445="${tmp}/c58-no-445.ndjson"
  fx_begin "${c58no445}"
  jopen c1
  jline c2r c1 "[\"EVENT\",$(ev 0 "e00" "${PK_A}" '[]')]"
  jline c2r c1 "[\"EVENT\",$(ev 1059 "e07" "${PK_EPH1}" "[[\"p\",\"${PK_B}\"]]")]"
  jline c2r c1 "[\"REQ\",\"sub-h\",{\"kinds\":[445],\"#h\":[\"${H1}\",\"${H2}\"]}]"
  emit_sentinel c0
  expect_rc 4 "C5.8 precondition: a declared id with no 445 in the snapshot proves nothing" \
    --journal "${c58no445}" "${base[@]}" || fail=1
  expect_msg "contains none of the events that could have leaked the real id" \
    "C5.8 precondition names the missing event class" \
    --journal "${c58no445}" "${base[@]}" || fail=1

  # =========================================================================
  # C5.9 — no `p` tag on a kind-445
  # =========================================================================
  # THE LEAK. Both messages are asserted, and that is the point: a `p` on a 445
  # also trips C5.3, so the exit code alone cannot tell which rule spoke, and a
  # C5.9 deleted outright would leave this fixture red with C5.3's generic
  # "a third tag NAME" and nothing telling the reader that circle membership
  # just became queryable.
  local c59p="${tmp}/c59-p-tag.ndjson"
  write_healthy "${c59p}"
  jline c2r c1 "[\"EVENT\",$(ev 445 "ePTAG" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886740\"],[\"p\",\"${PK_B}\"]]" 1785886280)]"
  emit_sentinel c0
  expect_rc 1 "C5.9 a p tag on a published 445 is a violation" \
    --journal "${c59p}" "${base[@]}" || fail=1
  expect_msg "indexed, queryable membership edge" \
    "C5.9 names the membership disclosure, which C5.3's shape message does not" \
    --journal "${c59p}" "${base[@]}" || fail=1
  expect_msg "C5.3 kind-445 tag shape" \
    "C5.3 still reports the same event, so C5.9 is a diagnosis and not a replacement" \
    --journal "${c59p}" "${base[@]}" || fail=1

  # ...and the same tag on an INBOUND 445 is the relay's frame. C5.3 spans both
  # directions and still fires (so the event is not unexamined), but C5.9 must
  # not accuse Haven of publishing something it received.
  local c59in="${tmp}/c59-inbound-p.ndjson"
  write_healthy "${c59in}"
  jline r2c c1 "[\"EVENT\",\"sub-h\",$(ev 445 "ePIN" "${PK_EPH4}" "[[\"h\",\"${H1}\"],[\"expiration\",\"1785886760\"],[\"p\",\"${PK_B}\"]]" 1785886290)]"
  emit_sentinel c0
  expect_no_msg "C5.9 recipient privacy" \
    "C5.9 does not accuse Haven of publishing a p tag a relay sent it" \
    --journal "${c59in}" "${base[@]}" || fail=1
  expect_msg "C5.3 kind-445 tag shape" \
    "the inbound p-tagged 445 is still examined by the direction-agnostic rule" \
    --journal "${c59in}" "${base[@]}" || fail=1

  # THE EMPTY SUBSET: no group message was published, so the routing rule had
  # nothing to read. Shares a journal with C5.8's second form on purpose — one
  # missing event class, two invariants that must each say so for themselves.
  expect_msg "C5.9 precondition" \
    "C5.9 declares its own empty subset rather than riding C5.8's" \
    --journal "${c58no445}" "${base[@]}" || fail=1

  # =========================================================================
  # --exclude-conn — the harness's own socket is not Haven's traffic
  # =========================================================================
  # The E2E harness reaches the same proxied relays as the app. A TestRelay
  # probe that legitimately names two authors (a lane asserting what the relay
  # holds) would otherwise be reported as a Haven social-graph disclosure.
  #
  # UNDECLARED first: a socket that never emitted the marker is indistinguish-
  # able from the app's own, and only the lane can name it. This is the case
  # --exclude-conn exists for, and it is kept as its own fixture so the flag
  # cannot rot into a no-op behind the self-declaration below.
  local xharness="${tmp}/exclude-harness.ndjson"
  write_healthy "${xharness}"
  jopen c7
  jline c2r c7 "[\"REQ\",\"probe\",{\"kinds\":[30443],\"authors\":[\"${PK_A}\",\"${PK_B}\"],\"limit\":25}]"
  # Re-anchor: every line appended after `write_healthy`'s marker would sit
  # ABOVE the snapshot boundary and never be examined at all.
  emit_sentinel c0
  expect_rc 1 "an UNDECLARED harness probe is a finding while its connection is attributed to Haven" \
    --journal "${xharness}" "${base[@]}" || fail=1
  expect_rc 0 "--exclude-conn removes the harness socket from attribution" \
    --journal "${xharness}" "${base[@]}" --exclude-conn c7 || fail=1

  # DECLARED: the same probe on a socket that emitted the intercepted sentinel
  # verb needs no flag at all. `TestRelay._declareHarnessSocket` marks every
  # socket the harness opens, including the ones a mid-run reconnect mints,
  # which is the half a drive-log grep for one ack can never cover.
  local xdeclared="${tmp}/declared-harness.ndjson"
  write_healthy "${xdeclared}"
  jopen c7
  emit_declaration c7
  jline c2r c7 "[\"REQ\",\"probe\",{\"kinds\":[30443],\"authors\":[\"${PK_A}\",\"${PK_B}\"],\"limit\":25}]"
  emit_sentinel c0
  expect_rc 0 "a self-declared harness socket is excluded with no --exclude-conn at all" \
    --journal "${xdeclared}" "${base[@]}" || fail=1

  # The reason the declaration exists, as its own fixture: ONE harness socket
  # multiplexes several simulated peers (`SyntheticUser.publishLocation` →
  # `TestRelay.publishAndAwaitOk`), so two peers publishing to two circles 35 ms
  # apart put two different-`h` 445s in one second on one connection. Judged as
  # a device that is precisely C5.1's leak; judged as what it is, it is two
  # devices coinciding and says nothing about Haven. This is the exact journal
  # that reddened three consecutive live-sync runs.
  local xpeers="${tmp}/harness-multiplexed-peers.ndjson"
  write_healthy "${xpeers}"
  jopen c7
  emit_declaration c7
  jline c2r c7 "[\"EVENT\",$(ev 445 "ePEER1" "${PK_EPH5}" "[[\"h\",\"${H3}\"],[\"expiration\",\"1785886500\"]]" 1785886228)]"
  jline c2r c7 "[\"EVENT\",$(ev 445 "ePEER2" "${PK_EPH6}" "[[\"h\",\"${H2}\"],[\"expiration\",\"1785886500\"]]" 1785886228)]"
  emit_sentinel c0
  expect_rc 0 "two peers multiplexed onto ONE harness socket in one second are not a Haven finding" \
    --journal "${xpeers}" "${base[@]}" || fail=1
  expect_no_msg "C5.1 timestamp correlation" \
    "C5.1 read the multiplexed socket and stayed silent rather than being switched off" \
    --journal "${xpeers}" "${base[@]}" || fail=1

  # ...and it must NOT become a silencer. Excluding the connection that carries
  # the real traffic empties the sample, and an empty sample is a META-FLOOR,
  # never a pass. This is the fixture that keeps --exclude-conn honest.
  expect_rc 4 "--exclude-conn cannot be used to silence a finding (it fails closed)" \
    --journal "${xharness}" "${base[@]}" --exclude-conn c7 --exclude-conn c1 --exclude-conn c2 || fail=1

  # The sentinel marker must stay outside the REQ allow-list's reach: it is a
  # proxy-intercepted VERB (frame.rs:51), not a REQ, so it can neither be
  # mistaken for a subscription nor trip the closed-world filter-key rule. And
  # the ack must NOT be in the journal at all — the proxy writes it straight to
  # the client sink, bypassing both recording pumps.
  if ! grep -aq '\["HAVEN_WIRE_SENTINEL","' "${healthy}"; then
    echo "SELF-TEST FAIL: the healthy fixture no longer carries the recorder's real" >&2
    echo "  sentinel verb (tooling/e2e/local-relay/src/frame.rs:51)." >&2
    fail=1
  fi
  if grep -aq 'HAVEN_WIRE_SENTINEL_ACK' "${healthy}"; then
    echo "SELF-TEST FAIL: the healthy fixture contains a sentinel ACK. The proxy sends" >&2
    echo "  the ack via client_tx (proxy.rs:339-345), which bypasses both recording" >&2
    echo "  pumps, so no journal can contain one and this fixture is unfaithful." >&2
    fail=1
  fi

  # -------------------------------------------------------------------------
  # USAGE (rc 2) — including the guards on the guard.
  # -------------------------------------------------------------------------
  expect_rc 2 "no arguments" || fail=1
  expect_rc 2 "no --journal" --sentinel "${SENTINEL}" "${POOLS[@]}" || fail=1
  expect_rc 2 "no --sentinel (an unanchored read is refused)" \
    --journal "${healthy}" "${POOLS[@]}" || fail=1
  expect_rc 2 "no --pool (a vacuous C5.6 is refused)" \
    --journal "${healthy}" --sentinel "${SENTINEL}" || fail=1
  expect_rc 2 "a too-short sentinel token is refused" \
    --journal "${healthy}" --sentinel "abc" "${POOLS[@]}" || fail=1
  expect_rc 2 "a malformed --pool is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" --pool "445" || fail=1
  # Paired with a VALID pool, so the refusal cannot come from the "no --pool at
  # all" guard. Without this pairing the case passes on that guard's coat-tails
  # and the empty-value branch could be deleted unnoticed — at which point
  # `--pool 445=` would silently become the strictest rule in the file
  # ("kind 445 may reach nothing") on a typo.
  expect_rc 2 "an empty --pool value is refused rather than read as 'nothing allowed'" \
    --journal "${healthy}" --sentinel "${SENTINEL}" --pool "1059=${RELAY_A}" --pool "445=" || fail=1
  # A URL declared as BOTH a discovery relay and a publish target: the
  # confusion the superset relationship makes easy, refused rather than
  # silently resolved in favour of one of the two rules.
  expect_rc 2 "a URL that is both a discovery relay and a pool member is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" \
    --pool "445=${RELAY_A}" --discovery-relay "${RELAY_A}" || fail=1

  # The guards on C5.7's and C5.8's own inputs. Every one of these would, if
  # accepted, leave the check running and matching NOTHING — the failure mode
  # this whole file exists to refuse, arriving through the argument list
  # instead of through the journal.
  #
  # An npub, a truncated key or a key with a `02`/`03` prefix never equals an
  # x-only author hex, so C5.7's identity arm would compare against a value no
  # event can carry while every summary line still reported it as declared.
  expect_rc 2 "an --identity-pubkey that is not 64 hex chars is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" "${POOLS[@]}" \
    --identity-pubkey "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" || fail=1
  expect_rc 2 "an --identity-pubkey with a 33-byte compressed prefix is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" "${POOLS[@]}" \
    --identity-pubkey "02${PK_A}" || fail=1
  # A SHORT needle is the dangerous direction for a substring scan: it matches
  # unrelated tokens by coincidence and buries the real finding in noise.
  expect_rc 2 "an --mls-group-id shorter than 32 hex chars is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" "${POOLS[@]}" \
    --mls-group-id "deadbeefdeadbeef" || fail=1
  # Non-hex cannot match a hex token, so the scan would be off while looking on.
  expect_rc 2 "a non-hex --mls-group-id is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" "${POOLS[@]}" \
    --mls-group-id "not-a-hex-group-id-not-a-hex-group-id-xx" || fail=1
  # An odd character count is not a whole number of bytes, so whatever it is,
  # it is not the id the app minted — a truncated copy/paste, most likely.
  expect_rc 2 "an --mls-group-id with an odd character count is refused" \
    --journal "${healthy}" --sentinel "${SENTINEL}" "${POOLS[@]}" \
    --mls-group-id "${MLS1}a" || fail=1
  # ...and the valid form must be ACCEPTED, or the four refusals above would
  # also be satisfied by a flag that rejects everything.
  expect_rc 0 "the valid forms of both new flags are accepted" \
    --journal "${healthy}" --sentinel "${SENTINEL}" "${POOLS[@]}" \
    --discovery-relay "${DISCOVERY}" \
    --identity-pubkey "${PK_A}" --mls-group-id "${MLS1}" || fail=1

  # A floor on the fixture COUNT, not just on their verdicts. Every assertion
  # here is a set operation that passes over an empty input, and the self-test
  # is no exception: deleting cases would leave it green while the thing it
  # certifies stopped being certified. If a case is genuinely retired, lower
  # this number in the same commit and say why.
  #
  # It is pinned to the EXACT count, deliberately. It used to carry slack, on
  # the reasoning that an exact pin "turns the first legitimately-skipped
  # fixture into a self-test failure" — but the sentence above it says every
  # case is unconditional and the count deterministic, so no fixture can be
  # legitimately skipped and the slack bought nothing except room to delete.
  # At 114-against-124 that room was ten cases, which is most of the C5.8
  # section. An exact pin means retiring a case is a two-line diff that has to
  # say why, which is the reviewable act the slack was quietly avoiding.
  readonly MIN_CASES=157
  if (( CASES_RUN < MIN_CASES )); then
    echo "SELF-TEST FAIL: only ${CASES_RUN} fixture(s) ran; at least ${MIN_CASES} expected." >&2
    echo "  Cases have been removed without lowering MIN_CASES — the self-test is" >&2
    echo "  now certifying less than it claims." >&2
    fail=1
  fi

  if (( fail )); then
    echo "check-wire-correlation: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "check-wire-correlation: self-test passed (${CASES_RUN} fixtures — a healthy" \
       "two-circle journal clears all nine invariants; each of C5.1-C5.9 goes red on" \
       "the leak it guards AND red as a META-FLOOR on an empty relevant subset," \
       "including the commit-only trap that would make C5.1 vacuous and the" \
       "single-445 trap that would make C5.7 vacuous; C5.1 is proven to attribute" \
       "PER PUBLISHER — one connection serving two circles in one second is a" \
       "violation, two connections coinciding is not, a multiplexed harness socket" \
       "is excluded by its own declaration, inbound pairs are silent, two circles" \
       "served by two devices is a META-FLOOR rather than a sample, and disjoint" \
       "relay sets refuse to report clean; two bodies under one event id" \
       "are both checked whether they differ in tags, kind or created_at, one event id" \
       "fanned out to an out-of-pool relay is caught, and a multi-#h REQ that omits" \
       "\`kinds\` is read at its widest; a 445 signed by an identity key is caught from" \
       "the journal-derived set AND from a declaration, one ephemeral key on two" \
       "messages is caught while the same event fanned out to two relays and echoed" \
       "twice is not, a leaked MLS group id is caught in an h tag, in a third tag" \
       "token and embedded in a longer one, and a needle set that SHRANK to half" \
       "the run's circles is proven green without the lane's own count and a" \
       "META-FLOOR with it, in both directions; C5.7/C5.8/C5.9 are proven SILENT on" \
       "inbound frames rather than merely outvoted, and both new flags refuse every" \
       "input shape that would leave their check matching nothing; repeated event" \
       "ids, an in-pool fan-out, the accepted multiplexed #h shape and traffic above" \
       "the sentinel do not red)."
  return 0
}

main "$@"
