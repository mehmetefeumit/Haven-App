# The wire journal — producer contract

The recording WebSocket proxy (`tooling/e2e/local-relay`, binary
`haven-wire-proxy`) sits between the app under test and the hermetic relay and
writes an NDJSON **wire journal**: one line per WebSocket message, both
directions, with a globally monotonic `wire_seq`.

This document is the authoritative schema. It supersedes the working draft the
consumers were bootstrapped against; every deviation from that draft is flagged
**DEVIATION** below.

## Why it exists

The oracle it replaces (`_assertWirePrivacyInvariants` in
`haven/integration_test/e2e/e2e_combined.dart`) is a forbid-list scoped to one
circle's kind-445 stream, so a new kind, a new tag or an MDK-introduced field
passes in silence. It is also silently shrinking: application kind-445s carry
`expiration = created_at + 228`, both hermetic relays enforce NIP-40, and its
`collectN` runs late in a 720 s scenario — so on a slow run the location events
have already been evicted and the checks quietly narrow to the commit subset
while `isNotEmpty` stays satisfied.

A proxy is immune to that. It records what was **sent**; an event a relay later
drops for expiry was still transmitted, and the transmission is the
privacy-relevant fact. It also sees what in-relay hooks cannot — `strfry` and
`LocalRelay` expose different things, and both only expose what they accepted.

## Where it sits

```
  app / harness  ──►  haven-wire-proxy :7788  ──►  relay :7777
                            │
                            └──►  /tmp/haven-wire-journal.ndjson
```

The relay keeps port 7777, so inserting the recorder into a lane is a one-line
change to that lane's `HAVEN_E2E_RELAY`:

| lane | before | after |
|---|---|---|
| Android | `ws://10.0.2.2:7777` | `ws://10.0.2.2:7788` |
| iOS | `ws://localhost:7777` | `ws://localhost:7788` |

Relay startup/teardown, health checks and the network-egress guard are all
unchanged — the guard allows all loopback traffic, so any port works.

```yaml
- name: Start the recording wire proxy
  run: bash tooling/e2e/ci/start-wire-proxy.sh 7788 ws://127.0.0.1:7777

- name: Tear down the recording wire proxy
  if: always()
  run: bash tooling/e2e/ci/stop-wire-proxy.sh
```

`start-wire-proxy.sh` refuses if another live instance already holds the journal
path it was given, builds the binary, runs its `--self-test` as a preflight (so
the lane proves the instrument on this runner before trusting it), rotates any
stale journal, starts the proxy, claims the journal path and blocks until the
port accepts.

### Multi-relay lanes

One proxy process serves several routes, all writing to ONE journal and ONE
`wire_seq` space — the only way an oracle can order relay R1's traffic against
R2's:

```sh
HAVEN_WIRE_PROXY_ROUTES='7788=ws://127.0.0.1:7777,7789=ws://127.0.0.1:7778' \
  bash tooling/e2e/ci/start-wire-proxy.sh
```

Running one proxy per relay instead would give each file its own sequence
space, and no consumer could establish a total order across them.

## Record types

Every line carries a `type`.

| `type` | when | fields |
|---|---|---|
| `frame` | one Text/Binary WebSocket message | `wire_seq` `type` `conn_id` `ts_ms` `dir` `relay_url` `listen` `frame` `raw_preview`? `raw_len` |
| `conn_open` | once per accepted connection, before any of its frames | `wire_seq` `type` `conn_id` `ts_ms` `relay_url` `listen` |
| `conn_error` | the connection could not be completed end to end | as `conn_open`, plus `reason`, plus `discarded`? |

**Three, and only three.** Every consumer validates `type` against that closed
set, so a fourth record type would make each of them report a perfectly good
journal as UNUSABLE. Anything new the producer needs to say has to be said
within these three — which is why the delivery retraction below is a
`conn_error` and not a type of its own.

A consumer that only wants traffic filters `type == "frame"`. The `frame` key
is present (possibly `null`) on exactly those lines, so `"frame" in line` is an
equivalent discriminator. Lifecycle records carry **no `dir` and no `frame`** —
a consumer that switches on `dir` must filter on `type` first.

**That equivalence is a promise two consumers can disagree about, so one of
them now ASSERTS it.** `check-wire-journal.sh` discriminates on `type`;
`check-wire-correlation.sh` discriminates on `has("frame")`. A line carrying
both a lifecycle `type` and a `frame` is therefore invisible to the first and
traffic to the second — a kind-3 EVENT on a `type:"conn_open"` line passed the
structural oracle in silence — and a line carrying a `frame` with no `type` is
the converse. `check-wire-journal.sh`'s `journal_wellformed` now rejects a
journal in which any lifecycle record carries `frame` or `dir`, and rejects a
`conn_error` with no `reason`. A consumer must not paper over the disagreement
locally: the producer is the only place it can be resolved.

```json
{"wire_seq":4,"type":"frame","conn_id":"c1","ts_ms":1785886144123,"dir":"c2r","relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","frame":["EVENT",{"id":"…","kind":445,"pubkey":"…","created_at":1785886144,"tags":[["h","…"],["expiration","…"]],"content":"…","sig":"…"}],"raw_len":420}
{"wire_seq":0,"type":"conn_open","conn_id":"c0","ts_ms":1785886144000,"relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788"}
{"wire_seq":1,"type":"conn_error","conn_id":"c0","ts_ms":1785886144010,"relay_url":"ws://127.0.0.1:9999","listen":"127.0.0.1:7788","reason":"upstream connect failed"}
```

### Fields

| field | type | meaning |
|---|---|---|
| `wire_seq` | int | Monotonic across the WHOLE journal, from 0, **gapless**. Total order of observation. Allocated under the same lock as the write, so file order and `wire_seq` order always agree — a consumer may stream instead of buffering and sorting. |
| `type` | string | `frame` \| `conn_open` \| `conn_error`. |
| `conn_id` | string | `c0`, `c1`, … Stable per WebSocket connection, unique across every route. |
| `ts_ms` | int | Proxy-side wall clock at observation. Never load-bearing for ordering. |
| `dir` | string | `c2r` (client→relay) or `r2c` (relay→client). `frame` lines only. |
| `relay_url` | string | The upstream this connection is proxied to — where the bytes actually went. |
| `listen` | string | `host:port` of the proxy listener that accepted the connection — how a lane correlates a connection back to the relay entry it configured in the app. |
| `frame` | array \| null | The parsed frame verbatim. `null` when the message was not structurally a Nostr frame. |
| `raw_preview` | string | Present exactly when `frame` is `null`. At most 200 **characters** (not bytes, so a multi-byte payload cannot be truncated into invalid UTF-8). |
| `raw_len` | int | Byte length of the original message, before parsing. Always the FULL size, even when the preview is truncated. |
| `reason` | string | `conn_error` only. A fixed label from the closed vocabulary below, never a transport error's own text. |
| `discarded` | int | `conn_error` only, and only on a delivery retraction: how many journalled frames on this connection, in the direction `reason` names, did NOT leave the proxy. Absent otherwise. |

### The `reason` vocabulary

Small and enumerable on purpose — a `reason` is only useful to a consumer if it
can be matched, not parsed.

| `reason` | meaning |
|---|---|
| `client handshake failed` | The client's WebSocket handshake did not complete. |
| `upstream connect failed` | The proxy could not reach `relay_url`. |
| `c2r read failed` / `r2c read failed` | The named direction's stream failed MID-CONNECTION: invalid UTF-8 in a text frame, a protocol violation, a capacity overrun, a reset without a closing handshake. The error CLASS is on the proxy's stderr (which `stop-wire-proxy.sh` tails into the lane log), not in the journal — the direction is the part that changes a verdict, and enlarging this vocabulary by twelve error kinds would make it unmatchable. |
| `c2r frames discarded` / `r2c frames discarded` | A delivery retraction; carries `discarded`. See below. |

A read failure is a FINDING, not noise: a journal that simply stopped was
previously indistinguishable from a clean close, and an oracle cannot fail
closed on a truncation it cannot see. Note the corollary — a peer that drops
its socket without a closing handshake now leaves a `conn_error` line, so these
are not rare.

## A recorded frame is a SENT frame — or the journal retracts it

A traffic line is written BEFORE the message is handed to its socket (the
sentinel's snapshot boundary depends on that order), so every `frame` line
CLAIMS a delivery to `relay_url`. Teardown must not falsify that claim, so a
connection that ends drains its writers under a bound rather than cancelling
them, and if the bound expires — or a socket died with frames still queued —
the proxy records:

```json
{"wire_seq":88,"type":"conn_error","conn_id":"c3","ts_ms":1785886144999,"relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","reason":"c2r frames discarded","discarded":3}
```

That says: **the last `discarded` journalled lines of connection `conn_id` in
that direction did not go out.** The queue is FIFO and the recorder writes in
the same order, so the retraction is precise rather than a blanket "distrust
this connection".

Two consequences a consumer must handle:

* The retraction is ORDERED AFTER the lines it retracts, so a streaming
  consumer has to revisit them. There is no way around this: the fact is not
  knowable when the line is written.
* A retraction can therefore land ABOVE a sentinel boundary while the lines it
  retracts sit below it. For a containment assertion (`observed ⊆ allowed`)
  that is the safe direction — the journal overstates what was sent, so the
  oracle checks a superset. For a liveness assertion (`required ⊆ observed`) it
  is not, so an oracle of that shape should scan the WHOLE file for
  `discarded` rather than only its snapshot.

Nothing was lost in a healthy run, and no discard record is written then.

## DEVIATIONS from the working draft

Five, all reported rather than decided silently.

### 1. `relay_url` + `listen` on every line, plus lifecycle records (ADDED)

The draft made `conn_id` opaque, with no endpoint. An assertion like "no event
ever reached an unconfigured relay" is a statement about *endpoints* and cannot
be written against an opaque id at all.

Both were added, rather than one or the other:

* **`relay_url` on every traffic line** — no join required, impossible for a
  consumer to get wrong, and ~40 bytes per line at E2E volumes.
* **`conn_open` / `conn_error` records** — because a connection carrying ZERO
  frames is invisible in a frame-only journal, and "the app dialled an endpoint
  and sent nothing" (or "…and could not reach it") is itself a containment
  finding.

This makes the journal *more* sensitive: it now maps traffic to named hosts.
See "Artifact policy" below, and note that `start-wire-proxy.sh` refuses a
non-loopback upstream unless `HAVEN_WIRE_PROXY_ALLOW_REMOTE=1`.

### 2. `type` on every line (ADDED)

Three record types need to be discriminable without inference. A consumer that
ignores `type` and reads `dir` gets `null` on a lifecycle record, so the field
is mandatory on every line and named first after `wire_seq`.

### 3. "Recognised Nostr frame" means STRUCTURALLY recognised (CLARIFIED)

The draft says a frame that is "not a recognised Nostr frame" records as
`frame: null`. That is ambiguous, and reading it as a verb allowlist would
defeat the workstream: a novel verb would arrive as `frame: null`,
indistinguishable from line noise, and an oracle asserting `observed ⊆ allowed`
over `frame[0]` would go blind to exactly the novelty it exists to catch.

So the producer records `frame` verbatim whenever the message is **a JSON array
whose first element is a string** — `["NEG-OPEN", …]` keeps its verb and the
oracle rejects it. `frame: null` therefore means something rarer and stronger:
the message was not even structurally a Nostr frame.

The producer records faithfully; the oracle decides what is allowed.

### 4. WebSocket CONTROL frames are forwarded but NOT recorded (NARROWED)

The draft says "one line per WebSocket frame". Ping/Pong/Close carry no Nostr
payload, and a journal in which every keepalive appeared as `frame: null` would
bury the unparseable-frame signal — a finding — under routine noise. Text and
Binary messages are recorded; control frames are forwarded unchanged.

A binary message IS recorded (as a finding with a lossy preview): Nostr is a
text protocol, so a binary payload is never routine.

### 5. The sentinel's shape (SPECIFIED — the draft left it undefined)

See the next section. The draft's reading rules referred to "a sentinel frame"
without pinning its form, which four consumers cannot independently agree on.

## The sentinel

### The frame

A drive target emits, as a TEXT WebSocket message on any connection to the
proxy:

```json
["HAVEN_WIRE_SENTINEL","<opaque token>"]
```

The proxy **intercepts** it. It is recorded as an ordinary `type:"frame"`,
`dir:"c2r"` line and is **never forwarded upstream**, then answered on the same
connection with:

```json
["HAVEN_WIRE_SENTINEL_ACK","<token>",<wire_seq>,"<conn_id>"]
```

The ack is synthesized by the proxy and is deliberately **not** journalled:
recording it as `dir:"r2c"` would claim the relay sent it.

### Why intercepted, and not a marker the relay sees

This was a real choice. The obvious alternative is a plain NIP-01 `REQ` whose
subscription id is the token — it needs no producer support, since the proxy
records every frame verbatim. It was rejected because:

* **A test-only marker would appear in real relay traffic.** The relay would
  see it, log it, and (on a relay with subscription limits or auth) react to
  it. The instrument would be perturbing the scenario it observes.
* **A fire-and-forget marker cannot be confirmed.** The emitter learns nothing;
  a marker that never reached the recorder surfaces on the host as "no sentinel
  in the journal" — a true failure, but one that blames the recorder for a
  frame the drive never got out.
* **The boundary would have to be inferred.** The ack returns the exact
  `wire_seq`, so no consumer has to heuristically pick "the highest line
  containing the token".
* **Attribution.** The ack's `conn_id` lets the emitting harness EXCLUDE its
  own probe traffic when reasoning about what the app sent.

An out-of-band control channel (an HTTP endpoint on the proxy) was also
considered and rejected: it is a second listening socket on the runner — more
surface, not less — and it could not return a `wire_seq` synchronously without
a second synchronisation.

### The second job the same frame does: declaring a harness socket

The marker is also how a connection says **"I belong to the harness"**.

`SyntheticUser.publishLocation` publishes through whichever `TestRelay` its
scenario holds, so ONE harness socket multiplexes several simulated devices —
and an oracle that reasons per publisher (`check-wire-correlation.sh` C5.1: did
one device serve two circles in the same second?) reads that socket as a device
that publishes to every circle at once. That is the exact defect C5.1 hunts, so
an undeclared harness socket manufactures the finding it exists to detect.

`TestRelay._declareHarnessSocket()` therefore emits the same intercepted VERB
on **every** socket the harness opens, and re-emits it after every reconnect (a
reconnect mints a fresh `conn_id`):

```json
["HAVEN_WIRE_SENTINEL","HAVEN_WIRE_CONN"]
```

It is fire-and-forget: the ack carries the `conn_id`, but the journal line
already names its own connection, so consumers read the declaration out of the
journal rather than out of a drive log. It is a no-op when no recorder was
declared for the build, since the frame would otherwise reach a real relay.

Consumers treat `frame[0] == "HAVEN_WIRE_SENTINEL"` on a `c2r` line as making
that `conn_id` harness-owned — no production code path can emit that verb, and
`scripts/ci/check_wire_proxy_test_only.sh` is what keeps it that way.

**The payload is deliberately not the run's token, and the two roles must not
be merged.** A boundary keys on `frame[1] == <token>`; attribution keys on the
verb. Were a declaration to carry the token it could move the snapshot (a
reconnect declaration written after the marker would extend it) and it could
satisfy a pending `HAVEN_WIRE_SENTINEL_ACK` wait, handing the emitter the
declaration's `wire_seq` for the marker it thought it sent. Both failures are
silent and both narrow what a green run covers.

### How a drive target emits one

`TestRelay.emitWireJournalSentinel()`
(`haven/integration_test/e2e/_lib/test_relay.dart`) sends the frame, waits for
the ack, and returns a `WireJournalSentinel { token, wireSeq, connId }`. It
throws if no ack arrives — which is also what happens when the lane pointed the
app straight at a relay instead of through the proxy, and is the correct
verdict there.

Call it **last**, after the traffic that should be inside the snapshot. The
boundary is sound for anything the drive has confirmed: once a relay's `OK` has
been observed, the corresponding `c2r` line is necessarily already journalled
(the proxy records before it forwards, and the `OK` cannot precede the
forward). Traffic the drive never confirmed cannot be bounded by any marker on
any socket.

The token is opaque. The harness uses `HAVEN_WIRE_SENTINEL:<hex>` so that a
host oracle can also match it as a literal substring without colliding with
ordinary frame content:

```sh
TOKEN="HAVEN_WIRE_SENTINEL:$(openssl rand -hex 16)"
flutter drive --dart-define=HAVEN_WIRE_SENTINEL="$TOKEN" …
bash tooling/e2e/ci/check-wire-journal.sh --sentinel "$TOKEN" …
```

Never put anything sensitive in the token: it is written to the journal
verbatim and echoed in the ack.

### How a consumer uses one

1. Find the line where `type == "frame"`, `dir == "c2r"`,
   `frame[0] == "HAVEN_WIRE_SENTINEL"` and `frame[1] == <token>`.

   **A substring match on the token over the raw line is NOT equivalent, and
   this document used to say it was.** Any line merely *containing* the token
   extends the snapshot, and several kinds of line can contain it: event
   content, a relay `NOTICE` echoing an unknown frame back, and the bounded
   `raw_preview` of an unparseable frame. A boundary other parties' traffic can
   push upward is not a boundary — the sample stops being reproducible and the
   background-wake race the sentinel exists to close reopens. `grep` is fine as
   a prefilter over a large journal; the verdict must be the structural test.
   `check-wire-journal.sh` does this, and reports "the token is present but
   never as a marker frame" as a distinct condition from "no token at all".

   `dir == "c2r"` is part of the test: the proxy synthesizes the ack and
   deliberately does not journal it, and it never forwards the marker, so no
   relay can have sent one.
2. If it is **absent**, FAIL — do not fall back to "assert over everything".
   An absent marker means the drive never emitted one or the recorder went
   degraded, and either way the sample is unbounded and irreproducible.
3. Take that line's `wire_seq` as the boundary and assert only over lines at or
   below it. Emitting more than one marker is fine; anchor on the highest.
4. To attribute traffic to the app rather than the harness, exclude the
   `conn_id` the ack named.

## Fail-open producer, fail-closed oracle

These pull in opposite directions and both are required.

**The proxy fails OPEN.** If the journal cannot be opened, cannot be written,
or the recorder panics — in the sink OR while encoding a line, both inside one
`catch_unwind` — traffic still flows and the scenario still runs. A privacy
instrument that can break the product is worse than no instrument.

This is a property of the recorder's *type*, not of its call sites: every
`pub fn record*` returns `u64` and nothing else, so there is no error for a
caller to ignore and no `?` for a later edit to add. `scripts/ci/check_wire_proxy_test_only.sh`
pins that signature and pins that `journal.rs`'s non-test code contains no
`unwrap`/`expect`/`panic!`.

Failure latches a `degraded` flag, is reported once on stderr, and appears in
the shutdown summary that `stop-wire-proxy.sh` tails into the step log. The
sequence counter keeps advancing, so a degraded journal is a **gapless prefix**
that simply stops — never a file with holes.

**Lines are not written atomically.** Each line is built with its newline into
one buffer and handed to a single `write_all`, which is the smallest unit the
recorder can offer — but `write_all` loops over partial writes, so a consumer
tailing the file concurrently can read a line without its terminator. Treat an
unterminated final line as truncation; do not treat "the last line parsed" as
proof the writer finished.

Two things do NOT fail open. **Binding**: a proxy that cannot listen leaves the
app pointed at a dead port, so `start-wire-proxy.sh` exits non-zero and the lane
fails immediately. **Journal collision**: `start-wire-proxy.sh` refuses to start
when the journal path it was given is already held by another running instance,
because its first act would be to `rm -f` a file that process still has open —
after which the first proxy keeps writing to an unlinked inode, reports itself
healthy, and every oracle reads a journal silently missing a whole plane's
traffic. `HAVEN_WIRE_JOURNAL` overrides the PER-INSTANCE default, so do not
export it when running more than one instance.

**The oracle fails CLOSED.** An absent, empty or truncated journal is a
FAILURE, never a pass. This is the A4 lesson: "nothing to scan" was once
reported as "nothing leaked".

## Reading rules for oracles

* **De-duplicate before asserting, keyed on the BODY.** The same event
  legitimately appears many times (published to N relays, returned to M
  subscribers). Assert over a SET, never a multiset — counts are
  nondeterministic and a count assertion flakes. But key the set on the event
  body (id, kind, pubkey, `created_at`, tags), never on `id` alone: `id` is
  journal *data*, a value the publishing client chose and no consumer here
  verifies against the body it labels, so keying on it lets two different
  bodies collapse to whichever the recorder saw first and leaves the survivor
  answering for both. That is the one way de-duplication turns from a
  determinism fix into a blindfold.
* **An endpoint-scoped assertion keys on (body, endpoint).** Fan-out of one
  event to N relays under ONE id is the normal publishing shape, and it is
  exactly the shape in which a containment breach occurs — the copy that
  escapes the pool carries the same id as the copies that stayed inside it.
  Drop the endpoint from the key and the first, legitimate destination answers
  for every later one.
* **An absent filter field means EVERY value, not a convenient default.**
  Under NIP-01 a `REQ` filter constrains only on the fields it names, so a
  filter with no `kinds` matches every kind. Reading an omitted field as the
  narrowest shape an oracle blesses is fail-open on the one axis a filter
  widens without adding a character to the frame.
* **Snapshot with a sentinel.** Background wakes can write to the journal while
  an oracle reads it.
* **`observed ⊆ allowed` AND `required ⊆ observed`.** Not set equality — that
  false-reds whenever an optional tag legitimately does not appear.
* **`frame: null` is a finding.** It is not noise and not a keepalive; control
  frames are never recorded.
* **Assert `required ⊆ observed` over `dir == "c2r"` ONLY.** This journal
  records both directions, so an oracle that ignores `dir` attributes other
  parties' traffic to Haven. Two shapes made that concrete in
  `check-wire-journal.sh`: a run publishing only kind-30443 satisfied the
  "required" check for 445 and 1059 out of *inbound* copies, and a run in which
  every kind-445 Haven sent had lost its NIP-40 `expiration` reported clean
  because one inbound 445 still carried it. An inbound event proves a PEER
  still publishes; it never proves Haven does. Report the inbound half if it is
  useful — do not assert on it.
* **A record the oracle cannot DECODE is a finding, exactly like one it decodes
  and dislikes.** jq aborts the record it is working on when a filter meets the
  wrong type, and in a streaming pass that means the record is silently
  dropped. An event whose `id` was a number, whose `pubkey` was a number, or
  whose `tags` was a string vanished from `check-wire-journal.sh`'s sample and
  the run reported CLEAN. Type-check before use, make the decoder total, and
  latch the decoder's exit status — jq's status reflects only its LAST input,
  and the sentinel line is by construction the last parseable input at or below
  the boundary, so a success always follows an error.
* **Read every event object in an EVENT frame, not the first.**
  `["EVENT",<445>,<3>]` reduces to its 445 under `first`.
* **A `discarded` count retracts earlier lines.** Scan for it before treating a
  `frame` line as proof of transmission; see "A recorded frame is a SENT frame"
  above for which lines a retraction applies to.

## Artifact policy — the raw journal is never uploaded

The journal is a complete transcript: full event JSON (ciphertext, ephemeral
pubkeys, ids, signatures), REQ filters carrying long-term identity pubkeys,
bounded previews of anything unparseable, and now a `relay_url` on every line
mapping all of it to named endpoints. CI artifacts are retained for days on a
public repository. A privacy INSTRUMENT that leaves a durable copy of
everything it observed is a privacy HAZARD.

**Decision: the raw `*.ndjson` stays on the runner and dies with it. Lanes
upload a redacted summary instead.**

```sh
bash tooling/e2e/ci/summarize-wire-journal.sh \
  /tmp/haven-wire-journal.ndjson /tmp/wire-summary.log
```

Redaction is an **allowlist** built field-by-field in `src/summarize.rs`, not a
filter, so a future journal field cannot leak by default — an unmodelled field
is simply absent from the output.

| kept | dropped |
|---|---|
| `wire_seq`, `conn_id`, `dir`, `type`, `raw_len` | — |
| `relay_url`, `listen` (lane infrastructure) | — |
| event `kind`, tag NAMES | event `id`, `pubkey`, `sig`, `content`, tag VALUES |
| `content_len`, `signed` | `content` |
| REQ filter KEY names, `kinds` values | `authors`, `#p`, `#h`, `ids`, all other filter values |
| the `OK` boolean | subscription ids, NOTICE/CLOSED text (length only) |
| `preview_len` | `raw_preview` |
| `conn_error` `reason` (a fixed proxy label) | — |
| `discarded` (a count) | — |

Tag values are dropped because `["p",<pubkey>]` and `["h",<nostr_group_id>]`
are precisely the identifiers that must not outlive the lane. `kinds` survives
because a kind number carries no identity and is the single most useful thing
in a triage transcript.

**The allowlist is over FIELDS; the surviving VALUES have their own bound.**
Choosing which fields survive stops an unmodelled *field* leaking, and does
nothing about a modelled field whose *value* is remote-controlled. Three are: a
frame's verb, a tag's NAME and a REQ filter's KEY are copied out of arbitrary
attacker-shaped JSON, because the producer deliberately keeps `frame` for any
array with a string first element (DEVIATION 3). `["<64-hex pubkey>", …]` is a
structurally valid frame whose "verb" is a pubkey, and a value containing a
newline could forge whole summary lines — including the totals line a reader
trusts. Each is therefore length-capped and character-classed, and REJECTED
rather than truncated (`verb=INVALID(len=64)`): a 20-character prefix of a
pubkey is still an identifier, whereas a length is something the summary
already publishes. `conn_error` `reason` and every numeric field get the same
treatment, because this tool reads a FILE, which may be stale, hand-made or
foreign rather than something this producer wrote.

`summarize-wire-journal.sh` then runs the summary through
`tooling/e2e/ci/scan-logs-for-secrets.sh` and DELETES it if the scan flags
anything, so a redaction bug cannot become an artifact. A missing or empty
journal exits non-zero: the run carries no wire evidence, which is a finding,
not a pass. Same exit-code convention as the secret scanner (0 clean / 1 leak /
2 unusable).

`scripts/ci/check_wire_proxy_test_only.sh` fails CI if any workflow puts a
`.ndjson` path in an `upload-artifact` step, so this is enforced, not merely
documented.

## Scope, stated honestly

This is a **send-side** instrument. It says nothing about a hostile relay
withholding, reordering or forging inbound events — eclipse, welcome
suppression, stale-KeyPackage serving. Do not let an oracle's name imply
otherwise.

It also cannot, on its own, tell the app's connections from the harness's: on
these lanes both run on the same host and reach the proxy identically. What it
CAN do is let a connection declare itself — every harness socket emits the
sentinel (see above), so consumers can subtract the harness exactly. Telling one
NON-harness device from another is finer than that, and the journal answers it
only as far as "a connection is a publisher": a single client keeps one
connection per relay, so co-timing within a connection is one device's, while
co-timing across two connections may be two devices coinciding and is not
asserted. Distinguishing a device that spreads one burst across several relays
needs a mechanism this proxy does not have — C5.1 refuses to report clean when
the journal shows two groups on disjoint relay sets, rather than checking less
than it claims.

## Commands

```sh
# Serve (configured from the environment; see start-wire-proxy.sh)
haven-wire-proxy

# Prove the instrument on this machine: relay + proxy + client on loopback,
# six named cases, refuses to pass if it executed fewer than it declares
haven-wire-proxy --self-test

# Redacted, upload-safe transcript
haven-wire-proxy --summarize /tmp/haven-wire-journal.ndjson --out summary.log

# Prove the start script's journal-claim gate (hermetic; no build, no network)
bash tooling/e2e/ci/start-wire-proxy.sh --self-test
```

| env var | default | meaning |
|---|---|---|
| `HAVEN_WIRE_PROXY_PORT` | `7788` | Listen port (single-route shorthand). |
| `HAVEN_WIRE_PROXY_UPSTREAM` | `ws://127.0.0.1:7777` | Upstream relay. |
| `HAVEN_WIRE_PROXY_ROUTES` | — | `<listen>=<upstream>,…`; wins over the two above. |
| `HAVEN_WIRE_JOURNAL` | `/tmp/haven-wire-journal.ndjson` | Journal path. Overrides the PER-INSTANCE default — do not export it when running more than one instance; the start script refuses rather than rotating a journal another live instance holds. |
| `HAVEN_WIRE_PROXY_ALLOW_REMOTE` | `0` | Permit a non-loopback upstream (start script). |
| `HAVEN_WIRE_PROXY_RUN_DIR` | `/tmp` | Where the start/stop scripts keep pid, log and journal-claim files. |
