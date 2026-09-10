#!/usr/bin/env bash
# CI guard: the two relay pools each keep the options they need and neither
# adopts the other's; the background burst closes cleanly; and the FFI bridge
# forwards the burst lifecycle to the engine rather than answering for it.
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
#   8. `session.rs`'s `fn pause_subscriptions` BODY (the burst's close path):
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
#      seven `LiveSyncFfi` methods named in `FFI_DELEGATIONS` calls
#      `core.<same-name>()`, makes exactly ONE call on the core handle, and
#      contains no `return` but the session gate's `return Err(`. The last rule
#      is what makes it a reachability check rather than a substring one — a
#      guarded bypass leaves the required call present and dead. See check 9's
#      own block for what each forwarding buys and how each collapse is silent.
#  10. `api.rs`'s two `#[frb(sync)]` session reads (`is_running`, `is_paused`)
#      answer from `SESSION`, ask the core for the flag they name, and contain
#      no panic token — a sync FFI read unwinds into Dart, and `unwrap_used` /
#      `expect_used` are restriction lints this repo does not enable.
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_SRC_DIR="${REPO_ROOT}/haven-core/src"
FFI_SRC_DIR="${REPO_ROOT}/haven/rust_builder/src"
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
  code_view "$2" | awk -v sig="fn $1" '
    index($0, sig) > 0 { inbody = 1 }
    inbody {
      print
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
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
  pause="$(fn_body_flat 'pause_subscriptions' "${session}")"
  if [[ -z "${pause}" ]]; then
    lfail "(8) $(basename "${session}") defines no pause_subscriptions() — the background burst has no close path, so the engine holds its standing REQ and its socket between publish ticks and P4's whole saving is gone."
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
#    bound as `core` in these seven methods. That is a convention this guard
#    imposes and cannot infer — a rename fails rule (a) with "does not forward",
#    which is the right place to learn about it.
#
#    Whitespace is squeezed out before matching, so rustfmt may split or join
#    the builder chain freely without moving this check either way.
#
#    Two of the seven are also each other's most plausible wrong destination, and
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
run_all_checks() { # <core-src-dir> <ffi-src-dir> <manager.rs> <session.rs> <api.rs>
  local core_dir="$1" ffi_dir="$2" manager="$3" session="$4" api="$5" rc=0
  check_no_verify_subscriptions_enabled "${core_dir}" "${ffi_dir}" || rc=1
  check_publish_pool_options "${manager}" || rc=1
  check_engine_pool_options "${session}" || rc=1
  check_ffi_add_relay "${api}" || rc=1
  check_ffi_core_delegations "${api}" || rc=1
  check_ffi_sync_reads_cannot_panic "${api}" || rc=1
  return "${rc}"
}

if [[ "${1:-}" != "--self-test" ]]; then
  for p in "${CORE_SRC_DIR}" "${FFI_SRC_DIR}"; do
    [[ -d "${p}" ]] || { echo "ERROR: ${p} not found" >&2; exit 2; }
  done
  for p in "${SESSION_FILE}" "${MANAGER_FILE}" "${API_FILE}"; do
    [[ -f "${p}" ]] || { echo "ERROR: ${p} not found" >&2; exit 2; }
  done

  log "Checking both pools' options, the burst close path and the bridge's forwarding ..."
  run_all_checks "${CORE_SRC_DIR}" "${FFI_SRC_DIR}" "${MANAGER_FILE}" "${SESSION_FILE}"     "${API_FILE}" || FAILED=1
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
  local -r SELF_TEST_FIXTURES=44
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local core="${tmp}/core" ffi="${tmp}/ffi"
  local manager="${core}/relay/manager.rs"
  local session="${core}/relay/live_sync/session.rs"
  local api="${ffi}/api.rs"

  _clean_tree() {
    rm -rf "${core}" "${ffi}"
    mkdir -p "${core}/relay/live_sync" "${ffi}"

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
    Client::builder().opts(client_opts).build()
}

impl LiveSyncCore {
    async fn start(&self, relays: &[String]) {
        for relay in relays {
            let _ = self.client.add_relay(relay.as_str()).await;
        }
    }

    /// The background burst's close path.
    pub async fn pause_subscriptions(&self) -> LiveSyncResult<()> {
        let _lifecycle = self.lifecycle.lock().await;
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
        let client = nostr_sdk::Client::builder().build();
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
    run_all_checks "${core}" "${ffi}" "${manager}" "${session}" "${api}"
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
log "OK: the publish pool sends no keepalive and holds no REQ; the engine pool keeps both the ping its standing REQ needs and the pool-side filter check off; the burst close path drains before it disconnects; and the bridge forwards every burst-lifecycle call to the core instead of answering for it."
