#!/usr/bin/env bash
# CI guard: nothing subscribes on the publish client, and nothing reaches the
# subscription half of MDK's Nostr adapter.
#
# The durable fanout publishes through MDK's relay client
# (`transport_nostr_adapter::NostrSdkRelayClient`, feature `sdk`), which
# `RelayManager::fanout_transport()` builds over Haven's PUBLISH client. That
# client's relays are registered `READ | WRITE`, because the same client runs
# Haven's targeted one-shot fetches — and a relay with the READ flag inherits
# every pool-wide subscription the client holds
# (`nostr-relay-pool-0.44.3/src/pool/mod.rs`, `RelayPool::add_relay`). So one
# pool-wide `subscribe` on that client would send its filter — an account's
# inbox, a circle's routing id — to every relay Haven has ever published to,
# fanout targets included, and keep the burst sockets from ever sleeping. MDK
# registers its own publish targets write-only for exactly this reason
# (`transport-nostr-adapter/src/sdk_client.rs:1165-1168` at the pinned rev);
# Haven keeps READ and bans the subscription instead.
#
# MDK's client also carries a whole subscription plane Haven does not use and
# must not start on this client: `NostrRelayClient::subscribe` connects EVERY
# relay in the pool before it issues its REQ (`sdk_client.rs:1341`), the
# notification forwarder and MDK's NIP-77 reconciler read whatever the pool
# delivers, and `NostrTransportAdapter::activate_account` drives all three.
# Haven's own receive planes run on the engine client and are held by
# check_engine_client_options.sh.
#
# Pure-grep gate over comment-stripped Rust under haven-core/src,
# haven/rust_builder/src and tooling/soak/src. Checks:
#   1. No file names the adapter's activation plane: `NostrTransportAdapter`,
#      the `TransportAdapter` trait, or `activate_account`.
#   2. No file CALLS the relay client's subscription plane
#      (`reconcile_subscription`, `spawn_notification_forwarder`,
#      `plan_subscription`, `take_subscription_registrations`,
#      `unsubscribe_account`). A test double has to DEFINE the trait's methods;
#      a definition is not a call.
#   3. In every file that names `NostrRelayClient` or `NostrSdkRelayClient`,
#      no `subscribe`/`unsubscribe` call of any spelling is made, except one
#      declared `// auto-closing REQ` (the marker
#      check_engine_client_options.sh check 7 pins to the per-relay page in
#      `relay/manager.rs`).
#   4. `relay/manager.rs`, the one file that holds the publish client, makes
#      no pool-wide `subscribe(` / `subscribe_with_id(` — marked or not. The
#      only receiver either may have there is a single relay's handle,
#      `relay`.
#   5. The one NIP-77 session shape. MDK's reconciler stays banned (check 2):
#      it advertises the device's inventory and fetches from every relay.
#      Haven's own session runs on this pool inside a wake, and:
#      (a) `sync_targeted(` appears exactly once, in `relay/manager.rs`, in
#          `fn neg_remote_ids`;
#      (b) that call's one target carries `(filter, Vec::new())` — the empty
#          local set, so the session advertises nothing the device holds —
#          and the body sets `.dry_run()` and `SyncDirection::Down`, so it
#          sends no REQ and no EVENT;
#      (c) no `.sync(`, `.sync_with(`, `.sync_with_items(` and no
#          `negentropy_items(` anywhere: each reads a local set from the
#          pool's database, or addresses every relay;
#      (d) no `SyncDirection::Up` / `SyncDirection::Both`;
#      (e) `neg_remote_ids(` is called only from `relay/negentropy.rs`.
#
# What this scan covers, and no more. It bans the `subscribe` / `unsubscribe`
# spellings above and the named entry points of MDK's subscription plane. It
# does NOT scan the other pool-wide calls a client offers — `fetch_events(`,
# `stream_events(` and `send_event(` without a target list each address
# every relay the pool holds (`sync(` is check 5's) — and it cannot see a call it cannot
# spell: a `subscribe` reached on the trait object through an alias, a generic
# or `impl Trait`, a method reference, a macro, a publish client handed out of
# `manager.rs` under another name, or anything under `tests/`. `manager.rs`
# uses only the targeted forms (`fetch_events_from`, `send_event_to`, one
# relay's handle); that is held by review and by the tests that count what
# each relay is sent, not by this guard.
#
# Usage:
#   bash scripts/ci/check_publish_client_no_subscription.sh
#   bash scripts/ci/check_publish_client_no_subscription.sh --self-test
#
# Exit codes:
#   0  all checks pass (or the self-test passed)
#   1  a subscription path is reachable (or the self-test failed)
#   2  expected files missing, or nothing names MDK's relay client — the scan
#      would be reading nothing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly -a SOURCE_ROOTS=(haven-core/src haven/rust_builder/src tooling/soak/src)
readonly MANAGER='haven-core/src/relay/manager.rs'
readonly MARKER='// auto-closing REQ'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=24
readonly NEG_DRIVER='haven-core/src/relay/negentropy.rs'

readonly ACTIVATION='(^|[^A-Za-z0-9_])(NostrTransportAdapter|TransportAdapter|activate_account)([^A-Za-z0-9_]|$)'
readonly PLANE_CALL='(\.|::)[[:space:]]*(reconcile_subscription|spawn_notification_forwarder|plan_subscription|take_subscription_registrations|unsubscribe_account)[[:space:]]*\('
readonly RELAY_CLIENT='(^|[^A-Za-z0-9_])(NostrRelayClient|NostrSdkRelayClient)([^A-Za-z0-9_]|$)'
readonly SUBSCRIBE_CALL='(\.|::)[[:space:]]*(un)?subscribe[a-z_]*[[:space:]]*\('
readonly POOL_WIDE='[A-Za-z0-9_)]*\.(subscribe|subscribe_with_id)\('

FAILED=0

log() {
  printf '\033[1;34m[check_publish_client_no_subscription]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_publish_client_no_subscription] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

# Comment-stripped view of a Rust file, line numbering preserved. `//` starts a
# comment unless a `:` precedes it, or every `"wss://relay"` literal would
# truncate its own line.
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

# Whether the call at <line> is declared auto-closing: the marker sits on the
# call's own line or in the contiguous `//` comment block directly above it.
marked_auto_closing() { # <file> <line>
  local file="$1" n="$2" raw
  raw="$(sed -n "${n}p" "${file}")"
  [[ "${raw}" == *"${MARKER}"* ]] && return 0
  while (( n > 1 )); do
    n=$(( n - 1 ))
    raw="$(sed -n "${n}p" "${file}")"
    [[ "${raw}" =~ ^[[:space:]]*// ]] || return 1
    [[ "${raw}" == *"${MARKER}"* ]] && return 0
  done
  return 1
}

run_check() {
  local root file rel view hits n
  for root in "${SOURCE_ROOTS[@]}"; do
    [[ -d "${REPO_ROOT}/${root}" ]] || { echo "ERROR: ${REPO_ROOT}/${root} not found" >&2; exit 2; }
  done
  [[ -f "${REPO_ROOT}/${MANAGER}" ]] || { echo "ERROR: ${REPO_ROOT}/${MANAGER} not found" >&2; exit 2; }

  log "Checking that nothing subscribes on the publish client or starts MDK's subscription plane ..."
  local named=0
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    view="$(code_view "${file}")"

    # Check 1: the activation plane.
    hits="$(grep -nE "${ACTIVATION}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names the adapter's activation plane (NostrTransportAdapter / TransportAdapter / activate_account; line(s) ${hits}). Activating an account subscribes its inbox and every group on whichever client the adapter was built over. Haven's receive planes are its own, on the engine client; the fanout uses MDK's relay client for publish_event and nothing else."
    fi

    # Check 2: the relay client's subscription plane.
    hits="$(grep -nE "${PLANE_CALL}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} calls the subscription plane of MDK's relay client (line(s) ${hits}). Its forwarder and its NIP-77 reconciler read whatever the client it holds delivers, and that client is the publish client."
    fi

    # Check 3: where MDK's relay client is in reach, no subscribe call at all.
    if grep -qE "${RELAY_CLIENT}" <<<"${view}"; then
      named=1
      while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        if ! marked_auto_closing "${file}" "${n}"; then
          fail "${rel}:${n} makes a subscribe/unsubscribe call in a file that names MDK's relay client. NostrRelayClient::subscribe connects every relay in the pool and registers a standing REQ on the client it holds — the publish client, whose READ relays would each be sent the filter. The one REQ this file family may issue is the per-relay page, declared '${MARKER}'."
        fi
      done < <(grep -nE "${SUBSCRIBE_CALL}" <<<"${view}" | cut -d: -f1 || true)
    fi
  done < <(for root in "${SOURCE_ROOTS[@]}"; do find "${REPO_ROOT}/${root}" -type f -name '*.rs'; done | LC_ALL=C sort)

  if (( named == 0 )); then
    echo "ERROR: no source file names NostrRelayClient or NostrSdkRelayClient — check 3 read nothing. If the fanout transport is gone, retire this guard with it." >&2
    exit 2
  fi

  # Check 4: no pool-wide subscribe on the publish client, marked or not. Read
  # with all whitespace removed, so a chain rustfmt wrapped keeps its receiver.
  hits="$(code_view "${REPO_ROOT}/${MANAGER}" | tr -d '[:space:]' | grep -oE "${POOL_WIDE}" | grep -vxE 'relay\.(subscribe|subscribe_with_id)\(' | sort -u | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${MANAGER} calls subscribe( / subscribe_with_id( on something other than one relay's handle (${hits}). On the client or its pool that REQ goes to EVERY relay registered with the READ flag — every relay Haven publishes to, fanout targets included — auto-closing or not."
  fi

  check_neg_session

  if (( FAILED )); then
    exit 1
  fi
  log "OK: no activation plane, no relay-client subscription call, no pool-wide subscribe on the publish client, and one empty-set dry-run NIP-77 session."
}

# The body of `fn <name>` in a comment-stripped view, whitespace removed:
# from its `fn` line to the brace that closes it. awk reads to the end (no
# early `exit`), so `code_view` is never cut off by SIGPIPE under pipefail.
fn_body_tight() { # <file> <name>
  code_view "$1" | awk -v name="$2" '
    !inside && !done && $0 ~ ("fn " name "[(<]") { inside = 1 }
    inside {
      print
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        if (chars[i] == "{") { depth++; opened = 1 }
        else if (chars[i] == "}") { depth-- }
      }
      if (opened && depth == 0) { inside = 0; done = 1 }
    }' | tr -d '[:space:]'
}

# Check 5: the one NIP-77 session shape.
check_neg_session() {
  local root file rel view sites body n
  sites=""
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    view="$(code_view "${file}" | tr -d '[:space:]')"
    n="$({ grep -o 'sync_targeted(' <<<"${view}" || true; } | wc -l | tr -d ' ')"
    if (( n > 0 )); then
      sites+="${rel}:${n} "
    fi
    if grep -qE '\.(sync|sync_with|sync_with_items)\(|negentropy_items\(' <<<"${view}"; then
      fail "${rel} calls a pool-wide or database-fed NIP-77 entry (.sync( / .sync_with( / .sync_with_items( / negentropy_items(). Each sends the pool database's ids as the local set, or opens a session with every relay the pool holds; the one session Haven opens is neg_remote_ids's, with an empty set, one relay at a time."
    fi
    if grep -qE 'SyncDirection::(Up|Both)' <<<"${view}"; then
      fail "${rel} names SyncDirection::Up or ::Both. A NIP-77 session that uploads sends the relay events from the pool's database; Haven's runs Down, as a dry run."
    fi
    if [[ "${rel}" != "${MANAGER}" && "${rel}" != "${NEG_DRIVER}" ]] && grep -q 'neg_remote_ids(' <<<"${view}"; then
      fail "${rel} calls neg_remote_ids( — the NIP-77 session runs only from ${NEG_DRIVER}, inside a pass that is begun only in a wake, at most four routes per spacing."
    fi
  done < <(for root in "${SOURCE_ROOTS[@]}"; do find "${REPO_ROOT}/${root}" -type f -name '*.rs'; done | LC_ALL=C sort)
  if [[ "${sites}" != "${MANAGER}:1 " ]]; then
    fail "sync_targeted( must appear exactly once, in ${MANAGER} (found: ${sites:-nowhere}). It is the pool's per-relay NIP-77 entry; a second call is a second session shape this guard has not read."
    return
  fi
  body="$(fn_body_tight "${REPO_ROOT}/${MANAGER}" neg_remote_ids)"
  if [[ "${body}" != *"sync_targeted("* ]]; then
    fail "${MANAGER}'s one sync_targeted( is not inside fn neg_remote_ids."
    return
  fi
  if ! grep -qE 'sync_targeted\(\[\([^][]*,\(filter,Vec::new\(\)\)\)\]' <<<"${body}"; then
    fail "neg_remote_ids's sync_targeted( target does not carry (filter, Vec::new()). Any other local set is the device's inventory, sent to the relay as raw ids for every range under 32 items (negentropy 0.5.0 lib.rs 311-319)."
  fi
  if [[ "${body}" != *".dry_run()"* || "${body}" != *"SyncDirection::Down"* ]]; then
    fail "neg_remote_ids does not set .dry_run() and SyncDirection::Down. Without both the pool sends its own REQ for what is missing, or uploads, on the publish client."
  fi
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is a whole tree run through the real entry point, and
# must fail with the message of the check it breaks.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _tree() { # <tree>
    local t="$1"
    mkdir -p "${t}/haven-core/src/relay/live_sync" "${t}/haven/rust_builder/src" "${t}/tooling/soak/src"
    cat >"${t}/${MANAGER}" <<'RS'
use transport_nostr_adapter::{NostrRelayClient, NostrSdkRelayClient};

// A comment naming client.subscribe(filter, None) subscribes nothing.
impl RelayManager {
    pub fn fanout_transport(&self) -> FanoutTransport {
        FanoutTransport {
            client: self.client.clone(),
            relay_client: Arc::new(NostrSdkRelayClient::new(self.client.clone())),
        }
    }

    async fn read_one_relays_answer(relay: &Relay, filter: Filter) {
        // auto-closing REQ: `opts` exits on EOSE.
        let _ = relay.subscribe_with_id(SubscriptionId::generate(), filter, opts).await;
    }
}

#[cfg(test)]
mod tests {
    struct Double;

    #[async_trait::async_trait]
    impl NostrRelayClient for Double {
        async fn subscribe(&self, _: NostrSubscription) -> Result<(), TransportAdapterError> {
            Err(TransportAdapterError::Closed)
        }
        async fn unsubscribe_account(&self, _: &MemberId) -> Result<(), TransportAdapterError> {
            Err(TransportAdapterError::Closed)
        }
    }
}
RS
    cat >"${t}/haven-core/src/relay/fanout.rs" <<'RS'
use cgka_traits::TransportAdapterError;
use transport_nostr_adapter::NostrRelayClient;

pub async fn publish_to_target(relay_client: &dyn NostrRelayClient) {
    let _ = relay_client.publish_event(targets, &event, 1).await;
}
RS
    # The engine client's own standing REQs: another client, another guard.
    cat >"${t}/haven-core/src/relay/live_sync/session.rs" <<'RS'
async fn open(client: &Client) {
    let _ = client.subscribe_with_id_to(urls, id, filter, None).await;
    client.unsubscribe(&id).await;
}
RS
    cat >>"${t}/${MANAGER}" <<'RS'

impl RelayManager {
    pub(crate) async fn neg_remote_ids(&self, url: RelayUrl, filter: Filter) -> NegAnswer {
        let options = SyncOptions::new()
            .direction(SyncDirection::Down)
            .dry_run();
        let output = self
            .client
            .pool()
            .sync_targeted([(url.clone(), (filter, Vec::new()))], &options)
            .await;
        NegAnswer::from(output)
    }
}
RS
    cat >"${t}/${NEG_DRIVER}" <<'RS'
pub(crate) async fn reconcile_route(relays: &RelayManager, route: &NegRoute) {
    // A comment naming client.sync_with(urls, filter, opts) syncs nothing.
    let _ = relays.neg_remote_ids(url, filter).await;
}
RS
    printf 'pub fn api() {}\n' >"${t}/haven/rust_builder/src/api.rs"
    printf 'fn main() {}\n' >"${t}/tooling/soak/src/main.rs"
  }
  _case() { # <label> <want-rc> <want-msg-substring> <tree>
    local label="$1" want="$2" msg="$3" got=0 out
    checked=$(( checked + 1 ))
    out="$(REPO_ROOT_OVERRIDE="$4" bash "${BASH_SOURCE[0]}" 2>&1)" || got=$?
    if [[ "${got}" -ne "${want}" ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n%s\n' "${label}" "${want}" "${got}" "${out}" >&2
      fails=1
    elif [[ -n "${msg}" && "${out}" != *"${msg}"* ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (rc=%d, but no message matched %q)\n%s\n' "${label}" "${got}" "${msg}" "${out}" >&2
      fails=1
    else
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    fi
  }

  echo "check_publish_client_no_subscription.sh --self-test"
  local t="${tmp}/ok"; _tree "${t}"
  _case "the tree shape passes: a marked per-relay REQ, a test double's definitions, the engine client's own REQs" 0 '' "${t}"

  t="${tmp}/adapter"; _tree "${t}"
  printf 'use transport_nostr_adapter::NostrTransportAdapter;\n' >>"${t}/tooling/soak/src/main.rs"
  _case "NostrTransportAdapter in the soak rig fails" 1 "names the adapter's activation plane" "${t}"

  t="${tmp}/activate"; _tree "${t}"
  printf 'async fn go(a: &A) { a.activate_account(activation).await; }\n' >>"${t}/haven/rust_builder/src/api.rs"
  _case "activate_account in the FFI crate fails" 1 "names the adapter's activation plane" "${t}"

  t="${tmp}/trait"; _tree "${t}"
  printf 'use cgka_traits::TransportAdapter;\n' >>"${t}/haven-core/src/relay/fanout.rs"
  _case "the TransportAdapter trait fails" 1 "names the adapter's activation plane" "${t}"

  t="${tmp}/error-type"; _tree "${t}"
  printf 'fn kind(e: &TransportAdapterError) -> u8 { 0 }\n' >>"${t}/haven/rust_builder/src/api.rs"
  _case "TransportAdapterError is not the adapter" 0 '' "${t}"

  t="${tmp}/forwarder"; _tree "${t}"
  printf 'fn f(sdk: &S, a: A) { sdk.spawn_notification_forwarder(a); }\n' >>"${t}/haven-core/src/relay/live_sync/session.rs"
  _case "the notification forwarder fails, wherever it is called" 1 'calls the subscription plane' "${t}"

  t="${tmp}/reconcile"; _tree "${t}"
  printf 'async fn f(sdk: &S) { sdk\n        .reconcile_subscription(sub, items, progress)\n        .await; }\n' >>"${t}/tooling/soak/src/main.rs"
  _case "the NIP-77 reconciler fails across a wrapped chain" 1 'calls the subscription plane' "${t}"

  t="${tmp}/unsub-account"; _tree "${t}"
  printf 'async fn f(c: &C, id: &MemberId) { let _ = c.unsubscribe_account(id).await; }\n' >>"${t}/haven-core/src/relay/fanout.rs"
  _case "unsubscribe_account called fails" 1 'calls the subscription plane' "${t}"

  t="${tmp}/trait-subscribe"; _tree "${t}"
  printf 'async fn f(relay_client: &dyn NostrRelayClient) { let _ = relay_client.subscribe(sub).await; }\n' >>"${t}/haven-core/src/relay/fanout.rs"
  _case "subscribe on the relay client fails" 1 "in a file that names MDK's relay client" "${t}"

  t="${tmp}/path-subscribe"; _tree "${t}"
  printf 'async fn f(c: &C) { let _ = NostrRelayClient::subscribe(c, sub).await; }\n' >>"${t}/haven-core/src/relay/fanout.rs"
  _case "the trait method called by path fails" 1 "in a file that names MDK's relay client" "${t}"

  t="${tmp}/unsubscribe"; _tree "${t}"
  printf 'async fn f(relay_client: &dyn NostrRelayClient) { let _ = relay_client.unsubscribe(sub).await; }\n' >>"${t}/haven-core/src/relay/fanout.rs"
  _case "unsubscribe on the relay client fails" 1 "in a file that names MDK's relay client" "${t}"

  t="${tmp}/pool-wide"; _tree "${t}"
  printf 'impl RelayManager { async fn listen(&self) { let _ = self.client.subscribe(filter, None).await; } }\n' >>"${t}/${MANAGER}"
  _case "a pool-wide subscribe on the publish client fails" 1 "on something other than one relay's handle" "${t}"

  # The marker cannot buy a pool-wide REQ: auto-closing or not, it goes to
  # every READ relay.
  t="${tmp}/pool-wide-marked"; _tree "${t}"
  printf 'impl RelayManager { async fn ask(&self) {\n    // auto-closing REQ\n    let _ = self.client.pool().subscribe_with_id(id, filter, opts).await;\n} }\n' >>"${t}/${MANAGER}"
  _case "a pool-wide subscribe_with_id declared auto-closing still fails" 1 "on something other than one relay's handle" "${t}"

  t="${tmp}/unmarked-relay"; _tree "${t}"
  sed -i '/auto-closing REQ: `opts` exits on EOSE/d' "${t}/${MANAGER}"
  _case "the per-relay REQ without its marker fails" 1 "in a file that names MDK's relay client" "${t}"

  t="${tmp}/comment"; _tree "${t}"
  printf '// Never `relay_client.subscribe(sub)` here, nor NostrTransportAdapter::activate_account.\n' >>"${t}/haven-core/src/relay/fanout.rs"
  _case "a comment naming every banned call passes" 0 '' "${t}"

  t="${tmp}/neg-second"; _tree "${t}"
  printf 'async fn f(p: &RelayPool) { let _ = p.sync_targeted(targets, &opts).await; }\n' >>"${t}/tooling/soak/src/main.rs"
  _case "a second sync_targeted( call fails" 1 'must appear exactly once' "${t}"

  t="${tmp}/neg-not-dry"; _tree "${t}"
  sed -i '/\.dry_run();/d; s/\.direction(SyncDirection::Down)/.direction(SyncDirection::Down);/' "${t}/${MANAGER}"
  _case "a session that is not a dry run fails" 1 'does not set .dry_run()' "${t}"

  t="${tmp}/neg-both"; _tree "${t}"
  sed -i 's/SyncDirection::Down/SyncDirection::Both/' "${t}/${MANAGER}"
  _case "a session that uploads fails" 1 'names SyncDirection::Up or ::Both' "${t}"

  t="${tmp}/neg-inventory"; _tree "${t}"
  sed -i 's/(filter, Vec::new())/(filter, items)/; s/let options = SyncOptions::new()/let _unused: Vec<u8> = Vec::new();\n        let options = SyncOptions::new()/' "${t}/${MANAGER}"
  _case "a session handed the inventory fails, though the body builds a Vec::new() elsewhere" 1 'does not carry (filter, Vec::new())' "${t}"

  t="${tmp}/neg-sync-with"; _tree "${t}"
  printf 'async fn f(c: &Client) { let _ = c.pool().sync_with(urls, filter, &opts).await; }\n' >>"${t}/haven-core/src/relay/fanout.rs"
  _case "a database-fed sync_with( fails" 1 'pool-wide or database-fed NIP-77 entry' "${t}"

  t="${tmp}/neg-items"; _tree "${t}"
  printf 'async fn f(d: &D) { let _ = d.negentropy_items(filter).await; }\n' >>"${t}/haven/rust_builder/src/api.rs"
  _case "negentropy_items( fails" 1 'pool-wide or database-fed NIP-77 entry' "${t}"

  t="${tmp}/neg-caller"; _tree "${t}"
  printf 'async fn f(r: &RelayManager) { let _ = r.neg_remote_ids(url, filter).await; }\n' >>"${t}/haven-core/src/relay/live_sync/session.rs"
  _case "neg_remote_ids( called outside the driver fails" 1 'runs only from' "${t}"

  t="${tmp}/no-manager"; _tree "${t}"
  rm "${t}/${MANAGER}"
  _case "a missing manager.rs is a misconfiguration" 2 '' "${t}"

  t="${tmp}/vacuous"; _tree "${t}"
  sed -i 's/NostrSdkRelayClient/SdkClient/g; s/NostrRelayClient/RelayClientTrait/g' "${t}/${MANAGER}" "${t}/haven-core/src/relay/fanout.rs"
  _case "a tree where nothing names MDK's relay client is a misconfiguration, not a pass" 2 '' "${t}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  '') run_check ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
