#!/usr/bin/env bash
# CI guard: the two relay pools each keep the options they need and neither
# adopts the other's; the background burst closes cleanly; the FFI bridge
# forwards the burst lifecycle to the engine rather than answering for it; and
# every relay client is built by the one constructor that verifies what a relay
# sends.
#
# Haven runs two pools with opposite duty cycles:
#
#   * the PUBLISH pool (`haven-core/src/relay/manager.rs`) connects, sends,
#     collects the OKs and then has nothing to say until the next location
#     tick. Nothing there holds a standing REQ, so a keepalive frame keeps
#     nothing alive — it is ~65 radio wakes an hour for an idle socket. Hence
#     `publish_relay_options()` = `ping(false).reconnect(false).sleep_when_idle(true)`.
#   * the ENGINE pool (`haven-core/src/relay/live_sync/session.rs`) exists to
#     hold a standing REQ. Its socket carries no other traffic, so a NAT box
#     that drops it produces a silent receive blackout nothing notices until
#     the 15-minute health tick — the C3 failure class. It therefore KEEPS the
#     ping and must never sleep.
#
# Copying either pool's options onto the other is a plausible "make these
# consistent" edit that costs battery in one direction and messages in the
# other, and neither direction has a runtime oracle: the wasted wakes only show
# up as battery hours later and off-device, and the blackout only shows up
# behind a NAT that drops idle sockets.
#
# # Why `verify_subscriptions` stays off (checks 1 and 2)
#
# nostr-sdk's `verify_subscriptions` re-checks every inbound EVENT against the
# filter registered for its subscription id — but `Relay::subscribe_long_lived`
# (nostr-relay-pool 0.44.3) SENDS the REQ and only THEN registers that filter.
# An event the relay replays inside that window finds no registered
# subscription and is discarded with `SubscriptionNotFound`, silently: no
# error reaches any caller, no notification is emitted, and nothing in the
# engine can tell the difference between "the relay had nothing" and "the pool
# threw away what it sent". The matching EOSE is NOT subject to the check, so
# it still lands and still anchors the sync cursor to the REQ's open time —
# past the events that were just dropped. The generation never comes back for
# them; only the next REQ's lookback does. On the inbox plane that is a
# gift-wrapped invitation (kind 1059) that does not arrive until the next
# session.
#
# The window is a task-scheduling gap, so it widens exactly when the device is
# busy and the relay answers quickly. It made
# `inbox_cursor_poisoning_e2e::a_future_dated_gift_wrap_never_pushes_the_inbox_cursor_past_the_local_clock`
# flaky in CI (runs 31216078806, 31555665220) and is reproducible locally by
# pinning that target to two cores.
#
# Nothing is given up by leaving the option off: the same identity dimensions
# of each plane's filter are re-checked in
# `live_sync::supervisor::plane_wants_event`, where the router context is
# registered BEFORE the REQ goes out and no such window exists. Re-enabling
# the option would restore the silent drop while adding nothing — hence this
# guard, which no test can replace: the drop is probabilistic, so a build with
# it re-enabled still passes the suite most of the time.
#
# Pure-grep gate (no Rust toolchain) so it runs fast and independently.
#
# Checks (each is a function returning an rc; ALL of them run, so one red run
# reports every violation instead of only the first):
#   1. `verify_subscriptions(true)` appears nowhere under haven-core/src or
#      haven/rust_builder/src.
#   2. The engine client builder still pins that option OFF explicitly, so
#      deleting the line (and inheriting a future upstream default of `true`)
#      is caught too.
#   3. `manager.rs` defines `fn publish_relay_options`, and its BODY still
#      carries `.ping(false)`, `.reconnect(false)` and `.sleep_when_idle(true)`.
#   4. Every `.add_relay(` call in `manager.rs` passes `publish_relay_options()`,
#      with exactly one allowlisted exception (see below).
#   5. `session.rs` contains no `.ping(false)` and no `.sleep_when_idle(` CALL:
#      the engine keeps the ping its standing REQ depends on, and its socket
#      may never sleep.
#   8. `session.rs`'s `fn pause_subscriptions` BODY (the burst's close path),
#      together with, when it calls `self.pause_locked(`, `fn pause_locked`'s
#      body — the pause under a lifecycle acquisition its caller holds:
#      contains `note_delivery_gap` or the `RawSignal::Pause` marker that
#      reaches it; contains NO `forget_` token; CALLS `terminate_all_relays()`
#      and contains NO `client.shutdown()`. The radio-off step is pinned
#      THROUGH that indirection: `fn terminate_all_relays`'s own body must
#      still call `client.disconnect()`, must not call `client.shutdown()`,
#      must re-read relay status after disconnecting and re-assert in a loop,
#      and must hold no timer. Plus: no standing-REQ call is reachable from the
#      background-burst ENTRY POINT (`fn resume_burst`).
#
# # Why check 8 pins those four facts and not a call order
#
# The pause is the one place the engine closes a socket while events may still
# be in flight, and each of these is silent when broken:
#
#   * `forget_*` DROPS an un-applied hold-back. The next burst's `EOSE` then
#     advances the cursor straight over an event this device recorded as
#     un-applied, and the catch-up sweep — which re-derives its floor from that
#     same per-circle cursor — never asks for it again. `note_delivery_gap`
#     suppresses the advance and KEEPS the hold-back. Both compile; only one is
#     correct, and the difference shows up as missing peer locations, weeks
#     later, on someone else's phone.
#   * `client.shutdown()` EMPTIES the pool (`force_remove_all_relays`), so the
#     next burst's subscribe fails with the opaque `no relays`. `disconnect()`
#     leaves the relays `Terminated` with their registrations intact, which is
#     what the next burst re-opens. Again both compile.
#   * a standing REQ opened from the burst entry point is the whole regression:
#     P4 exists to remove the standing subscription between publish ticks, and a
#     `subscribe`-shaped call there restores it with no observable symptom
#     except battery, hours later and off-device.
#
# The CALL ORDER inside the pause (sweep → marker → gauge → disconnect) is NOT
# pinned here. It is a runtime property with runtime oracles — the Rust tests
# `pause_never_disconnects_while_an_auto_commit_awaits_its_ok`,
# `a_pause_marker_drains_every_queued_event_before_the_router_is_cleared` and
# `rule13_a_burst_never_pauses_with_a_pending_publish_outstanding` — and a grep
# for an order would go red on a harmless refactor while proving nothing about
# the behaviour.
#
# # Why the disconnect is pinned THROUGH `terminate_all_relays`
#
# The pause no longer disconnects inline. `nostr-relay-pool`'s
# `InnerRelay::disconnect` fires its termination notify BEFORE it stores
# `Terminated`, and that notify is a single permit, not a latch: a connection
# task woken inside that gap can re-read the pre-store status, conclude it was
# not terminated, and re-arm its retry loop with the one permit that could have
# broken it already spent. It then opens a REAL socket over the pause's
# `Terminated` and holds it, pinging, until the next burst silently adopts it —
# P4's promise false for the whole gap, with no symptom but battery. So the
# pause calls `terminate_all_relays()`, which disconnects, yields, re-reads and
# re-asserts up to a bounded number of rounds.
#
# Accepting EITHER token in the pause body would have been the cheap fix, and it
# is the wrong one: it pins a NAME. A future `terminate_all_relays` that logs
# and returns would satisfy it, and the pause would stop closing sockets with
# every check still green — exactly the hole this check exists to close, moved
# one call deep. The requirement is therefore split in two: the pause must REACH
# the helper, and the helper must still BE a disconnect. The helper's body gets
# the four facts that make it one:
#
#   * it calls `client.disconnect()` and NOT `client.shutdown()`. `stop_inner`
#     calls this same helper immediately BEFORE its own `shutdown()`, so a
#     `shutdown()` moved in here would empty the pool in the PAUSE path too,
#     where the next burst still needs those registrations.
#   * it RE-READS relay status after disconnecting (`unterminated_relay_count()`,
#     or an inline `.status()` if that count is ever folded in) and re-asserts in
#     a loop. A helper that disconnects once and returns is the pre-fix
#     behaviour under a new name, and the loop plus the re-read are the only
#     things that tell the two apart in text: without the read there is nothing
#     to judge convergence by, and without the loop there is no second permit —
#     which is the whole repair, since a re-assert lands on a SLEEPING
#     connection task and breaks it without re-reading anything.
#   * it holds NO TIMER: no `sleep(`, `sleep_until(`, `timeout(`, `timeout_at(`
#     or `Duration::`. This runs after the pause's deliberately uncapped Rule-13
#     publish-gauge wait, so the helper's own doc states the invariant as "it
#     holds no timer"; the convergence signal is the status read, and a sleep
#     substituted for it passes on an idle host (where the race does not
#     reproduce at all) while hiding it on the loaded one — a background phone,
#     permanently. Matched as CALL syntax, never as words: the helper's comments
#     explain why it yields "never a sleep", and a prose match would fire on its
#     own explanation. (Those comments are stripped by `code_view` before the
#     match, so both defences hold independently.)
#
# NOT pinned: the round COUNT, the yield's spelling, and the warn-rather-than-
# fail policy on non-convergence. All three are tuning decisions — a pause that
# refused to finish would wedge the background tick over a condition it cannot
# fix — and a grep for any of them goes red on a harmless refactor while proving
# nothing.
#   6. `haven/rust_builder/src/api.rs` makes no `.add_relay(` call except the
#      marked e2e helper (its own throwaway client, not the publish pool).
#   7. `manager.rs` opens no standing REQ: EVERY `subscribe` spelling
#      nostr-sdk 0.44.1 / nostr-relay-pool 0.44.3 expose (`subscribe`,
#      `subscribe_to`, `subscribe_with_id`, `subscribe_with_id_to`,
#      `subscribe_targeted`, on `Client`, `RelayPool` and `Relay` alike) is
#      rejected unless it is declared auto-closing. A subscription registered
#      on the publish pool would keep the now ping-less socket from ever
#      sleeping AND re-create the C3 silent-drop class on the one pool that has
#      no keepalive to detect it.
#   9. `api.rs` is a PURE FORWARDER for the whole burst lifecycle: each of the
#      eight `LiveSyncFfi` methods named in `FFI_DELEGATIONS` calls
#      `core.<same-name>()`, makes exactly ONE call on the core handle, and
#      contains no `return` but the session gate's `return Err(`. The last rule
#      is what makes it a reachability check rather than a substring one — a
#      guarded bypass leaves the required call present and dead. See check 9's
#      own block for what each forwarding buys and how each collapse is silent.
#  10. `api.rs`'s two `#[frb(sync)]` session reads (`is_running`, `is_paused`)
#      answer from `SESSION`, ask the core for the flag they name, and contain
#      no panic token — a sync FFI read unwinds into Dart, and `unwrap_used` /
#      `expect_used` are restriction lints this repo does not enable.
#  11. Every relay client is built by `relay/verified.rs`'s `verified_client`,
#      which installs the policy that verifies each relay event's id AND
#      signature before the pool acts on it. No other source file under
#      haven-core/src, haven/rust_builder/src or tooling/soak/src names a
#      `Client` or `RelayPool` construction, other than the test witnesses
#      marked `// test witness` in the files and test modules listed for them;
#      nothing reads a client's database; no source gives a relay client a
#      signer; and MDK's relay client, which builds no client and is handed
#      one, is handed the publish client and nothing else, at one site. It is a
#      text scan: integration tests under `tests/` are not read, and a
#      construction it cannot spell is not seen. See check 11's own block for
#      what that leaves open.
#
# # Why check 7 reads every spelling, and how the one legitimate call is told apart
#
# Grepping only `subscribe_to(` / `subscribe_with_id_to(` left four spellings
# open, and each of them registers exactly the same standing REQ: `Client::
# subscribe` / `subscribe_with_id` take `Option<SubscribeAutoCloseOptions>` and
# a `None` there IS the long-lived form, `RelayPool::subscribe_targeted` fans
# one out per relay, and `Relay::subscribe` does it on a single socket.
#
# But the same names are ALSO how an auto-closing REQ is issued, and this file
# makes exactly one: `read_one_relays_answer`'s per-relay page, whose
# `SubscribeOptions` carry `close_on(ExitOnEOSE)` so the pool never records it
# in the long-lived map. The distinguishing argument is a variable, not a
# literal, so no amount of call-text reading can see it — the call declares
# itself instead, with an `// auto-closing REQ` marker on its own line or in the
# comment block directly above it (same idiom as check 4's `// negative
# control` and check 6's `// e2e helper`). The marker count is pinned by
# EQUALITY: more than one means it is being used to wave a standing REQ
# through, none means the one call this check knows about is gone and the
# scanner is no longer reading anything real.
#
# # Why check 4 is not the plan's literal wording
#
# The plan asked for "every `.add_relay(` line also matches `pool().add_relay(`".
# That is unsatisfiable: rustfmt breaks the builder chain, so the production
# sites read `client\n.pool()\n.add_relay(url, publish_relay_options())` and
# `pool()` is never on the same line as `.add_relay(`. What distinguishes a safe
# registration is the OPTIONS argument — and since `Client::add_relay` takes a
# URL and nothing else, an options argument is only reachable through
# `RelayPool::add_relay`, so it is an exact proxy for the pool-level call under
# any formatting. The check therefore reads each `.add_relay(` call's full
# argument list (joined across lines until the parentheses balance, on a
# comment-stripped view) and requires `publish_relay_options()` in it. A bare
# `Client::add_relay` — the call that ORs `READ|WRITE|PING` back onto an
# already-registered relay and silently restores the keepalive on every socket —
# has no such argument and fails.
#
# The one exception is the test that DOCUMENTS that crate behaviour
# (`client_add_relay_ors_ping_back_onto_a_registered_relay`); it is allowlisted
# by a trailing `// negative control` marker, and the marker must appear on
# exactly one line: more means it is being used to smuggle a real call past the
# check, none means the canary that justifies this whole check is gone.
#
# Passing `publish_relay_options()` is necessary but not sufficient: the type is
# a builder, so `publish_relay_options().ping(true)` satisfies the substring
# while restoring the very keepalive check 3 exists to remove. Check 4
# therefore ALSO rejects a registration whose call text overrides any of the
# four power/flag options the pinned defaults settle (`.ping(`, `.flags(`,
# `.read(`, `.write(`).
#
# Usage:
#   check_engine_client_options.sh              # check the tree
#   check_engine_client_options.sh --self-test  # hermetic fixtures, no repo read
#
# Exit codes:
#   0  all checks pass
#   1  at least one check failed
#   2  expected paths missing (misconfiguration)

set -uo pipefail
LITERAL_FREE="$(cat "$(dirname "${BASH_SOURCE[0]}")/lib/literal_free.awk")"
readonly LITERAL_FREE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_SRC_DIR="${REPO_ROOT}/haven-core/src"
FFI_SRC_DIR="${REPO_ROOT}/haven/rust_builder/src"
SOAK_SRC_DIR="${REPO_ROOT}/tooling/soak/src"
SESSION_FILE="${CORE_SRC_DIR}/relay/live_sync/session.rs"
MANAGER_FILE="${CORE_SRC_DIR}/relay/manager.rs"
API_FILE="${FFI_SRC_DIR}/api.rs"

FAILED=0

log() {
  printf '\033[1;34m[check_engine_client_options]\033[0m %s\n' "$*"
}

# Failure sink for the function-shaped checks: each sets `_lf` and returns it,
# so the caller keeps going and `--self-test` can drive them against fixtures.
_lf=0
lfail() {
  printf '\033[1;31m[check_engine_client_options] FAIL:\033[0m %s\n' "$*" >&2
  _lf=1
}

# ---------------------------------------------------------------------------
# Comment-stripped view of a Rust file, line numbering preserved.
#
# `//` starts a comment UNLESS it is preceded by `:` — otherwise every
# `"wss://relay"` literal would truncate its own line, and a `.add_relay(` that
# followed a URL on the same line would vanish from the view, i.e. pass check 4
# for want of being seen.
# ---------------------------------------------------------------------------
code_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else {
          two = substr(line, i, 2)
          prev = (i > 1) ? substr(line, i - 1, 1) : ""
          if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//" && prev != ":") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

# The body of `fn <name>`, comment-stripped and flattened onto one line, so a
# chain rustfmt split (or joined) reads the same either way.
fn_body_flat() { # <fn-name> <file>
  code_view "$2" | awk -v sig="fn $1" "${LITERAL_FREE}"'
    index($0, sig) > 0 { inbody = 1 }
    inbody {
      print
      lfree = literal_free($0); o = gsub(/[{]/, "&", lfree); c = gsub(/[}]/, "&", lfree)
      depth += o - c
      if (seen && depth <= 0) exit
      if (o > 0) seen = 1
    }' | tr '\n' ' ' | tr -s ' '
}

# Whether the subscribe call at <line> is declared auto-closing: the marker sits
# either on the call's own line or anywhere in the contiguous `//` comment block
# directly above it (rustfmt owns the call line's width, so a trailing marker on
# a long chain is not always available).
marked_auto_closing() { # <file> <line>
  local file="$1" n="$2" raw
  raw="$(sed -n "${n}p" "${file}")"
  [[ "${raw}" == *"// auto-closing REQ"* ]] && return 0
  while (( n > 1 )); do
    n=$((n - 1))
    raw="$(sed -n "${n}p" "${file}")"
    [[ "${raw}" =~ ^[[:space:]]*// ]] || return 1
    [[ "${raw}" == *"// auto-closing REQ"* ]] && return 0
  done
  return 1
}

# Every `.add_relay(` call in a file, as `<line-number><TAB><call text>`, where
# the call text is joined forward until its parentheses balance. Reads the
# comment-stripped view, so a call described in prose is not a call.
add_relay_calls() { # <file>
  code_view "$1" | awk '
    function depth_of(t,   i, d, c) {
      d = 0
      for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c == "(") d++
        else if (c == ")") d--
      }
      return d
    }
    { code[NR] = $0 }
    END {
      for (n = 1; n <= NR; n++) {
        p = index(code[n], ".add_relay(")
        if (p == 0) continue
        text = substr(code[n], p)
        m = n
        while (depth_of(text) > 0 && m < NR) { m++; text = text " " code[m] }
        gsub(/[ \t]+/, " ", text)
        print n "\t" text
      }
    }'
}

# ---------------------------------------------------------------------------
# 1. Nobody turns `verify_subscriptions` on, anywhere in either crate's source.
#    Whitespace-tolerant so `verify_subscriptions( true )` cannot slip through.
# ---------------------------------------------------------------------------
check_no_verify_subscriptions_enabled() { # <dir>...
  _lf=0
  local enabled
  enabled="$(grep -rnE 'verify_subscriptions[[:space:]]*\([[:space:]]*true[[:space:]]*\)' "$@" 2>/dev/null)"
  if [[ -n "${enabled}" ]]; then
    printf '%s\n' "${enabled}" >&2
    lfail "(1) verify_subscriptions(true) drops the stored events a REQ replays before nostr-relay-pool registers that REQ's filter — silently, while the EOSE still advances the cursor past them. The filter is re-checked in live_sync::supervisor::plane_wants_event instead."
  fi
  return "$_lf"
}

# ---------------------------------------------------------------------------
# 2 + 5. The engine client's file: it states the `verify_subscriptions` choice
#        explicitly, and it never acquires the publish pool's power options.
# ---------------------------------------------------------------------------
check_engine_pool_options() { # <session.rs>
  local session="$1"
  _lf=0

  if ! grep -qE 'verify_subscriptions[[:space:]]*\([[:space:]]*false[[:space:]]*\)' "${session}"; then
    lfail "(2) $(basename "${session}") no longer pins verify_subscriptions(false) on the engine client — the engine must not inherit the SDK default for an option that silently drops a REQ's first stored events"
  fi

  # Read the comment-stripped view: two comments in this file name
  # `sleep_when_idle` deliberately (explaining why `Sleeping` is unreachable
  # here), and describing the option is not enabling it.
  local code hits
  code="$(code_view "${session}")"

  hits="$(printf '%s\n' "${code}" | grep -nE '\.ping[[:space:]]*\([[:space:]]*false')"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" >&2
    lfail "(5) the engine pool turned its keepalive OFF. Its socket holds a standing REQ and carries no other traffic, so without the ping a NAT-dropped connection stays silently dead until the 15-minute health tick — the receive blackout the publish pool cannot suffer (it has no standing REQ) and this one can."
  fi

  hits="$(printf '%s\n' "${code}" | grep -nE '\.sleep_when_idle[[:space:]]*\(')"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" >&2
    lfail "(5) the engine pool set sleep_when_idle. The engine is the always-listening half: a socket allowed to sleep between REQ generations stops delivering, and no caller learns it went away."
  fi

  # (8) The background burst's close path.
  local pause
  local locked=''
  pause="$(fn_body_flat 'pause_subscriptions' "${session}")"
  # The rules read the wrapper AND the body it delegates to: a shutdown or a
  # forget added beside the delegation is the same defect as one inside it.
  if [[ "${pause}" == *"self.pause_locked("* ]]; then
    locked="$(fn_body_flat 'pause_locked' "${session}")"
    [[ -n "${locked}" ]] && pause+=" ${locked}" || pause=''
  fi
  if [[ -z "${pause}" ]]; then
    lfail "(8) $(basename "${session}") defines no pause_subscriptions(), or no pause_locked() for it to call — the background burst has no close path, so the engine holds its standing REQ and its socket between publish ticks and P4's whole saving is gone."
  else
    if [[ "${pause}" != *"note_delivery_gap"* && "${pause}" != *"RawSignal::Pause"* ]]; then
      lfail "(8) pause_subscriptions() neither calls note_delivery_gap nor sends the RawSignal::Pause marker that reaches it. Without one of them the pause closes every REQ while leaving each open generation still owed an advance, so the next burst's EOSE advances the cursor over a window this one interrupted."
    fi
    if [[ "${pause}" == *"forget_"* ]]; then
      lfail "(8) pause_subscriptions() calls a forget_* on an anchor. forget DROPS the generation's un-applied hold-back, so the next burst's EOSE advances the cursor past an event this device could not apply and no plane ever re-requests it (Security Rule 12). Use note_delivery_gap, which suppresses the advance and KEEPS the hold-back."
    fi
    if [[ "${pause}" != *"terminate_all_relays("* ]]; then
      lfail "(8) pause_subscriptions() no longer calls terminate_all_relays(). That call IS the radio off: without it the sockets stay open between publish ticks — the 55 s pinger keeps waking the radio and the pause saves nothing. A bare client.disconnect() is not a substitute; it can leave a connection task alive on the crate's retry schedule (see terminate_all_relays' own doc)."
    fi
    if [[ "${pause}" == *"client.shutdown()"* ]]; then
      lfail "(8) pause_subscriptions() calls client.shutdown(). shutdown EMPTIES the relay pool (force_remove_all_relays), so the next burst's subscribe fails with the opaque 'no relays'. A pause must disconnect() — Terminated, registrations intact — never shut down."
    fi
  fi

  # (8) ...and the helper the pause delegates that radio-off step to must still
  #     BE a disconnect. Requiring only the CALL above would pin a name: a
  #     `terminate_all_relays` that logs and returns satisfies it while the
  #     pause silently stops closing sockets.
  local terminate
  terminate="$(fn_body_flat 'terminate_all_relays' "${session}")"
  if [[ -z "${terminate}" ]]; then
    lfail "(8) $(basename "${session}") defines no terminate_all_relays() — the pause's radio-off step is delegated to a function this scanner cannot find, so nothing below reads anything and the disconnect is pinned nowhere."
  else
    if [[ "${terminate}" != *"client.disconnect()"* ]]; then
      lfail "(8) terminate_all_relays() no longer calls client.disconnect(). The pause's radio-off step is now a name that closes no socket: the engine holds its connections between publish ticks, the 55 s pinger keeps waking the radio, and every other check here stays green."
    fi
    if [[ "${terminate}" == *"client.shutdown()"* ]]; then
      lfail "(8) terminate_all_relays() calls client.shutdown(). shutdown EMPTIES the relay pool (force_remove_all_relays), and this helper runs on the PAUSE path — so the next burst's subscribe fails with the opaque 'no relays'. Terminate must disconnect() — Terminated, registrations intact; stop_inner does the shutdown itself, after this."
    fi
    if [[ "${terminate}" != *"unterminated_relay_count("* && "${terminate}" != *".status()"* ]]; then
      lfail "(8) terminate_all_relays() never re-reads relay status after disconnecting. Disconnect-and-return is the PRE-FIX behaviour under a new name: the crate stores Terminated AFTER firing its termination notify, so a task woken in that gap re-arms its retry loop and re-opens a real socket over the pause. The re-read is what tells a converged pool from that strand."
    fi
    if [[ "${terminate}" != *"for "* && "${terminate}" != *"while "* && "${terminate}" != *"loop {"* ]]; then
      lfail "(8) terminate_all_relays() disconnects once instead of re-asserting in a loop. The re-assert IS the repair: disconnect() early-returns only on an already-terminal status, so a relay stranded at Disconnected gets a FRESH permit on the next round and its sleeping connection task breaks on it. One round leaves the strand to the radio-off watch alone."
    fi
    local timer
    for timer in 'sleep(' 'sleep_until(' 'timeout(' 'timeout_at(' 'Duration::'; do
      if [[ "${terminate}" == *"${timer}"* ]]; then
        lfail "(8) terminate_all_relays() waits on the clock (\`${timer}\`). It runs after the pause's deliberately uncapped Rule-13 publish-gauge wait and must hold no timer: each round yields once, and convergence is decided by the status read, never by a duration. A sleep here also passes on an idle host — where the race does not reproduce — while hiding it on a loaded one."
        break
      fi
    done
  fi

  # (8) No standing REQ from the background-burst entry point.
  local burst
  burst="$(fn_body_flat 'resume_burst' "${session}")"
  if [[ -z "${burst}" ]]; then
    lfail "(8) $(basename "${session}") defines no resume_burst() — the burst entry point this check scans is gone, so the standing-REQ scan below reads nothing."
  else
    local spelling
    for spelling in 'subscribe_long_lived' 'subscribe_to(' 'subscribe_with_id(' 'subscribe_with_id_to(' 'subscribe_targeted('; do
      if [[ "${burst}" == *"${spelling}"* ]]; then
        lfail "(8) resume_burst() opens a standing REQ directly (\`${spelling}\`). Every REQ a burst issues must go through register_and_subscribe, which opens the cursor-anchor generation at the same instant it derives the REQ's \`since\` and records the accepted endpoints the burst waits on. A REQ issued around that path anchors nothing and is waited on by nobody."
      fi
    done
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 3 + 4 + 7. The publish pool's file: the options exist, every registration
#            passes them, and nothing here opens a standing REQ.
# ---------------------------------------------------------------------------
check_publish_pool_options() { # <manager.rs>
  local manager="$1" base
  base="$(basename "${manager}")"
  _lf=0

  # (3) The options function still says what it says.
  local body
  body="$(fn_body_flat 'publish_relay_options' "${manager}")"
  if [[ -z "${body}" ]]; then
    lfail "(3) ${base} defines no publish_relay_options() — the publish pool would fall back to the SDK default (READ|WRITE|PING, no idle sleep) and resume waking the radio every 55 s per relay for a socket nothing is listening on"
  else
    local want
    for want in 'ping[[:space:]]*\([[:space:]]*false' \
      'reconnect[[:space:]]*\([[:space:]]*false' \
      'sleep_when_idle[[:space:]]*\([[:space:]]*true'; do
      if ! grep -qE "\.${want}" <<<"${body}"; then
        case "${want}" in
          ping*) lfail "(3) publish_relay_options() no longer sets .ping(false) — that keepalive is ~65 radio wakes an hour keeping alive a socket that holds no subscription" ;;
          reconnect*) lfail "(3) publish_relay_options() no longer sets .reconnect(false) — the idle monitor runs only inside a live connection task, so a DROPPED relay with reconnection on never reaches Sleeping and retries every 10-60 s forever" ;;
          *) lfail "(3) publish_relay_options() no longer sets .sleep_when_idle(true) — the burst socket would be held open between publishes for nothing" ;;
        esac
      fi
    done
  fi

  # (4) Every registration passes those options; exactly one marked exception.
  local allowlisted=0 lineno call raw
  while IFS=$'\t' read -r lineno call; do
    [[ -n "${lineno}" ]] || continue
    raw="$(sed -n "${lineno}p" "${manager}")"
    if [[ "${call}" == *"publish_relay_options()"* ]]; then
      # ...but the options type is a BUILDER, so carrying the call is not the
      # same as keeping what it returns. Any override of the four settings the
      # pinned defaults decide is the regression check 3 forbids, re-introduced
      # one method call further along the chain.
      local override
      for override in '.ping(' '.flags(' '.read(' '.write('; do
        if [[ "${call}" == *"${override}"* ]]; then
          lfail "(4) ${base}:${lineno}: add_relay passes publish_relay_options() and then overrides it with \`${override}\`. The builder returns a new value, so this registers a relay with options the pinned defaults never agreed to — a restored keepalive, or read/write flags the publish pool does not use."
        fi
      done
      continue
    fi
    if [[ "${raw}" == *"// negative control"* ]]; then
      allowlisted=$((allowlisted + 1))
      continue
    fi
    lfail "(4) ${base}:${lineno}: add_relay called without publish_relay_options(). A bare Client::add_relay ORs READ|WRITE|PING onto an already-registered relay (nostr-sdk 0.44.1 client/mod.rs:300) and the pinger re-reads that flag live, so one such call silently restores the keepalive on every publish socket. Register through client.pool().add_relay(url, publish_relay_options())."
  done < <(add_relay_calls "${manager}")

  if (( allowlisted != 1 )); then
    lfail "(4) ${base}: found ${allowlisted} '// negative control' add_relay marker(s), expected exactly 1. More than one means the marker is being used to smuggle a real registration past this check; none means client_add_relay_ors_ping_back_onto_a_registered_relay — the test that proves the crate still ORs PING back, and therefore the reason this check exists — is gone."
  fi

  # (7) No standing REQ on the publish pool — every spelling, not just the two
  #     `*_to` ones. The auto-closing page read declares itself with a marker.
  local code hit lineno auto_closing=0
  code="$(code_view "${manager}")"
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    lineno="${hit%%:*}"
    if marked_auto_closing "${manager}" "${lineno}"; then
      auto_closing=$((auto_closing + 1))
      continue
    fi
    printf '%s\n' "${hit}" >&2
    lfail "(7) ${base}:${lineno} opens a standing REQ. A subscription registered here keeps the ping-less publish socket from ever sleeping, and a REQ on a pool with no keepalive dies silently at the first NAT drop — the receive-blackout class the publish pool has no way to detect. Live subscriptions belong to the engine (live_sync::session); if this REQ really auto-closes on EOSE, say so with an '// auto-closing REQ' marker on its own line or directly above it."
  done < <(printf '%s\n' "${code}" | grep -nE '\.subscribe(_to|_with_id|_with_id_to|_targeted)?[[:space:]]*\(')

  if (( auto_closing != 1 )); then
    lfail "(7) ${base}: found ${auto_closing} '// auto-closing REQ' marker(s), expected exactly 1. More than one means the marker is being used to wave a standing REQ through; none means read_one_relays_answer's per-relay page — the only subscribe this pool may make, and the call that proves this scanner still matches anything — is gone."
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 6. The FFI crate registers nothing itself. Its one bare `add_relay` builds a
#    throwaway client inside an e2e helper, marked so it can be excluded by
#    name rather than by hoping nobody adds another.
# ---------------------------------------------------------------------------
check_ffi_add_relay() { # <api.rs>
  local api="$1" base
  base="$(basename "${api}")"
  _lf=0

  local marked=0 lineno call raw
  while IFS=$'\t' read -r lineno call; do
    [[ -n "${lineno}" ]] || continue
    raw="$(sed -n "${lineno}p" "${api}")"
    if [[ "${raw}" == *"// e2e helper"* ]]; then
      marked=$((marked + 1))
      continue
    fi
    lfail "(6) ${base}:${lineno}: bare add_relay on the FFI side. Relay registration belongs to RelayManager, which passes publish_relay_options(); a Client::add_relay reached through the bridge ORs PING back onto every relay it names. If this really is a throwaway test client, mark the line '// e2e helper'."
  done < <(add_relay_calls "${api}")

  if (( marked > 1 )); then
    lfail "(6) ${base}: ${marked} lines carry the '// e2e helper' marker, expected at most 1 — the allowlist is a single documented throwaway client, not a way to opt out of the check."
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 9. The bridge is a PURE FORWARDER for the whole background-burst lifecycle.
#
#    Seven `LiveSyncFfi` methods exist only to hand a call to the core method of
#    the SAME NAME. The core owns the burst state machine; the bridge owns
#    nothing, and every decision it takes instead of forwarding is invisible —
#    `rust_builder` has no test that ever constructs a `LiveSyncFfi`, and the
#    Dart tests drive a fake that never crosses the bridge, so a body replaced
#    by `Ok(())` compiles, passes clippy, passes `cargo test --lib` and passes
#    `flutter test`.
#
#    Each method gets three rules, because there are three ways to go quiet:
#
#      (a) it must CALL `core.<same-name>(`. This is the gutting case, and its
#          only symptom is off-device: a `pause_subscriptions` that never pauses
#          holds the standing REQ, the socket and the 55 s pinger between
#          publish ticks — the whole saving P4 exists for.
#      (b) it must make EXACTLY ONE call on the `core` handle. Two means the
#          bridge is choosing between core entry points, which is precisely the
#          decision it is not allowed to take.
#      (c) every `return` in it must be `return Err(` — the session gate, and
#          nothing else. A guarded bypass
#          (`if core.is_paused() { return core.resume_after_background()...; }`)
#          leaves the required call textually PRESENT and unreachable, and that
#          is worse than swapping it: every burst opens from `Paused`, so the
#          condition holds at 100% of burst opens and the correct call is dead
#          code. Rules (a) and (b) read text; only (c) makes the check about
#          reachability, which is what the promise actually is.
#
#    `?` is not a `return` and is not counted: it propagates an error, it cannot
#    skip past the forwarding with a success.
#
#    Rules (a) and (b) read the handle by NAME, so the engine `Arc` must stay
#    bound as `core` in these eight methods. That is a convention this guard
#    imposes and cannot infer — a rename fails rule (a) with "does not forward",
#    which is the right place to learn about it.
#
#    Whitespace is squeezed out before matching, so rustfmt may split or join
#    the builder chain freely without moving this check either way.
#
#    Two of the eight are also each other's most plausible wrong destination, and
#    each direction is silent in its own way. `LiveSyncCore` deliberately splits
#    `resume_after_background` (the foreground re-anchor — app resume and the
#    health tick's whole-session repair, which must always carry the inbox REQ)
#    from `open_background_burst` (the burst, which takes the
#    `INBOX_BURSTS_PER_REQ` fold and advances the counter deciding it). Rust
#    cannot tell the callers apart, so the distinction survives only in the
#    bridge. Forwarding the burst to `resume_after_background` leaves the fold
#    NEVER applied: every burst asks each inbox relay for the full bounded
#    lookback, which is the metadata cost the fold exists to remove — and
#    nothing goes red, because the receive path still works. Forwarding the
#    foreground re-anchor to the burst consumes a fold position on every app
#    resume, so an open app can go a whole fold period unable to receive an
#    invitation.
# ---------------------------------------------------------------------------

# The forwarding surface, in call order. Each name is BOTH the bridge method and
# the core method it must reach.
FFI_DELEGATIONS=(
  'resume_after_background'
  'open_background_burst'
  'wait_backlog_settled'
  'settle_before_pause'
  'pause_subscriptions'
  'pool_subscription_count'
  'in_flight_publishes'
  'drive_pool_connected_relays'
)

check_ffi_core_delegations() { # <api.rs>
  local api="$1" base
  base="$(basename "${api}")"
  _lf=0

  local name body calls rets errs
  for name in "${FFI_DELEGATIONS[@]}"; do
    body="$(fn_body_flat "${name}" "${api}")"
    body="${body// /}"

    if [[ -z "${body}" ]]; then
      lfail "(9) ${base} exposes no ${name}(). $(_delegation_why "${name}")"
      continue
    fi

    # (c) Reachability, before anything that reads text: a body that can return
    #     early keeps the required call and never makes it.
    rets="$(grep -o 'return' <<<"${body}" | grep -c .)"
    errs="$(grep -o 'returnErr(' <<<"${body}" | grep -c .)"
    if (( rets != errs )); then
      lfail "(9) ${base}: ${name}() can return before it reaches core.${name}() — it has $(( rets - errs )) \`return\` that is not the session gate's \`return Err(\`. A forwarding method takes no decision of its own: the required call being PRESENT in the text is not the same as it being reached, and a guarded bypass runs at 100% of the calls whose condition holds."
    fi

    # (a) It must make the call this method exists to make. n == 0 lands here.
    if [[ "${body}" != *"core.${name}("* ]]; then
      lfail "(9) ${base}: ${name}() does not forward to the core's ${name}(). $(_delegation_why "${name}")"
    fi

    # (b) ...and only that one. A second call is the bridge choosing between
    #     core entry points, which is a decision the core owns.
    local n
    n="$(grep -o 'core\.[a-zA-Z0-9_]*(' <<<"${body}" | grep -c .)"
    if (( n > 1 )); then
      calls="$(grep -o 'core\.[a-zA-Z0-9_]*(' <<<"${body}" | LC_ALL=C sort -u | tr '\n' ' ')"
      lfail "(9) ${base}: ${name}() makes ${n} call(s) on the core handle (${calls}); a forwarding method makes exactly one. Choosing between core entry points here is a decision taken where nothing can observe it — no test in rust_builder constructs a LiveSyncFfi, and the Dart tests never cross the bridge."
    fi

    # The foreground re-anchor's own wrong destination gets its own message: it
    # is the direction that silently burns a fold position on every app resume.
    if [[ "${name}" == 'resume_after_background' && "${body}" == *"open_background_burst("* ]]; then
      lfail "(9) ${base}: resume_after_background() forwards to the BURST entry point. A foreground re-anchor would then consume a fold position, and an open app could go a whole fold period without an inbox REQ."
    fi
  done

  return "$_lf"
}

# What each forwarding buys, so a red run says what breaks rather than which
# grep failed. One sentence each, on the same rule as every message here: name
# the user-visible loss, not the code shape.
_delegation_why() { # <name>
  case "$1" in
    resume_after_background)
      printf '%s' "App resume and the subscription-health tick have no whole-session re-anchor left, so an open app stops repairing its own subscriptions." ;;
    open_background_burst)
      printf '%s' "Any other core call skips the burst counter, so the INBOX_BURSTS_PER_REQ fold silently never applies and every burst re-requests the whole bounded inbox lookback." ;;
    wait_backlog_settled)
      printf '%s' "A body that answers without asking the core reports Settled for a wait that never happened, so the burst encrypts its location at the epoch it held BEFORE a peer's commit landed — peers decrypt it from a past-epoch key until a later burst converges them." ;;
    settle_before_pause)
      printf '%s' "Without the core's settle, the pause that follows can cut a commit between SEND and OK (Security Rule 13): wait_for_ok fails, publish_failed rolls the group back to the prior epoch, and the relay may already have stored and served that commit — a roster fork." ;;
    pause_subscriptions)
      printf '%s' "A burst that never pauses holds its standing REQ, its socket and the 55 s pinger between publish ticks — the entire saving P4 exists for, falsified with no observable but battery, hours later and off-device." ;;
    pool_subscription_count)
      printf '%s' "This is the direct read of the burst promise 'no standing REQ between publish ticks'; a body that answers a constant makes the e2e oracle built on it pass VACUOUSLY, which is worse than having no oracle." ;;
    in_flight_publishes)
      printf '%s' "This is the Rule-13 gauge read; a body that answers a constant makes 'no publish was cut off' assert nothing." ;;
    drive_pool_connected_relays)
      printf '%s' "This is the read of 'no NIP-77 session and no drive socket stands between bursts'; a body that answers a constant makes P2c's socket half pass VACUOUSLY." ;;
    *)
      printf '%s' "Unknown delegation — add its reason to _delegation_why alongside the name." ;;
  esac
}

# ---------------------------------------------------------------------------
# 10. The two SYNC session reads answer from the session, and cannot panic.
#
#     `is_running` and `is_paused` are `#[frb(sync)]`: they run on the Dart
#     caller's thread, so a panic in either unwinds INTO Dart rather than
#     returning an error. The invariant that forbids it is stated verbatim on
#     `SESSION` ("every access uses `.map_err(...)` and NEVER `.unwrap()`") and
#     nothing else holds it: `clippy::unwrap_used` and `expect_used` are
#     restriction lints and are not enabled, so `SESSION.read().expect("...")`
#     passes the whole gate.
#
#     Panic-freedom alone would hold vacuously for a body that answers a
#     constant, so two positive rules go with it: the read must consult
#     `SESSION` (not a cached copy that can go stale against the one owner) and
#     it must ask the core for THIS flag. Neither pins a spelling — a
#     `map_or`/`is_some_and` rewrite satisfies both — so a refactor is free and
#     only an answer that stops depending on the session fails.
#
#     `is_paused` is the read the burst coordinator makes on every tick to decide
#     whether to re-anchor: a constant `false` there re-opens standing REQs in
#     the background, which is the exact regression P4 removes.
# ---------------------------------------------------------------------------
check_ffi_sync_reads_cannot_panic() { # <api.rs>
  local api="$1" base
  base="$(basename "${api}")"
  _lf=0

  local name body panicky
  for name in is_running is_paused; do
    body="$(fn_body_flat "${name}" "${api}")"
    body="${body// /}"

    if [[ -z "${body}" ]]; then
      lfail "(10) ${base} exposes no ${name}(). The burst coordinator decides whether to re-anchor from is_paused and whether to self-heal from is_running; without them it decides blind."
      continue
    fi

    if [[ "${body}" != *"SESSION.read()"* ]]; then
      lfail "(10) ${base}: ${name}() no longer answers from SESSION. There is exactly one live engine per MLS DB file (Security Rule 14) and SESSION is its one slot; a cached copy beside it answers for a session that may already be gone."
    fi

    if [[ "${body}" != *".${name}()"* ]]; then
      lfail "(10) ${base}: ${name}() never asks the core for ${name}(). A read that answers a constant is worse than a missing one: is_paused() pinned to false makes the burst coordinator re-anchor a PAUSED engine, re-opening standing REQs in the background, and every oracle built on the flag passes while it happens."
    fi

    for panicky in '.unwrap()' '.expect(' 'panic!' 'unreachable!' 'todo!'; do
      if [[ "${body}" == *"${panicky}"* ]]; then
        lfail "(10) ${base}: ${name}() contains \`${panicky}\`. A #[frb(sync)] read runs on the Dart caller's thread, so this unwinds ACROSS the FFI boundary instead of returning; SESSION's own contract says every access maps the error, never unwraps it."
      fi
    done
  done

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 11. Every relay event is verified by Haven before anything acts on it.
#
#     `nostr-relay-pool` 0.44.3 skips verification for an event whose CLAIMED
#     id it has verified before (`SharedState::verify_and_cache`), so a relay
#     that holds no key can replay a seen id over another author, other content
#     or another signature and be believed — on every plane Haven reads a relay.
#     The policy in `relay/verified.rs` re-verifies each event in the pool's
#     admission hook, which runs before the pool's database, before its
#     id-keyed stream de-duplication and before every notification. It only
#     runs on a client that was built with it, so the whole guarantee is "no
#     client is built anywhere else" — and a second construction is one
#     plausible line (`Client::builder().build()`) that passes every test,
#     because an honest relay never forges.
#
#     What is pinned:
#       * the constructor still installs THAT policy (`.admit_policy(VerifiedEvents)`),
#         names `admit_policy` exactly once, and holds the file's only
#         construction outside its test module — above the module or below
#         it. Once, because the builder keeps the LAST policy it is given, so a
#         second `.admit_policy(...)` after the first silently replaces it; and
#         never as an assignment, because the builder's field is public and
#         `builder.admit_policy = None` unsets it;
#       * the client is given no gossip store: the file's product code does
#         not say `gossip` at all, so neither the builder call (`.gossip(`)
#         nor an assignment to the builder's public field passes. The SDK
#         hands every event to a gossip store BEFORE it asks the policy
#         (`nostr-sdk-0.44.1/src/client/middleware.rs:34-46`), so a forged
#         relay list would be taken in there and refused only afterwards;
#       * the policy still calls `verify()` — id AND signature — and neither
#         half alone: a signature covers only the claimed id, so
#         `verify_signature()` passes any fields swapped under a genuine id;
#       * the policy says nothing: no log macro and no rejection reason. It runs
#         once per frame a relay chooses to send, and anything it rendered would
#         be relay-chosen (Security Rule 15);
#       * no other file constructs a `Client`, a `RelayPool` or a `Relay`. Read
#         over a comment-stripped view flattened onto one line with no space
#         beside punctuation, so a chain rustfmt wrapped (`Client::⏎builder(`)
#         is one token; an import alias, a type alias and the `<Client>::`
#         form are refused because the scan could not follow them;
#       * no `.database()` read: the pool's database is a second source of
#         events this guard does not reason about;
#       * no signer on any relay client: the words `set_signer` and
#         `unset_signer`, and `.signer(` / `::signer(` with or without a
#         turbofish (`.signer::<Keys>(`), appear nowhere in the three trees —
#         so `set_signer::<Keys>(`, the path-qualified call
#         (`ClientBuilder::signer(b, k)`) and a method reference to
#         `set_signer` or to a builder's `signer` (`ClientBuilder::signer`,
#         passed as a function) are refused with the plain call, and so is a
#         write to a builder's public `signer` field (`builder.signer = …`,
#         `nostr-sdk-0.44.1/src/client/builder.rs:26`); a path THROUGH a
#         module named `signer` (`nostr::signer::…`) is not one, and neither
#         is a comparison (`.signer == …`). With a signer the pool
#         answers a relay's NIP-42 challenge with the identity key on a socket
#         that carries a circle's routing id, and MDK's relay client signs an
#         unsigned non-445 event it is handed
#         (`transport-nostr-adapter/src/sdk_client.rs:668-682`);
#       * no relay client is told to authenticate: every
#         `automatic_authentication(` is `automatic_authentication(false)`.
#         Two things can be changed on a client AFTER it is built — its signer
#         (`Client::set_signer`) and this switch
#         (`Client::automatic_authentication(&self, enable)`,
#         `nostr-sdk-0.44.1/src/client/mod.rs:116`) — so both are held here,
#         and the publish client's values are read back by the test
#         `the_publish_client_holds_no_signer_and_never_authenticates`. Either
#         alone keeps the pool from answering a challenge;
#       * NOT read: `tests/`. The NIP-42 control client there holds a signer
#         and authenticates on purpose; a macro that spells either call is
#         not followed either;
#       * MDK's relay client is handed the publish client, once. MDK's adapter
#         is linked with its `sdk` feature, and `NostrSdkRelayClient` builds no
#         client: its only constructor outside its own tests is
#         `NostrSdkRelayClient::new(client: Client)`
#         (`transport-nostr-adapter/src/sdk_client.rs:258` at the pinned rev),
#         and no other linked MDK crate depends on nostr-sdk. So what it reads
#         from a relay is verified exactly when the client it is given came
#         from `verified_client`. Pinned: the type is named in
#         `relay/manager.rs` and no other source file; that file spells
#         `NostrSdkRelayClient::new(` once, tests included, inside
#         `fn fanout_transport`, as `NostrSdkRelayClient::new(self.client.clone())`;
#         and every `Self { client … }` there is `client: verified_client(…)`,
#         so `self.client` has one origin.
#
#     A test that needs a client of its own — a publisher, or a witness of what
#     a relay broadcasts — declares it with a trailing `// test witness`. The
#     allowlist is a LOCATION and a count, not a count alone: each file that
#     may carry the marker is named below with how many lines carry it, pinned
#     by EQUALITY like the other allowlists here, and in haven-core and the FFI
#     crate a marked line must sit inside a top-level `#[cfg(test)] mod`. A
#     bare total would let one witness be deleted and its marker spent on a
#     client in product code, with the count unchanged. (The soak rig's two are
#     in rig code: that crate is a test instrument throughout and never ships —
#     `check_soak_test_only.sh`.)
#
#     NOT pinned: who calls the constructor. A further caller still gets the
#     policy; only a construction that bypasses it is a defect.
#
#     What this scan cannot see, so nobody reads more into a green run:
#       * a construction it cannot spell — `let c: Client = Default::default()`
#         or a `#[derive(Default)]` on a struct holding a `Client`, where the
#         compiler infers the type; a `macro_rules!` that takes the type as an
#         identifier; a constructor a trait provides (`trait Fresh: Default`
#         implemented for `Client`). A `Client` newtype with no `Default`,
#         constructible only by `verified_client`, would close these
#         structurally; it is not done;
#       * a client built in a crate outside the three scanned trees. MDK's
#         relay adapter is such a crate and is linked with its `sdk` feature;
#         that it builds no client outside its own tests is read from its
#         source at the pinned rev, not by this scan, and has to be re-read on
#         every MDK bump (tracker `T-FORGED-COPY-SEEN`);
#       * a `RelayManager` given its client some other way than a `Self { … }`
#         literal — a field assignment after construction, or a second struct
#         in `manager.rs` whose own `self.client` reaches `fanout_transport`'s
#         spelling through a method of the same name;
#       * integration tests under `tests/`, which build bare clients freely and
#         cannot reach the product's;
#       * text inside a string literal, which reads as code here — and the
#         reverse: the comment-stripped view is not string-aware, so a string
#         literal holding `/*` makes the code after it read as a comment until
#         the next `*/`, and a construction in between is not seen.
#     The behavioural tests are what catch a call site that stops using the
#     constructor (`forged_relay_event_e2e.rs`, `forged_group_event_e2e.rs`).
#
#     What it refuses although nothing is built, and why it stays that way:
#     the `<Client>::` token also fires on a turbofish that only NAMES the
#     type — `Arc::<Client>::new(client)`, `OnceLock::<Client>::new()`,
#     `Vec::<Relay>::new()`. It is not narrowed: `Box::<Client>::default()`
#     and `Arc::<Client>::default()` are the same spelling and DO build a
#     client with no policy, and telling `::new(` from `::default(` would also
#     pass a local generic whose `new` builds its parameter. Write the holder
#     without the turbofish (`let shared: Arc<Client> = Arc::new(client);`).
# ---------------------------------------------------------------------------
readonly TEST_WITNESS_MARKER='// test witness'
# <tree>:<path under that tree's src>:<marked lines>. `core` and `ffi` entries
# must also sit inside a top-level `#[cfg(test)] mod`.
readonly -a TEST_WITNESS_FILES=(
  'core:relay/live_sync/session.rs:2'
  'ffi:api.rs:1'
  'soak:rig/doubles.rs:1'
  'soak:scenarios/s09_cursor_poisoning.rs:1'
)
# `reqwest::Client` is the Blossom HTTP client and reads no relay; it is
# renamed out of the view before the scan rather than excused after it.
readonly _CLIENT_CONSTRUCTION='(^|[^A-Za-z0-9_])(Client::(builder|new|default)|ClientBuilder|RelayPoolBuilder|RelayPool::(builder|new|default)|Relay::new|(Client|RelayPool|Relay)>::)'
readonly _SDK_RELAY_CLIENT='(^|[^A-Za-z0-9_])NostrSdkRelayClient([^A-Za-z0-9_]|$)'
readonly _CLIENT_ALIAS='(^|[^A-Za-z0-9_])(Client|ClientBuilder|RelayPool|RelayPoolBuilder|Relay) as |=([A-Za-z0-9_]+::)*(Client|RelayPool|Relay);'

# stdin, flattened onto one line with no space beside punctuation.
_tight() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ ?([^A-Za-z0-9_ ]) ?/\1/g; s/reqwest::Client/reqwest::Http/g'
}

# A top-level `#[cfg(test)] mod`: an item starting in column 0 that is a `mod`
# with `#[cfg(test)]` among the attributes directly on it, through its closing
# brace in column 0. Both readers below take the comment-stripped view, so a
# block comment that spells such a module opens none. ANY line that starts in
# column 0 and is neither an attribute nor a closing brace or parenthesis is
# taken for the item the attributes belonged to — not only one that starts
# with a letter — so a `#[cfg(test)]` on `::std::thread_local! { … }` is spent
# there and does not make the next `mod` a test module. A `)]` in column 0 is
# the end of an attribute rustfmt wrapped, and spends nothing.
readonly _TEST_MODULE_AWK='
  /^#\[cfg\(test\)\]/ { armed = 1; next }
  /^#!?\[/ { if (!inside && want == 0) print; next }
  /^[^[:space:]})]/ { inside = (armed && $0 ~ /^(pub(\([a-z]+\))? )?mod [A-Za-z_0-9]+ \{/); armed = 0 }
  want == 0 && !inside { print }
  want == NR { found = inside }
  /^\}/ { inside = 0; armed = 0 }
  END { if (want != 0) exit found ? 0 : 1 }'

# Whether <line> of <file> sits inside a top-level `#[cfg(test)] mod`.
_in_test_module() { # <file> <line>
  code_view "$1" | awk -v want="$2" "${_TEST_MODULE_AWK}"
}

# <file> without its top-level `#[cfg(test)] mod`s: everything that ships,
# whether it stands above a test module or below one.
_outside_test_modules() { # <file>
  code_view "$1" | awk -v want=0 "${_TEST_MODULE_AWK}"
}

check_relay_events_verified() { # <core-src-dir> <ffi-src-dir> <soak-src-dir>
  local core_dir="$1" ffi_dir="$2" soak_dir="$3" verified="$1/relay/verified.rs"
  _lf=0

  if [[ ! -f "${verified}" ]]; then
    lfail "(11) relay/verified.rs is gone. It holds the one relay-client constructor and the policy that verifies every relay event; without it nothing below reads anything."
    return "$_lf"
  fi

  # The file outside its tests: the policy and the constructor.
  local product
  product="$(_outside_test_modules "${verified}" | _tight)"

  local constructor
  constructor="$(fn_body_flat 'verified_client' "${verified}" | _tight)"
  if [[ -z "${constructor}" ]]; then
    lfail "(11) relay/verified.rs defines no verified_client(). That function is the one place a relay client is built, so that none can be built without the policy."
  elif [[ "${constructor}" != *".admit_policy(VerifiedEvents)"* ]]; then
    lfail "(11) verified_client() no longer installs the policy (\`.admit_policy(VerifiedEvents)\`). nostr-relay-pool 0.44.3 hands on an event whose claimed id it has seen before without checking it, so every client built here would act on a relay's forgery — and no test with an honest relay can tell."
  elif (( $(grep -o 'admit_policy' <<<"${constructor}" | wc -l) != 1 )); then
    lfail "(11) verified_client() names admit_policy more than once. The builder keeps the LAST policy it is given and its field is public, so a second \`.admit_policy(...)\` or an assignment after the first replaces VerifiedEvents while the first call still reads as installed."
  fi
  local disarm
  for disarm in 'gossip' 'admit_policy='; do
    if [[ "${product}" == *"${disarm}"* ]]; then
      lfail "(11) relay/verified.rs disarms the policy (\`${disarm}\`). The SDK hands every event to a gossip store BEFORE it asks the admission policy, so a client given one — by the builder's call or by assigning its public field — takes in a forged relay list and refuses it only afterwards; and assigning the builder's admit_policy field replaces or unsets what verified_client() installs."
    fi
  done
  if (( $(grep -oE "${_CLIENT_CONSTRUCTION}" <<<"${product}" | wc -l) != 1 )); then
    lfail "(11) relay/verified.rs must hold exactly one client construction outside its test module — verified_client()'s. A second one, above the tests or below them, is a client built without the policy, in the one file this check does not scan for them."
  fi

  local policy
  policy="$(fn_body_flat 'admit_event' "${verified}" | _tight)"
  if [[ "${policy}" != *"event.verify()"* ]]; then
    lfail "(11) the policy's admit_event() no longer calls event.verify(). verify() checks the id AND the signature; nothing else in Haven or in the pool does once an id has been seen."
  fi
  if [[ "${policy}" == *"verify_signature"* || "${policy}" == *"verify_id"* ]]; then
    lfail "(11) the policy's admit_event() checks half an event. A signature covers the claimed id alone, so verify_signature() passes any author, content, kind, tag or timestamp swapped under a genuine id; verify_id() alone passes any signature. Only verify() is both."
  fi
  if [[ "${product}" != *"struct VerifiedEvents;"* ]]; then
    lfail "(11) VerifiedEvents is no longer a field-less struct. It must hold no state: anything it kept would be state a relay can reach, one frame at a time."
  fi
  local said
  for said in 'log::' 'println!' 'eprintln!' 'dbg!' 'tracing::' 'reason:Some' 'AdmitStatus::rejected('; do
    if [[ "${product}" == *"${said}"* ]]; then
      lfail "(11) relay/verified.rs says something about an event it refused (\`${said}\`). The policy runs once per frame a relay chooses to send; whatever it logs or gives as a reason is relay-chosen text, at a rate the relay chooses (Security Rule 15). A refused event is dropped as if withheld."
    fi
  done

  # Everywhere else: no construction, no alias, no database read.
  local file rel marked view hits entry root tree want
  while IFS= read -r file; do
    [[ "${file}" == "${verified}" ]] && continue
    rel="${file#"${REPO_ROOT}/"}"
    marked="$(grep -nF -- "${TEST_WITNESS_MARKER}" "${file}" | cut -d: -f1 | tr '\n' ' ')"

    # Which allowlisted witness file this is, if any.
    tree='' want=0
    for entry in "${TEST_WITNESS_FILES[@]}"; do
      case "${entry%%:*}" in
        core) root="${core_dir}" ;;
        ffi) root="${ffi_dir}" ;;
        *) root="${soak_dir}" ;;
      esac
      entry="${entry#*:}"
      if [[ "${file}" == "${root}/${entry%:*}" ]]; then
        tree="${root}" want="${entry##*:}"
      fi
    done
    if (( $(wc -w <<<"${marked}") != want )); then
      lfail "(11) ${rel} carries $(wc -w <<<"${marked}") '${TEST_WITNESS_MARKER}' marker(s), expected exactly ${want}. The marker is allowed in the files TEST_WITNESS_FILES names and nowhere else: more, or one in another file, means it is being used to wave a client through; fewer means a witness this check knows about is gone. Change the list only with the test that needs it."
    fi

    # A marker must sit on a line that constructs something, or the pinned
    # count could be met by decoration; and in a crate that ships, inside a
    # test module, or it could be spent on a product client.
    local n
    for n in ${marked}; do
      if ! code_view "${file}" | sed -n "${n}p" | _tight | grep -qE "${_CLIENT_CONSTRUCTION}"; then
        lfail "(11) ${rel}:${n} carries '${TEST_WITNESS_MARKER}' on a line that builds no client. The marker excuses one construction on its own line and nothing else."
      fi
      if [[ -n "${tree}" && "${tree}" != "${soak_dir}" ]] && ! _in_test_module "${file}" "${n}"; then
        lfail "(11) ${rel}:${n} carries '${TEST_WITNESS_MARKER}' outside a top-level #[cfg(test)] mod. In a crate that ships the marker excuses a TEST's own client; on a line of product code it would excuse a client built without the policy."
      fi
    done

    view="$(code_view "${file}" \
      | awk -v skip="${marked}" 'BEGIN { n = split(skip, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1 } !(NR in s)' \
      | _tight)"

    hits="$(grep -oE "${_CLIENT_CONSTRUCTION}" <<<"${view}" | sort -u | tr '\n' ' ')"
    if [[ -n "${hits}" ]]; then
      lfail "(11) ${rel} builds a relay client of its own (${hits}). Only relay/verified.rs may: a client built anywhere else carries no policy, so it acts on an event a relay forged under an id it has seen. Call verified_client(); a test's own publisher or witness is declared with a trailing '${TEST_WITNESS_MARKER}'."
    fi
    if grep -qE "${_CLIENT_ALIAS}" <<<"${view}"; then
      lfail "(11) ${rel} renames a relay client type (an \`as\` import or a type alias of Client / RelayPool / Relay). This scan reads constructions by the type's own name, so a renamed one would be built unseen."
    fi
    if [[ "${view}" == *".database()"* ]]; then
      lfail "(11) ${rel} reads a client's database (\`.database()\`). The pool's database is a second source of relay events; Haven reads a relay only through a fetch or a notification of a client verified_client() built."
    fi
    if grep -qE '(^|[^A-Za-z0-9_])(un)?set_signer([^A-Za-z0-9_]|$)|\.signer(::<|\(|=[^=])|::signer(::<|[^A-Za-z0-9_:]|$)' <<<"${view}"; then
      lfail "(11) ${rel} gives a relay client a signer (\`set_signer\` / \`.signer(\` / \`::signer(\` / \`.signer =\`). No relay client of Haven's holds a key: with one the pool answers a relay's NIP-42 challenge with it — on the publish client that is the identity key, bound by its signature to a circle's routing id, the device's address and the time — and MDK's relay client signs an unsigned non-445 event it is handed. Events are signed where they are built, never by a client."
    fi
    if (( $(grep -o 'automatic_authentication(' <<<"${view}" | wc -l) != $(grep -o 'automatic_authentication(false)' <<<"${view}" | wc -l) )); then
      lfail "(11) ${rel} sets a relay client's \`automatic_authentication\` to something other than the literal \`false\`. It can be switched on a built client (\`Client::automatic_authentication(&self, enable)\`), and a client that authenticates answers a relay's NIP-42 challenge the day it holds a signer. Every relay client of Haven's is built with \`automatic_authentication(false)\` and none is ever told otherwise."
    fi
  done < <(grep -rlE --include='*.rs' 'Client|RelayPool|Relay|database|signer|automatic_authentication' "$@" 2>/dev/null | sort)

  # MDK's relay client: handed the publish client, once, in manager.rs.
  local manager="${core_dir}/relay/manager.rs" named handover mgr_all mgr_product
  named="$(grep -rlE --include='*.rs' "${_SDK_RELAY_CLIENT}" "$@" 2>/dev/null | sort | tr '\n' ' ')"
  for file in ${named}; do
    if [[ "${file}" != "${manager}" ]] && grep -qE "${_SDK_RELAY_CLIENT}" <<<"$(code_view "${file}")"; then
      lfail "(11) ${file#"${REPO_ROOT}/"} names MDK's relay client (NostrSdkRelayClient). It builds no client and acts on whichever one it is handed, so it is handed one in relay/manager.rs alone — RelayManager::fanout_transport(), over the publish client verified_client() built. Take the transport from there."
    fi
  done
  if [[ -f "${manager}" ]]; then
    mgr_all="$(code_view "${manager}" | _tight)"
    mgr_product="$(_outside_test_modules "${manager}" | _tight)"
    handover="$(fn_body_flat 'fanout_transport' "${manager}" | _tight)"
    if (( $(grep -o 'NostrSdkRelayClient::new(' <<<"${mgr_all}" | wc -l) != 1 )) \
      || [[ "${handover}" != *'NostrSdkRelayClient::new(self.client.clone())'* ]]; then
      lfail "(11) relay/manager.rs must hand MDK's relay client the publish client exactly once: \`NostrSdkRelayClient::new(self.client.clone())\` inside fn fanout_transport, and nowhere else in the file, tests included. MDK's client verifies nothing itself (it forwards what the client it holds admits), so handed any other client it would act on a relay's forgery, and send on sockets the publish pool does not own."
    fi
    if (( $(grep -o 'Self{client' <<<"${mgr_product}" | wc -l) != $(grep -o 'Self{client:verified_client(' <<<"${mgr_product}" | wc -l) )) \
      || [[ "${mgr_product}" != *'Self{client:verified_client('* ]]; then
      lfail "(11) relay/manager.rs builds a value whose \`client\` is not \`verified_client(…)\`. fanout_transport() hands \`self.client\` to MDK's relay client, so every \`Self { client … }\` in this file has to spell where that client came from."
    fi
  fi

  # A witness file that is gone, or no longer names a client at all, was never
  # visited above.
  for entry in "${TEST_WITNESS_FILES[@]}"; do
    case "${entry%%:*}" in
      core) tree="${core_dir}" ;;
      ffi) tree="${ffi_dir}" ;;
      *) tree="${soak_dir}" ;;
    esac
    entry="${entry#*:}"
    if ! grep -qF -- "${TEST_WITNESS_MARKER}" "${tree}/${entry%:*}" 2>/dev/null; then
      lfail "(11) ${entry%:*} carries no '${TEST_WITNESS_MARKER}' marker, expected exactly ${entry##*:}. A witness this check knows about is gone; change TEST_WITNESS_FILES with the test that removed it."
    fi
  done

  return "$_lf"
}

# ---------------------------------------------------------------------------
# THE REGISTRY. One list, driven by BOTH the production run and `--self-test`.
#
# It used to be two: the production block enumerated the checks, and the
# self-test's own runner enumerated them again. Deleting a check from the
# production block therefore left every self-test fixture green — the fixtures
# proved the checks WORK, never that they RUN — and a real regression rode into
# the tree with both CI steps at rc 0. With one list a check unwired from
# production is unwired from the fixtures too, and the fixtures for it go red.
#
# The other half of that hole (a check written and never wired ANYWHERE) is
# closed by the self-test's wiring fixture, which asserts that every `check_*`
# function defined in this file is invoked from here.
# ---------------------------------------------------------------------------
run_all_checks() { # <core-src-dir> <ffi-src-dir> <manager.rs> <session.rs> <api.rs> <soak-src-dir>
  local core_dir="$1" ffi_dir="$2" manager="$3" session="$4" api="$5" soak_dir="$6" rc=0
  check_no_verify_subscriptions_enabled "${core_dir}" "${ffi_dir}" || rc=1
  check_publish_pool_options "${manager}" || rc=1
  check_engine_pool_options "${session}" || rc=1
  check_ffi_add_relay "${api}" || rc=1
  check_ffi_core_delegations "${api}" || rc=1
  check_ffi_sync_reads_cannot_panic "${api}" || rc=1
  check_relay_events_verified "${core_dir}" "${ffi_dir}" "${soak_dir}" || rc=1
  return "${rc}"
}

if [[ "${1:-}" != "--self-test" ]]; then
  for p in "${CORE_SRC_DIR}" "${FFI_SRC_DIR}" "${SOAK_SRC_DIR}"; do
    [[ -d "${p}" ]] || { echo "ERROR: ${p} not found" >&2; exit 2; }
  done
  for p in "${SESSION_FILE}" "${MANAGER_FILE}" "${API_FILE}"; do
    [[ -f "${p}" ]] || { echo "ERROR: ${p} not found" >&2; exit 2; }
  done

  log "Checking both pools' options, the burst close path, the bridge's forwarding and the one verifying client constructor ..."
  run_all_checks "${CORE_SRC_DIR}" "${FFI_SRC_DIR}" "${MANAGER_FILE}" "${SESSION_FILE}" \
    "${API_FILE}" "${SOAK_SRC_DIR}" || FAILED=1
fi

# ---------------------------------------------------------------------------
# --self-test: hermetic fixtures for the function-shaped checks above.
#
# Every fixture runs the WHOLE check set over a small tree that mirrors today's
# shapes, and asserts on the message as well as the rc — a guard that fails for
# the wrong reason is a guard that will pass for the wrong reason later. Both
# anti-vacuity directions are covered: the clean tree must PASS (including the
# two `sleep_when_idle` comments, which describe the option rather than setting
# it), and every mutation must name the check it broke.
#
# The count is pinned by EQUALITY, not a floor: a floor lets a deleted fixture
# hide under the slack.
# ---------------------------------------------------------------------------
self_test() {
  local -r SELF_TEST_FIXTURES=103
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local core="${tmp}/core" ffi="${tmp}/ffi" soak="${tmp}/soak"
  local manager="${core}/relay/manager.rs"
  local session="${core}/relay/live_sync/session.rs"
  local verified="${core}/relay/verified.rs"
  local api="${ffi}/api.rs"
  local doubles="${soak}/rig/doubles.rs"

  _clean_tree() {
    rm -rf "${core}" "${ffi}" "${soak}"
    mkdir -p "${core}/relay/live_sync" "${core}/profile" "${ffi}" "${soak}/rig" "${soak}/scenarios"

    cat >"${verified}" <<'RS'
//! A comment naming Client::builder() and verify_signature() constructs and
//! checks nothing.
#[derive(Debug)]
struct VerifiedEvents;

impl AdmitPolicy for VerifiedEvents {
    fn admit_event<'a>(
        &'a self,
        _relay_url: &'a RelayUrl,
        _subscription_id: &'a SubscriptionId,
        event: &'a Event,
    ) -> BoxedFuture<'a, Result<AdmitStatus, PolicyError>> {
        // `verify`, never `verify_signature`.
        let status = if event.verify().is_ok() {
            AdmitStatus::Success
        } else {
            AdmitStatus::Rejected { reason: None }
        };
        Box::pin(async move { Ok(status) })
    }
}

pub fn verified_client(opts: ClientOptions, monitor: Option<Monitor>) -> Client {
    let builder = Client::builder().opts(opts).admit_policy(VerifiedEvents);
    match monitor {
        Some(monitor) => builder.monitor(monitor),
        None => builder,
    }
    .build()
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn a_pool_client_without_the_policy_hands_back_a_forgery() {
        let events = fetched(&Client::builder().build()).await;
    }
}
RS

    # The Blossom HTTP client and an in-process test relay: neither is a relay
    # client, and both spell a token the scan looks for.
    cat >"${core}/profile/blossom.rs" <<'RS'
fn http() -> reqwest::Client {
    reqwest::Client::builder().build().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    async fn relay() -> LocalRelay {
        nostr_relay_builder::prelude::LocalRelay::new(RelayBuilder::default())
    }
}
RS

    cat >"${doubles}" <<'RS'
impl TestRelay {
    pub async fn start(tag: RelayTag) -> Self {
        let witness = Client::builder().build(); // test witness
        witness.subscribe(Filter::new(), None).await.expect("witness subscribes");
    }
}
RS

    cat >"${soak}/scenarios/s09_cursor_poisoning.rs" <<'RS'
async fn witness_on(url: &str) -> Client {
    let witness = Client::builder().build(); // test witness
    witness
}
RS

    cat >"${manager}" <<'RS'
const PUBLISH_POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(10);

/// Prose naming ping(false) and sleep_when_idle must satisfy nothing.
fn publish_relay_options() -> RelayOptions {
    RelayOptions::default()
        .ping(false)
        .reconnect(false)
        .sleep_when_idle(true)
        .idle_timeout(PUBLISH_POOL_IDLE_TIMEOUT)
}

impl RelayManager {
    pub fn new() -> Self {
        Self {
            client: verified_client(
                ClientOptions::default().automatic_authentication(false),
                None,
            ),
            relay_client: OnceLock::new(),
        }
    }

    // A comment naming NostrSdkRelayClient::new(other) hands nothing over.
    pub fn fanout_transport(&self) -> FanoutTransport {
        let relay_client = self
            .relay_client
            .get_or_init(|| Arc::new(NostrSdkRelayClient::new(self.client.clone())));
        FanoutTransport {
            client: self.client.clone(),
            relay_client: Arc::clone(relay_client),
        }
    }

    async fn add_relays_and_connect(client: &Client, relay_urls: &[RelayUrl]) {
        for url in relay_urls {
            match client
                .pool()
                .add_relay(url.as_str(), publish_relay_options())
                .await
            {
                Ok(newly_added) => log::debug!("add_relay({url}): {newly_added}"),
                Err(e) => log::debug!("add_relay({url}) failed: {e}"),
            }
        }
    }

    async fn read_one_relays_answer(relay: &Relay, filter: Filter) {
        let opts = SubscribeOptions::default().close_on(Some(
            SubscribeAutoCloseOptions::default().exit_policy(ReqExitPolicy::ExitOnEOSE),
        ));
        // auto-closing REQ: `opts` exits on EOSE, so nothing is registered in
        // the pool's long-lived subscription map.
        let _ = relay.subscribe_with_id(SubscriptionId::generate(), filter, opts).await;
    }
}

#[cfg(test)]
mod tests {
    const UNDIALLED_RELAY: &str = "wss://relay.example";

    #[tokio::test]
    async fn client_add_relay_ors_ping_back_onto_a_registered_relay() {
        let manager = RelayManager::new();
        manager
            .client
            .pool()
            .add_relay(UNDIALLED_RELAY, publish_relay_options())
            .await
            .expect("register without a ping");
        let client = manager.client.clone();
        client.add_relay(UNDIALLED_RELAY).await.expect("re-add"); // negative control
    }
}
RS

    cat >"${session}" <<'RS'
fn build_engine_client() -> Client {
    let client_opts = ClientOptions::default()
        .verify_subscriptions(false)
        .automatic_authentication(false);
    verified_client(client_opts, Some(Monitor::new(64)))
}

impl LiveSyncCore {
    async fn start(&self, relays: &[String]) {
        for relay in relays {
            let _ = self.client.add_relay(relay.as_str()).await;
        }
    }

    /// The background burst's close path.
    pub async fn pause_subscriptions(&self) -> LiveSyncResult<()> {
        let lifecycle = self.lifecycle.lock().await;
        self.pause_locked(&lifecycle).await
    }

    async fn pause_locked(&self, _lifecycle: &TokioMutexGuard<'_, ()>) -> LiveSyncResult<()> {
        self.paused.store(true, Ordering::Release);
        let _ = bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe_all()).await;
        let mut drained = false;
        if !self.wedged.load(Ordering::Acquire) {
            let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
            let queued = bounded(RELAY_LIFECYCLE_OP_TIMEOUT, tx.send(RawSignal::Pause { ack: ack_tx }))
                .await
                .is_ok_and(|sent| sent.is_ok());
            drained = queued && bounded(RELAY_LIFECYCLE_OP_TIMEOUT, ack_rx).await.is_ok();
        }
        if !drained {
            self.router.write().await.clear();
            self.processor.note_delivery_gap();
        }
        self.processor.wait_publishes_drained().await;
        self.terminate_all_relays().await;
        self.repair.clear();
        Ok(())
    }

    /// Radio off, PROVEN: disconnect, let a woken connection task write its
    /// status, re-read, re-assert.
    async fn terminate_all_relays(&self) {
        let mut unterminated = 0usize;
        for _ in 0..RELAY_TERMINATE_ROUNDS {
            self.client.disconnect().await;
            // A yield, never a sleep(Duration::from_millis(50)): this runs after
            // the pause's uncapped Rule-13 wait, and convergence is decided by
            // the status read rather than by the clock.
            tokio::task::yield_now().await;
            unterminated = self.unterminated_relay_count().await;
            if unterminated == 0 {
                return;
            }
        }
        log::warn!("[live_sync] radio off: {unterminated} relay(s) still hold a task");
    }

    /// The background burst's entry point.
    async fn resume_burst(&self, inbox_every: u32) -> LiveSyncResult<()> {
        let _lifecycle = self.lifecycle.lock().await;
        self.paused.store(false, Ordering::Release);
        self.rebuild_stalled_relays().await;
        self.client.connect().await;
        self.client.wait_for_connection(SUBSCRIBE_CONNECT_WAIT).await;
        self.register_and_subscribe(&group_subs, &inbox_sub, now, phase, inbox_phase)
            .await?;
        Ok(())
    }

    /// `Sleeping` is deliberately in no bucket: `build_engine_client` never
    /// enables `sleep_when_idle` (it defaults off), so the engine pool cannot
    /// produce a `Sleeping` relay.
    fn bucket(status: RelayStatus) -> Option<Bucket> {
        match status {
            // `sleep_when_idle` so `Sleeping` cannot occur.
            RelayStatus::Sleeping => None,
            _ => Some(Bucket::Other),
        }
    }
}

#[cfg(test)]
mod tests {
    async fn a_circle_added_mid_session_is_delivered() {
        let publisher = Client::builder().build(); // test witness
        let _ = publisher.add_relay(url.as_str()).await;
    }

    async fn a_burst_still_receives() {
        let publisher = Client::builder().build(); // test witness
        let _ = publisher.add_relay(url.as_str()).await;
    }
}
RS

    cat >"${api}" <<'RS'
pub struct RelayManagerFfi {
    inner: RelayManager,
}

impl LiveSyncFfi {
    /// The FOREGROUND re-anchor. Always carries the inbox REQ.
    pub async fn resume_after_background(&self) -> Result<(), String> {
        let core = SESSION
            .read()
            .map_err(|_| "session lock poisoned".to_string())?
            .as_ref()
            .map(Arc::clone);
        match core {
            Some(core) => core
                .resume_after_background()
                .await
                .map_err(|e| e.to_string()),
            None => Err("no active live-sync session".to_string()),
        }
    }

    /// The BACKGROUND entry point. Takes the inbox fold.
    pub async fn open_background_burst(&self) -> Result<(), String> {
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        core.open_background_burst()
            .await
            .map_err(|e| e.to_string())
    }

    /// Waits out this burst's stored replay before the location is encrypted.
    pub async fn wait_backlog_settled(&self) -> Result<BacklogOutcomeFfi, String> {
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        Ok(core.wait_backlog_settled().await.into())
    }

    /// Rule 13: hold the sockets open until the commit traffic quiesces.
    pub async fn settle_before_pause(&self) -> Result<(), String> {
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        core.settle_before_pause().await;
        Ok(())
    }

    /// The burst's close path.
    pub async fn pause_subscriptions(&self) -> Result<(), String> {
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        core.pause_subscriptions().await.map_err(|e| e.to_string())
    }

    /// Presence-only: the direct read of the burst promise.
    pub async fn pool_subscription_count(&self) -> Result<u32, String> {
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        Ok(u32::try_from(core.pool_subscription_count().await).unwrap_or(u32::MAX))
    }

    /// Presence-only: the Rule-13 gauge.
    pub async fn in_flight_publishes(&self) -> Result<u32, String> {
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        Ok(u32::try_from(core.in_flight_publishes()).unwrap_or(u32::MAX))
    }

    /// Presence-only: the drive pool's connected relays.
    pub async fn drive_pool_connected_relays() -> Result<u32, String> {
        let Some(core) = live_session_core()? else {
            return Err("no active live-sync session".to_string());
        };
        core.drive_pool_connected_relays()
            .await
            .map(|n| u32::try_from(n).unwrap_or(u32::MAX))
            .ok_or_else(|| "no drive pool in this live-sync session".to_string())
    }

    #[frb(sync)]
    #[must_use]
    pub fn is_running(&self) -> bool {
        SESSION
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|c| c.is_running()))
            .unwrap_or(false)
    }

    #[frb(sync)]
    #[must_use]
    pub fn is_paused(&self) -> bool {
        SESSION
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|c| c.is_paused()))
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    /// Fetches every event of `kind` from a single relay via its own throwaway
    /// client — never the publish pool.
    pub(super) async fn fetch_by_kind(relay: &str) -> Vec<nostr::Event> {
        let client = nostr_sdk::Client::builder().build(); // test witness
        client.add_relay(relay).await.expect("add relay"); // e2e helper
        client.connect().await;
        Vec::new()
    }
}
RS
  }

  # ONE list, shared with the production run — see `run_all_checks`. A check
  # unwired there is unwired here, so its fixtures go red instead of continuing
  # to certify a check that no longer runs.
  _run_all() {
    run_all_checks "${core}" "${ffi}" "${manager}" "${session}" "${api}" "${soak}"
  }

  _fixture() { # <label> <want-rc> <want-msg-substring> <mutation...>
    local label="$1" want_rc="$2" want_msg="$3"
    shift 3
    _clean_tree
    "$@"

    local out got=0
    out="$(_run_all 2>&1)" || got=$?
    checked=$(( checked + 1 ))

    if [[ "${got}" -ne "${want_rc}" ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want_rc}" "${got}" >&2
      printf '%s\n' "${out}" >&2
      fails=1
      return
    fi
    if [[ -n "${want_msg}" && "${out}" != *"${want_msg}"* ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (rc=%d, but no message matched %q)\n' "${label}" "${got}" "${want_msg}" >&2
      printf '%s\n' "${out}" >&2
      fails=1
      return
    fi
    printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
  }

  _noop() { :; }
  _sed() { sed -i "$1" "$2"; }
  # The fixture's pause folded back into one function: the wrapper's two lines
  # and the variant's signature go.
  _pause_inline() {
    sed -i -e '/^        let lifecycle = self.lifecycle.lock().await;$/,/^    async fn pause_locked(/c\        let _lifecycle = self.lifecycle.lock().await;' "$1"
  }
  _append() { printf '%s\n' "$2" >>"$1"; }

  # 1. The shapes in the tree today pass, all four checks at once — including
  #    `terminate_all_relays`'s IN-BODY comment, which spells `sleep(` and
  #    `Duration::` in prose while the helper waits on neither. That is the
  #    anti-vacuity direction for the timer pin: if it ever reads raw source
  #    instead of the comment-stripped view, it fires on the very explanation of
  #    why the helper yields, and this fixture is what catches it.
  _fixture 'the tree shape passes' 0 '' _noop

  # 2. Anti-vacuity for check 5: the file's two deliberate comments name
  #    `sleep_when_idle` (and one now spells the call form) and must not fail.
  _fixture 'a comment naming sleep_when_idle(true) still passes' 0 '' \
    _append "${session}" '// Never `.sleep_when_idle(true)` here: the engine listens continuously.'

  # 3. The option this guard was created for, turned back on.
  _fixture 'verify_subscriptions(true) fails' 1 '(1) verify_subscriptions(true)' \
    _sed 's/verify_subscriptions(false)/verify_subscriptions(true)/' "${session}"

  # 4. ...and deleting the pin instead of flipping it is the same regression,
  #    one upstream default change away.
  _fixture 'deleting the verify_subscriptions pin fails' 1 '(2)' \
    _sed '/verify_subscriptions(false)/d' "${session}"

  # 5-6. The publish pool's keepalive, restored either by editing the options
  #      or by deleting the function that holds them.
  _fixture 'ping(true) inside publish_relay_options fails' 1 '(3) publish_relay_options() no longer sets .ping(false)' \
    _sed 's/\.ping(false)/.ping(true)/' "${manager}"

  _fixture 'a missing publish_relay_options fails' 1 'defines no publish_relay_options()' \
    _sed 's/^fn publish_relay_options/fn burst_relay_opts/' "${manager}"

  # 7. The crate trap: a bare Client::add_relay ORs PING back onto every relay.
  _fixture 'a bare client.add_relay( in manager.rs fails' 1 'add_relay called without publish_relay_options()' \
    _append "${manager}" '    async fn dial(c: &Client, r: &RelayUrl) { let _ = c.add_relay(r.as_str()).await; }'

  # 8-9. The engine adopting the publish pool's options — the C3 blackout.
  _fixture 'a .ping(false) call in session.rs fails' 1 '(5) the engine pool turned its keepalive OFF' \
    _sed 's/\.verify_subscriptions(false)/.verify_subscriptions(false)\n        .ping(false)/' "${session}"

  _fixture 'a .sleep_when_idle(true) call in session.rs fails' 1 '(5) the engine pool set sleep_when_idle' \
    _sed 's/\.verify_subscriptions(false)/.verify_subscriptions(false)\n        .sleep_when_idle(true)/' "${session}"

  # 10 + 13-16. A standing REQ re-introduced on the publish pool, in each of
  #             the five spellings the pinned crates expose. Only `subscribe_to`
  #             was caught before; the other four registered exactly the same
  #             long-lived REQ and passed.
  _fixture 'subscribe_to( in manager.rs fails' 1 '(7)' \
    _append "${manager}" '    async fn sub(&self) { let _ = self.client.subscribe_to(relays, filter, None).await; }'

  _fixture 'subscribe( in manager.rs fails' 1 '(7)' \
    _append "${manager}" '    async fn sub(&self) { let _ = self.client.subscribe(filter, None).await; }'

  _fixture 'subscribe_with_id( in manager.rs fails' 1 '(7)' \
    _append "${manager}" '    async fn sub(&self) { let _ = self.client.subscribe_with_id(id, filter, None).await; }'

  _fixture 'subscribe_with_id_to( in manager.rs fails' 1 '(7)' \
    _append "${manager}" '    async fn sub(&self) { let _ = self.client.subscribe_with_id_to(relays, id, filter, None).await; }'

  _fixture 'subscribe_targeted( in manager.rs fails' 1 '(7)' \
    _append "${manager}" '    async fn sub(&self) { let _ = self.client.pool().subscribe_targeted(relays, id, filter, opts).await; }'

  # 17. The auto-closing marker used to wave a standing REQ through.
  _fixture 'a second // auto-closing REQ marker fails' 1 "expected exactly 1" \
    _append "${manager}" '    async fn sub(&self) { let _ = self.client.subscribe(filter, None).await; } // auto-closing REQ'

  # 18. The builder trap: the required argument is present, and then undone.
  _fixture 'publish_relay_options().ping(true) on a registration fails' 1 'overrides it with' \
    _sed 's/add_relay(url.as_str(), publish_relay_options())/add_relay(url.as_str(), publish_relay_options().ping(true))/' "${manager}"

  # 11. The FFI side registering a relay of its own.
  _fixture 'an unmarked add_relay in api.rs fails' 1 '(6)' \
    _append "${api}" '    async fn dial(c: &Client, r: &str) { let _ = c.add_relay(r).await; }'

  # 12. The allowlist marker used to wave a second bare call through.
  _fixture 'a second // negative control marker fails' 1 "expected exactly 1" \
    _append "${manager}" '    async fn dial(c: &Client, r: &str) { let _ = c.add_relay(r).await; } // negative control'

  # 19-21. The background burst's close path (check 8). Each of these compiles,
  #        each is silent when wrong, and each costs the user something
  #        different: a lost backlog, a dead next burst, or the standing REQ P4
  #        exists to remove.

  # 19. `forget_*` instead of `note_delivery_gap`: DROPS the un-applied
  #     hold-back, so the next burst's EOSE advances the cursor over an event
  #     this device could not apply and no plane ever re-requests it.
  _fixture 'a forget_* in the pause path fails' 1 '(8) pause_subscriptions() calls a forget_*' \
    _sed 's/self.processor.note_delivery_gap();/self.processor.forget_inbox_subscription();/' "${session}"

  # 20. `shutdown()` in the pause: EMPTIES the pool, so the next burst's
  #     subscribe fails with the opaque "no relays". Added ALONGSIDE the
  #     delegated radio-off step rather than replacing it, so this fixture still
  #     fails for its own reason: the pause reaches `terminate_all_relays()`,
  #     every helper rule holds, and only the pause's shutdown rule fires.
  _fixture 'client.shutdown() in the pause path fails' 1 '(8) pause_subscriptions() calls client.shutdown()' \
    _sed 's@        self.repair.clear();@        self.client.shutdown().await;\n        self.repair.clear();@' "${session}"

  # 21. A standing REQ opened straight from the burst entry point — the P4
  #     regression itself, and the one with no runtime symptom but battery.
  _fixture 'a standing REQ in the burst path fails' 1 '(8) resume_burst() opens a standing REQ' \
    _sed 's|self.client.wait_for_connection(SUBSCRIBE_CONNECT_WAIT).await;|self.client.subscribe_with_id_to(relays, sub_id, filter, None).await?;|' "${session}"

  # 21a. The pause's body inline in pause_subscriptions, with no lock-holding
  #      variant, is the same close path and passes.
  _fixture 'a pause body inline in pause_subscriptions passes' 0 '' \
    _pause_inline "${session}"

  # 21b. A pause_subscriptions that delegates to a pause_locked() the file does
  #      not define: every rule would read an EMPTY body and certify nothing.
  _fixture 'a pause delegating to a missing pause_locked fails' 1 \
    'or no pause_locked() for it to call' \
    _sed 's@    async fn pause_locked(@    async fn pause_now(@' "${session}"

  # 21c. A shutdown beside the delegation, in the wrapper itself.
  _fixture 'a client.shutdown() in the pause wrapper fails' 1 '(8) pause_subscriptions() calls client.shutdown()' \
    _sed 's@^        self.pause_locked(&lifecycle).await$@        self.client.shutdown().await;\n        self.pause_locked(\&lifecycle).await@' "${session}"

  # 38-44. The radio-off step, now reached through `terminate_all_relays()`.
  #        Fixture 38 is the call itself; 39-44 are what the helper must still
  #        DO, because a check that only required the call would pin a name and
  #        let a helper that closes nothing through.

  # 38. The indirection undone: a bare `client.disconnect()` back in the pause.
  #     This is the defect the helper was written for — the crate stores
  #     `Terminated` AFTER firing its termination notify, so a task woken in
  #     that gap re-arms its retry loop and re-opens a real socket the next
  #     burst silently adopts. It compiles, it reads as correct, and its only
  #     symptom is battery.
  _fixture 'a bare client.disconnect() back in the pause fails' 1 \
    '(8) pause_subscriptions() no longer calls terminate_all_relays()' \
    _sed 's@        self.terminate_all_relays().await;@        self.client.disconnect().await;@' "${session}"

  # 39. The helper renamed out of existence: the pause's call text is untouched
  #     and every rule below it reads an EMPTY body — the vacuity direction, in
  #     which a helper this scanner cannot find certifies nothing.
  _fixture 'a missing terminate_all_relays fails' 1 \
    'defines no terminate_all_relays()' \
    _sed 's@    async fn terminate_all_relays@    async fn terminate_relays_now@' "${session}"

  # 40. The name kept and the disconnect dropped: the pause still "turns the
  #     radio off" and closes no socket. Nothing else in this file can see it.
  _fixture 'a terminate_all_relays that disconnects nothing fails' 1 \
    '(8) terminate_all_relays() no longer calls client.disconnect()' \
    _sed 's@            self.client.disconnect().await;@            self.paused.store(true, Ordering::Release);@' "${session}"

  # 41. `shutdown()` added INSIDE the helper, with the disconnect left in place
  #     — the shape a reader waves through (`disconnect(); shutdown();` looks
  #     thorough) and the one that empties the pool on the PAUSE path, where the
  #     next burst still needs those registrations.
  _fixture 'client.shutdown() inside terminate_all_relays fails' 1 \
    '(8) terminate_all_relays() calls client.shutdown()' \
    _sed 's@            tokio::task::yield_now().await;@            self.client.shutdown().await;\n            tokio::task::yield_now().await;@' "${session}"

  # 42. The VERIFY half deleted: it still disconnects, still yields, still
  #     loops — and judges convergence on nothing, so the loop cannot tell a
  #     terminated pool from a stranded connection task.
  _fixture 'a terminate_all_relays that never re-reads status fails' 1 \
    '(8) terminate_all_relays() never re-reads relay status' \
    _sed '/unterminated = self.unterminated_relay_count().await;/d' "${session}"

  # 43. The RE-ASSERT half deleted: one disconnect, one read, return. That is
  #     the pre-fix behaviour under the new name — and the second round is the
  #     whole repair, because it fires a FRESH permit that a sleeping connection
  #     task breaks on without re-reading any status.
  _fixture 'a terminate_all_relays that disconnects once fails' 1 \
    '(8) terminate_all_relays() disconnects once instead of re-asserting' \
    _sed 's@        for _ in 0..RELAY_TERMINATE_ROUNDS {@        {@' "${session}"

  # 44. The yield replaced by a wait on the clock — the "give it a moment" fix.
  #     It runs after the pause's deliberately uncapped Rule-13 publish-gauge
  #     wait, and it passes on an idle host (where the race does not reproduce
  #     at all) while hiding it on a loaded one.
  _fixture 'a sleep inside terminate_all_relays fails' 1 \
    '(8) terminate_all_relays() waits on the clock (`sleep(`)' \
    _sed 's@            tokio::task::yield_now().await;@            tokio::time::sleep(RELAY_TERMINATE_SETTLE).await;@' "${session}"

  # 22-23. The bridge collapsing the two entry points onto one core method
  #        (check 9). Both compile, both keep receiving, and both are invisible
  #        at runtime — one never applies the inbox fold, the other burns a fold
  #        position on every app resume.
  _fixture 'the burst forwarding to the foreground re-anchor fails' 1 \
    '(9) api.rs: open_background_burst() does not forward' \
    _sed 's|        core.open_background_burst()|        core.resume_after_background()|' "${api}"

  _fixture 'the foreground re-anchor forwarding to the burst fails' 1 \
    '(9) api.rs: resume_after_background() forwards to the BURST' \
    _sed 's|            .resume_after_background()|            .open_background_burst()|' "${api}"

  # 24. The guarded bypass — the mutation that beat check 9 while it was a
  #     substring test. The required call is still THERE and is now dead code:
  #     every burst opens from `Paused`, so `is_paused()` holds at 100% of burst
  #     opens and the inbox fold never applies again. Strictly worse than the
  #     swap fixture 22 catches, and it read as green.
  _fixture 'a guarded bypass around the burst call fails' 1 \
    '(9) api.rs: open_background_burst() can return before it reaches' \
    _sed 's@^        core.open_background_burst()@        if core.is_paused() { return core.resume_after_background().await.map_err(|e| e.to_string()); }\n        core.open_background_burst()@' "${api}"

  # 25-29. Each forwarding replaced by an answer the bridge invents. All five
  #        compile, pass clippy, pass `cargo test --lib` (nothing in
  #        rust_builder constructs a LiveSyncFfi) and pass `flutter test` (the
  #        Dart tests use a fake and never cross the bridge).

  # 25. The engine never pauses: standing REQ, socket and 55 s pinger held
  #     between publish ticks — P4's entire saving, with no observable but
  #     battery, hours later and off-device.
  _fixture 'a gutted pause_subscriptions fails' 1 \
    '(9) api.rs: pause_subscriptions() does not forward' \
    _sed 's@core.pause_subscriptions().await.map_err(|e| e.to_string())@Ok(())@' "${api}"

  # 26. `Settled` for a wait that never happened: the burst encrypts at the
  #     epoch it held before a peer's commit landed.
  _fixture 'a gutted wait_backlog_settled fails' 1 \
    '(9) api.rs: wait_backlog_settled() does not forward' \
    _sed 's@Ok(core.wait_backlog_settled().await.into())@Ok(BacklogOutcomeFfi::Settled)@' "${api}"

  # 27. No settle: the pause that follows can cut a commit between SEND and OK
  #     (Security Rule 13) and fork the roster.
  _fixture 'a gutted settle_before_pause fails' 1 \
    '(9) api.rs: settle_before_pause() does not forward' \
    _sed '/core.settle_before_pause().await;/d' "${api}"

  # 28-29. The two presence-only oracles answering a constant. This is the
  #        vacuity direction: an e2e assertion of "no standing REQ between
  #        ticks" built on a hard-coded 0 passes forever, which is worse than
  #        having no oracle at all.
  _fixture 'pool_subscription_count answering a constant fails' 1 \
    '(9) api.rs: pool_subscription_count() does not forward' \
    _sed 's@Ok(u32::try_from(core.pool_subscription_count().await).unwrap_or(u32::MAX))@Ok(0)@' "${api}"

  _fixture 'in_flight_publishes answering a constant fails' 1 \
    '(9) api.rs: in_flight_publishes() does not forward' \
    _sed 's@Ok(u32::try_from(core.in_flight_publishes()).unwrap_or(u32::MAX))@Ok(0)@' "${api}"

  _fixture 'drive_pool_connected_relays answering a constant fails' 1 \
    '(9) api.rs: drive_pool_connected_relays() does not forward' \
    _sed 's@        core.drive_pool_connected_relays()@        Some(0_usize)@' "${api}"

  # 30. Reachability ISOLATED: the required call is present and unchanged, the
  #     core-call count is still exactly one, and only the early `return Ok(())`
  #     is wrong. Nothing but rule (c) can catch this.
  _fixture 'a non-error early return before the forwarding fails' 1 \
    '(9) api.rs: settle_before_pause() can return before it reaches' \
    _sed 's@^        core.settle_before_pause().await;@        if self.circle.is_empty() { return Ok(()); }\n        core.settle_before_pause().await;@' "${api}"

  # 31. The call-count rule ISOLATED: the required call is present AND reached
  #     on one branch, with no early return anywhere — the bridge has simply
  #     started deciding when to pause. Only rule (b) sees it.
  _fixture 'a second core call in a forwarding method fails' 1 \
    '(9) api.rs: pause_subscriptions() makes 2 call(s) on the core handle' \
    _sed 's@^        core.pause_subscriptions().await.map_err(|e| e.to_string())@        if core.is_paused() { Ok(()) } else { core.pause_subscriptions().await.map_err(|e| e.to_string()) }@' "${api}"

  # 32. The forwarding renamed out of existence: the Dart side loses the close
  #     path entirely, and a scanner that only looked at the methods it found
  #     would report nothing.
  _fixture 'a missing pause_subscriptions delegation fails' 1 \
    '(9) api.rs exposes no pause_subscriptions()' \
    _sed 's@pub async fn pause_subscriptions@pub async fn close_burst@' "${api}"

  # 33-34. The two #[frb(sync)] reads made panicky. Both pass clippy: unwrap_used
  #        and expect_used are restriction lints and are not enabled, and these
  #        run on the Dart caller's thread, so the unwind crosses the FFI.
  _fixture 'is_paused reading the lock with .expect fails' 1 \
    '(10) api.rs: is_paused() contains `.expect(`' \
    _sed '/fn is_paused/,/^    }/ s@\.ok()@.expect("session lock poisoned")@' "${api}"

  _fixture 'is_running reading the lock with .unwrap fails' 1 \
    '(10) api.rs: is_running() contains `.unwrap()`' \
    _sed '/fn is_running/,/^    }/ s@\.unwrap_or(false)@.unwrap()@' "${api}"

  # 35. Panic-freedom holds vacuously for a read that no longer reads: answering
  #     from a cached copy beside SESSION answers for a session that may already
  #     be gone (Security Rule 14 gives SESSION exactly one owner).
  _fixture 'is_paused answering from a cached copy fails' 1 \
    '(10) api.rs: is_paused() no longer answers from SESSION' \
    _sed '/fn is_paused/,/^    }/ s@SESSION@self.cached_pause_state@' "${api}"

  # 36. ...and the other vacuity direction: it still takes the lock, and then
  #     ignores what is in it. `is_paused` pinned to false makes the burst
  #     coordinator re-anchor a PAUSED engine — standing REQs back in the
  #     background, with every oracle built on the flag green throughout.
  _fixture 'is_paused answering a constant fails' 1 \
    '(10) api.rs: is_paused() never asks the core for is_paused()' \
    _sed '/fn is_paused/,/^    }/ s@c.is_paused()@true@' "${api}"

  # 45-46. The constructor without the policy, and with some other policy: a
  #        client that acts on a relay's forgery, with every test of an honest
  #        relay still green.
  _fixture 'deleting .admit_policy( fails' 1 '(11) verified_client() no longer installs the policy' \
    _sed 's/\.admit_policy(VerifiedEvents)//' "${verified}"

  _fixture 'installing some other policy fails' 1 '(11) verified_client() no longer installs the policy' \
    _sed 's/\.admit_policy(VerifiedEvents)/.admit_policy(AdmitEverything)/' "${verified}"

  # 47-48. Half a check. Each compiles, and each passes an honest relay.
  _fixture 'verify() replaced by verify_signature() fails' 1 '(11) the policy'"'"'s admit_event() checks half an event' \
    _sed 's/event\.verify()\.is_ok()/event.verify_signature()/' "${verified}"

  _fixture 'verify() replaced by verify_id() fails' 1 '(11) the policy'"'"'s admit_event() checks half an event' \
    _sed 's/event\.verify()\.is_ok()/event.verify_id()/' "${verified}"

  # 49-51. The policy growing state or a voice.
  _fixture 'a policy with a field fails' 1 '(11) VerifiedEvents is no longer a field-less struct' \
    _sed 's/^struct VerifiedEvents;/struct VerifiedEvents { refused: AtomicU64 }/' "${verified}"

  _fixture 'a log line in the policy fails' 1 '(11) relay/verified.rs says something about an event it refused (`log::`)' \
    _sed 's/^        let status = if/        log::debug!("refused {}", event.id);\n        let status = if/' "${verified}"

  _fixture 'a rejection reason fails' 1 '(11) relay/verified.rs says something about an event it refused (`reason:Some`)' \
    _sed 's/reason: None/reason: Some(event.id.to_hex())/' "${verified}"

  # 52-53. The constructor's own file: gone, or holding a second construction.
  _fixture 'a missing verified.rs fails' 1 '(11) relay/verified.rs is gone' \
    rm "${verified}"

  _fixture 'a second construction beside the constructor fails' 1 '(11) relay/verified.rs must hold exactly one client construction' \
    _sed 's/^#\[cfg(test)\]/pub fn plain_client() -> Client { Client::builder().build() }\n\n#[cfg(test)]/' "${verified}"

  # 53b. ...and below the test module, where a view that stops at the first
  #      `#[cfg(test)]` never looks.
  _fixture 'a second construction below the test module fails' 1 '(11) relay/verified.rs must hold exactly one client construction' \
    _append "${verified}" 'pub fn plain_client() -> Client { Client::builder().build() }'

  # 54-59. A client built somewhere else, in each crate and each spelling.
  _fixture 'a second Client::builder() in manager.rs fails' 1 'manager.rs builds a relay client of its own' \
    _sed 's/^            client: verified_client($/            client: Client::builder().opts(/' "${manager}"

  _fixture 'a construction rustfmt wrapped across lines fails' 1 'session.rs builds a relay client of its own' \
    _append "${session}" 'fn lookup_client() -> Client {
    Client::
        builder()
        .build()
}'

  _fixture 'a fully qualified Client::new in api.rs fails' 1 'api.rs builds a relay client of its own' \
    _append "${api}" 'fn signing_client(keys: Keys) -> nostr_sdk::Client { nostr_sdk::Client::new(keys) }'

  _fixture 'a RelayPool built in the soak rig fails' 1 'doubles.rs builds a relay client of its own' \
    _append "${doubles}" 'fn pool() -> RelayPool { RelayPool::new(RelayPoolOptions::default()) }'

  _fixture 'a bare Relay::new fails' 1 'manager.rs builds a relay client of its own' \
    _append "${manager}" 'fn one(url: RelayUrl, state: SharedState) -> Relay { Relay::new(url, state, RelayOptions::default()) }'

  _fixture 'the <Client>::default() form fails' 1 'session.rs builds a relay client of its own' \
    _append "${session}" 'fn fallback() -> Client { <Client>::default() }'

  # 60-61. A rename the scan could not follow.
  _fixture 'an aliased import fails' 1 '(11) '"${manager#"${REPO_ROOT}/"}"' renames a relay client type' \
    _append "${manager}" 'use nostr_sdk::Client as Sdk;'

  _fixture 'a type alias fails' 1 'renames a relay client type' \
    _append "${api}" 'type Sdk = nostr_sdk::Client;'

  # 62. The pool's database as a second read path.
  _fixture 'a .database() read fails' 1 '(11) '"${manager#"${REPO_ROOT}/"}"' reads a client'"'"'s database' \
    _append "${manager}" '    async fn cached(&self) -> Events { self.client.database().query(Filter::new()).await.unwrap_or_default() }'

  # 63-65. The witness allowlist: an unmarked witness, a marker too many, and a
  #        marker that marks nothing.
  _fixture 'an unmarked test client fails' 1 'api.rs builds a relay client of its own' \
    _sed 's@ // test witness@@' "${api}"

  _fixture 'a witness marker in a file that has no witnesses fails' 1 'manager.rs carries 1 '"'"'// test witness'"'"' marker(s), expected exactly 0' \
    _append "${manager}" '    fn publisher() -> Client { Client::builder().build() } // test witness'

  _fixture 'a marker on a line that builds nothing fails' 1 'on a line that builds no client' \
    _append "${manager}" '    const PUBLISHERS: usize = 1; // test witness'

  # 66-68. The allowlist is a location, not a count. One witness deleted and
  #        its marker spent on a product client — in the same file, where the
  #        file's count is unchanged, and in another file, where the total is —
  #        and a witness file that is gone altogether.
  _spend_a_marker_in() { # <file that receives the product client>
    sed -i '0,/        let publisher = Client::builder().build(); \/\/ test witness/{//d}' "${session}"
    if [[ "$1" == "${session}" ]]; then
      sed -i '0,/^#\[cfg(test)\]/s//fn lookup_client() -> Client { Client::builder().build() } \/\/ test witness\n\n#[cfg(test)]/' "${session}"
    else
      printf '%s\n' 'fn lookup_client() -> Client { Client::builder().build() } // test witness' >>"$1"
    fi
  }

  _fixture 'a marker moved onto a product client in the same file fails' 1 'outside a top-level #[cfg(test)] mod' \
    _spend_a_marker_in "${session}"

  _fixture 'a marker moved onto a product client in another file fails' 1 'session.rs carries 1 '"'"'// test witness'"'"' marker(s), expected exactly 2' \
    _spend_a_marker_in "${manager}"

  _fixture 'a witness file that is gone fails' 1 'rig/doubles.rs carries no '"'"'// test witness'"'"' marker' \
    rm "${doubles}"

  # 68b. A test module that exists only inside a block comment. rustfmt leaves
  #      a comment's inner lines in column 0, so read from the raw file the
  #      product method below it would sit "inside a test module".
  _spend_a_marker_behind_a_comment() {
    sed -i '0,/        let publisher = Client::builder().build(); \/\/ test witness/{//d}' "${session}"
    sed -i '0,/^#\[cfg(test)\]/s//impl Lookup {\n\/*\n#[cfg(test)]\nmod fake {\n*\/\n    fn client() -> Client { Client::builder().build() } \/\/ test witness\n}\n\n#[cfg(test)]/' "${session}"
  }

  _fixture 'a marker behind a commented-out test module fails' 1 'outside a top-level #[cfg(test)] mod' \
    _spend_a_marker_behind_a_comment

  # 68c. A `#[cfg(test)]` that belongs to an item starting with something other
  #      than a letter. It is spent on that item; the plain `mod` after it ships.
  _spend_a_marker_after_a_spent_attribute() {
    sed -i '0,/        let publisher = Client::builder().build(); \/\/ test witness/{//d}' "${session}"
    sed -i '0,/^#\[cfg(test)\]/s//#[cfg(test)]\n::std::thread_local! { static SEEN: Cell<bool> = const { Cell::new(false) }; }\nmod lookup {\n    pub fn client() -> Client { Client::builder().build() } \/\/ test witness\n}\n\n#[cfg(test)]/' "${session}"
  }

  _fixture 'a marker in a module after a spent #[cfg(test)] fails' 1 'outside a top-level #[cfg(test)] mod' \
    _spend_a_marker_after_a_spent_attribute

  # 68d. Anti-vacuity for 68c: an attribute rustfmt wrapped ends on a `)]` in
  #      column 0, between `#[cfg(test)]` and its `mod`. That line is no item,
  #      so the module under it is still the test module and its witnesses
  #      still stand inside one.
  _fixture 'a test module under a wrapped attribute still passes' 0 '' \
    _sed '0,/^#\[cfg(test)\]/s//#[cfg(test)]\n#[allow(\n    clippy::too_many_lines,\n    clippy::cognitive_complexity\n)]/' "${session}"

  # 69-71b. Four ways to disarm the policy inside the constructor while the
  #         `.admit_policy(VerifiedEvents)` call is still there to be read.
  _fixture 'a gossip store on the client fails' 1 '(11) relay/verified.rs disarms the policy (`gossip`)' \
    _sed 's/\.admit_policy(VerifiedEvents);/.admit_policy(VerifiedEvents).gossip(NostrGossipMemory::unbounded());/' "${verified}"

  _fixture 'a gossip store assigned to the builder'"'"'s field fails' 1 '(11) relay/verified.rs disarms the policy (`gossip`)' \
    _sed 's/^    match monitor {/    builder.gossip = Some(NostrGossipMemory::unbounded().into_nostr_gossip());\n    match monitor {/' "${verified}"

  _fixture 'a second admit_policy after the first fails' 1 '(11) verified_client() names admit_policy more than once' \
    _sed 's/\.admit_policy(VerifiedEvents);/.admit_policy(VerifiedEvents).admit_policy(AdmitEverything);/' "${verified}"

  _fixture 'assigning the builder'"'"'s admit_policy field fails' 1 '(11) relay/verified.rs disarms the policy (`admit_policy=`)' \
    _sed 's/^    match monitor {/    builder.admit_policy = None;\n    match monitor {/' "${verified}"

  # MDK's relay client: handed anything but the publish client, handed it a
  # second time, named in another file, or riding a client RelayManager was
  # given rather than built with.
  _fixture 'MDK'"'"'s relay client handed some other client fails' 1 '(11) relay/manager.rs must hand MDK'"'"'s relay client the publish client exactly once' \
    _sed 's/NostrSdkRelayClient::new(self.client.clone())/NostrSdkRelayClient::new(spare_client())/' "${manager}"

  _fixture 'a second handover in a test fails' 1 '(11) relay/manager.rs must hand MDK'"'"'s relay client the publish client exactly once' \
    _append "${manager}" '#[cfg(test)]
mod more {
    fn transport(manager: &RelayManager) -> NostrSdkRelayClient { NostrSdkRelayClient::new(manager.client.clone()) }
}'

  _fixture 'the handover moved out of fanout_transport fails' 1 '(11) relay/manager.rs must hand MDK'"'"'s relay client the publish client exactly once' \
    _sed 's/pub fn fanout_transport(&self)/pub fn another_transport(\&self)/' "${manager}"

  _fixture 'MDK'"'"'s relay client named in another file fails' 1 'session.rs names MDK'"'"'s relay client' \
    _append "${session}" 'fn sdk(client: Client) -> NostrSdkRelayClient { NostrSdkRelayClient::new(client) }'

  _fixture 'a RelayManager built around a client it was given fails' 1 '(11) relay/manager.rs builds a value whose `client` is not `verified_client' \
    _sed 's/^impl RelayManager {/impl RelayManager {\n    pub fn over(client: Client) -> Self {\n        Self { client }\n    }\n/' "${manager}"

  # A signer on a relay client: set after the build, given to a builder, or
  # taken away again (which only something that set one would do).
  _fixture 'a signer set on the publish client fails' 1 'manager.rs gives a relay client a signer' \
    _sed 's/^impl RelayManager {/impl RelayManager {\n    pub async fn arm(\&self, keys: Keys) {\n        self.client.set_signer(keys).await;\n    }\n/' "${manager}"

  _fixture 'a signer given to a builder in another file fails' 1 'session.rs gives a relay client a signer' \
    _append "${session}" 'fn signing(builder: Builder, keys: Keys) -> Builder {
    builder
        .signer(keys)
}'

  _fixture 'a signer taken off a client in the FFI crate fails' 1 'api.rs gives a relay client a signer' \
    _append "${api}" 'async fn disarm(c: &Handle) { c.unset_signer().await }'

  _fixture 'a comment naming set_signer( and a designer( call still pass' 0 '' \
    _append "${session}" '// Never `client.set_signer(keys)` here.
fn styled(d: &Design) -> Look { d.designer().look() }'

  # The spellings a `set_signer(` / `.signer(` text match walks past.
  _fixture 'a signer set through a turbofish fails' 1 'session.rs gives a relay client a signer' \
    _append "${session}" 'async fn arm(c: &Handle, keys: Keys) { c.set_signer::<Keys>(keys).await }'

  _fixture 'a signer given through a path-qualified builder call fails' 1 'session.rs gives a relay client a signer' \
    _append "${session}" 'fn signing(builder: Builder, keys: Keys) -> Builder { Builder::signer(builder, keys) }'

  _fixture 'a signer given to a builder through a turbofish fails' 1 'session.rs gives a relay client a signer' \
    _append "${session}" 'fn signing(builder: Builder, keys: Keys) -> Builder { builder.signer::<Keys>(keys) }'

  _fixture 'a method reference to set_signer fails' 1 'api.rs gives a relay client a signer' \
    _append "${api}" 'fn arming() -> impl Fn(&Handle, Keys) -> Armed { Handle::set_signer }'

  _fixture 'a method reference to a builder'"'"'s signer fails' 1 'session.rs gives a relay client a signer' \
    _append "${session}" 'fn signing() -> impl Fn(Builder, Keys) -> Builder { Builder::signer }'

  _fixture 'a path through a module named signer still passes' 0 '' \
    _append "${session}" 'fn kind(s: &nostr::signer::SignerBackend) -> bool { s.is_local() }'

  # The builder's `signer` is a public field: no call spells this one.
  _fixture 'a signer written to a builder'"'"'s field fails' 1 'session.rs gives a relay client a signer' \
    _append "${session}" 'fn signing(mut builder: Builder, keys: Keys) -> Builder {
    builder.signer = Some(keys.into_nostr_signer());
    builder
}'

  _fixture 'a comparison of two signer fields still passes' 0 '' \
    _append "${session}" 'fn same(a: &Options, b: &Options) -> bool { a.signer == b.signer }'

  # Authentication switched on: at the build, or on a built client.
  _fixture 'a relay client built to authenticate fails' 1 'manager.rs sets a relay client'"'"'s `automatic_authentication`' \
    _sed 's/automatic_authentication(false)/automatic_authentication(true)/' "${manager}"

  _fixture 'authentication switched on a built client fails' 1 'session.rs sets a relay client'"'"'s `automatic_authentication`' \
    _append "${session}" 'fn answer(c: &Handle, on: bool) { c.automatic_authentication(on) }'

  _fixture 'a second automatic_authentication(false) still passes' 0 '' \
    _append "${session}" 'fn refuse(c: &Handle) { c.automatic_authentication(false) }'

  _fixture 'a comment naming NostrSdkRelayClient in another file still passes' 0 '' \
    _append "${session}" '// MDK'"'"'s NostrSdkRelayClient::new(client) is handed a client in manager.rs.'

  # 72-73. Anti-vacuity: what must NOT fail. The clean tree already carries the
  #        Blossom `reqwest::Client::builder()`, an in-process `LocalRelay::new`,
  #        a bare client inside verified.rs's own tests, and a comment naming
  #        `Client::builder()`; these add the same shapes where they are scanned.
  _fixture 'reqwest::Client and LocalRelay::new elsewhere still pass' 0 '' \
    _append "${manager}" 'fn http() -> reqwest::Client { reqwest::Client::new() }
async fn relay() -> LocalRelay { LocalRelay::new(RelayBuilder::default()) }'

  _fixture 'a comment naming Client::builder() and .database() still passes' 0 '' \
    _append "${session}" '// Never `Client::builder().build()` here, and never `client.database()`.'

  # 37. STRUCTURAL, not a tree mutation — the hole every fixture above shared.
  #     Production and this self-test used to enumerate the checks separately,
  #     so deleting a check from the production block left all 23 fixtures
  #     green: they proved the checks WORK, never that they RUN. `run_all_checks`
  #     is now the one list both drive, which closes the deletion case; this
  #     closes the other one, a check written and wired NOWHERE.
  checked=$(( checked + 1 ))
  _unwired="$(
    wired="$(declare -f run_all_checks)"
    while read -r fn; do
      [[ "${wired}" == *"${fn} "* ]] || printf '%s ' "${fn}"
    done < <(declare -F | awk '{print $3}' | grep '^check_')
  )"
  if [[ -z "${_unwired}" ]]; then
    printf '  \033[1;32mPASS\033[0m every check_* function is wired into run_all_checks (rc=0)\n'
  else
    printf '  \033[1;31mFAIL\033[0m check function(s) defined but never invoked by run_all_checks: %s\n' \
      "${_unwired}" >&2
    printf '     A check that is not in that list runs nowhere — in the production tree OR in\n' >&2
    printf '     these fixtures — while still looking like coverage.\n' >&2
    fails=1
  fi

  if (( checked != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${checked} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  if (( fails != 0 )); then
    echo "check_engine_client_options.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "check_engine_client_options.sh --self-test: ${checked} fixtures passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "check_engine_client_options.sh: FAILED" >&2
  exit 1
fi
log "OK: the publish pool sends no keepalive and holds no REQ; the engine pool keeps both the ping its standing REQ needs and the pool-side filter check off; the burst close path drains before it disconnects; the bridge forwards every burst-lifecycle call to the core instead of answering for it; and every relay client is built by the one constructor that verifies each relay event."
