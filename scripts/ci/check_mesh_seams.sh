#!/usr/bin/env bash
# CI guard: the Bluetooth mesh meets the relay path at one call, and holds its
# keys in one file (docs/BLUETOOTH_MESH_PLAN.md T-INDEP-1c; guard wording per
# docs/BLUETOOTH_MESH_M2_DESIGN.md, review answer Q-2).
#
# The mesh is an opt-in second carrier for the location events the relay path
# already seals. What it may never become is a second way through the relay
# path: something a relay send waits on, a place a kind 445 is sealed or
# decided, or a reader of a relay plane. Two seams keep it from that, and both
# are textual facts a review of a later change can miss:
#
#   * KEYS. A mesh packet is sealed under a key derived from a circle's
#     group-event exporter secret. That secret is read off the one live MLS
#     session, so the ring that keeps it lives beside the session manager —
#     in `nostr/mls/manager/mesh.rs`, a child module of `manager` — and in no
#     other file under `nostr/` or `relay/`. The child module reads the engine
#     only through the `Held` trait the session manager implements for the
#     session it holds: it names no engine type, takes no engine lock, awaits
#     nothing and never touches the second store handle, so it cannot run an
#     engine call of its own or widen what is read off the engine. It
#     re-exports nothing, so no other file reaches a mesh type through it but
#     by a name declared there — and every name it declares for others to use
#     carries `mesh` (`MeshKeyStore`, `MeshPacket`, `MeshDrive`, …), which
#     checks 3 and 5 read wherever it is used.
#
#   * THE HAND-OFF. `SessionManager::mesh_offer` is called once, by
#     `Publishing::publish_location`, after that send's own checks (`Expired`,
#     `Superseded`) and before its relay send. Before the checks, a location
#     the relay path refuses would still go out by Bluetooth — to a member
#     removed since it was sealed. After the relay send, the gate
#     `assert_a_completed_location_send_is_never_made_again` no longer holds
#     and the mesh would wait on a relay. A second call site is a second way
#     onto the mesh this guard has not read.
#
#   * THE INGRESS. `Publishing::mesh_drive` is where what the mesh received
#     meets the engine. It names no mesh module either: it is handed
#     `MeshPacket`s, answers a `MeshDrive`, and calls the session's
#     `mesh_read`, `ingest_from_mesh` and `mesh_taken_in` and the circle
#     store's `fold_mesh_counts` — its row in FANOUT_MAY_NAME, and nothing
#     else of the mesh. That it calls no relay is not a textual fact and is
#     held by `haven-core/tests/mesh_drive_e2e.rs`.
#
# Later steps of the mesh add `bridge_locations` and
# `publish_location_and_bridge` to `relay/fanout.rs`. Each is admitted by
# adding a row to FANOUT_MAY_NAME below — the function, and the mesh items its
# body may name — never by loosening a check.
#
# Pure-grep gate over comment-stripped Rust. Checks:
#   1. Under haven-core/src/relay and haven-core/src/nostr the identifier
#      `mesh` — the mesh module's name, however it is reached: `crate::mesh`,
#      `super::mesh`, a bare `mesh::`, a grouped `use crate::{.., mesh}` —
#      appears only in `nostr/mls/manager/mesh.rs`, and in
#      `nostr/mls/manager.rs` as the declaration `mod mesh;` and in paths
#      `self::mesh::…` into that child.
#   2. `nostr/mls/manager/mesh.rs` re-exports nothing (`pub use`,
#      `pub(..) use`), names no `AccountDeviceSession`, has no `async` and no
#      `.await`, and reaches neither the session's lock (`.engine(`,
#      `.reading(`, `.session`) nor `message_store`.
#   3. `relay/fanout.rs` names a mesh item — any identifier containing `mesh`,
#      in any case — only inside the body of a function listed in
#      FANOUT_MAY_NAME, and only the items listed for it.
#   4. `mesh_offer(` — the name followed by a parenthesis, however it is
#      reached: a method call, `SessionManager::mesh_offer(&s, …)` — occurs
#      exactly once outside its own `fn` in haven-core/src,
#      haven/rust_builder/src and tooling/soak/src: in `relay/fanout.rs`, in
#      `pub async fn publish_location`, after `if !record.may_be_sent` and
#      before `self.fanout.publish_location(`.
#   5. Under haven-core/src/relay and haven-core/src/nostr a mesh item — any
#      identifier containing `mesh` — is named only in the key ring's file,
#      in `nostr/mls/manager.rs` (the session manager that owns the ring and
#      holds the engine for it), in `relay/fanout.rs` as check 3 admits, and
#      in `nostr/mls/mod.rs` as the names of MOD_MAY_NAME, which it
#      re-exports. So `relay/manager.rs`, `relay/catchup.rs`,
#      `relay/verified.rs`, every file under `relay/live_sync/` and every
#      other file of the two trees name none at all.
#
# What this scan covers, and no more. It reads names. It cannot see a mesh
# type reached through a name without `mesh` in it — a value a
# `SessionManager` method returns, bound under another name — nor
# `mesh_offer` passed as a function value and called under another name, nor
# a string a macro pastes into a path, nor anything under `tests/`. That a
# location's send is the same with mesh on and off is held by
# `haven-core/tests/mesh_handoff_e2e.rs`, not by this guard.
#
# Usage:
#   bash scripts/ci/check_mesh_seams.sh
#   bash scripts/ci/check_mesh_seams.sh --self-test
#
# Exit codes:
#   0  all checks pass (or the self-test passed)
#   1  a seam is broken (or the self-test failed)
#   2  an expected file is missing, or the key ring no longer names the mesh
#      module — the scan would be reading nothing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly -a SEAM_TREES=(haven-core/src/relay haven-core/src/nostr)
readonly -a SOURCE_ROOTS=(haven-core/src haven/rust_builder/src tooling/soak/src)
readonly KEYS='haven-core/src/nostr/mls/manager/mesh.rs'
readonly MANAGER='haven-core/src/nostr/mls/manager.rs'
readonly FANOUT='haven-core/src/relay/fanout.rs'
readonly MLS_MOD='haven-core/src/nostr/mls/mod.rs'
# The key ring's public names `nostr/mls/mod.rs` re-exports, and every mesh
# item it may name.
readonly -a MOD_MAY_NAME=(MeshDrive MeshKeyStore MeshPacket StoredMeshKey MESH_ON_MAX_MS)
readonly -a NO_MESH=(
  haven-core/src/relay/manager.rs
  haven-core/src/relay/catchup.rs
  haven-core/src/relay/verified.rs
)
readonly NO_MESH_DIR='haven-core/src/relay/live_sync'

# The functions of relay/fanout.rs whose bodies may name a mesh item, each
# with the items it may name: `<declaration prefix>|<item> <item> …`. A later
# step adds its function here, with exactly what it calls.
readonly -a FANOUT_MAY_NAME=(
  'pub async fn publish_location(|mesh_offer'
  'pub async fn mesh_drive(|mesh_drive MeshPacket MeshDrive mesh_read ingest_from_mesh mesh_taken_in fold_mesh_counts'
)

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=37

readonly WORD='(^|[^A-Za-z0-9_])mesh([^A-Za-z0-9_]|$)'
readonly ITEM='[A-Za-z0-9_]*[Mm][Ee][Ss][Hh][A-Za-z0-9_]*'

FAILED=0

log() {
  printf '\033[1;34m[check_mesh_seams]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_mesh_seams] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

# Comment-stripped view of a Rust file, line numbering preserved. `//` starts a
# comment unless a `:` precedes it, or a `"wss://relay"` literal would truncate
# its own line.
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

# "<first> <last>" — the lines of the one function declared `<prefix>` in a
# comment-stripped view on stdin, from its declaration to the brace that
# closes it. Nothing when it is declared no times or more than once. awk
# reads to the end, so the pipe feeding it is never cut off under pipefail.
fn_lines() { # <declaration prefix>
  awk -v prefix="$1" '
    index($0, prefix) && !inside { found++; if (found == 1) { inside = 1; first = NR } }
    inside {
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        if (chars[i] == "{") { depth++; opened = 1 }
        else if (chars[i] == "}") { depth-- }
      }
      if (opened && depth == 0) { inside = 0; last = NR }
    }
    END { if (found == 1 && last) print first, last }'
}

run_check() {
  local tree file rel view hits n entry prefix items item range first last body
  for tree in "${SEAM_TREES[@]}" "${SOURCE_ROOTS[@]}" "${NO_MESH_DIR}"; do
    [[ -d "${REPO_ROOT}/${tree}" ]] || { echo "ERROR: ${REPO_ROOT}/${tree} not found" >&2; exit 2; }
  done
  for file in "${KEYS}" "${MANAGER}" "${FANOUT}" "${MLS_MOD}" "${NO_MESH[@]}"; do
    [[ -f "${REPO_ROOT}/${file}" ]] || { echo "ERROR: ${REPO_ROOT}/${file} not found" >&2; exit 2; }
  done
  # Read whole before it is searched: a `grep -q` on a pipe ends the awk
  # early, and pipefail then reports the scan as failed.
  view="$(code_view "${REPO_ROOT}/${KEYS}")"
  if ! grep -qE 'crate::mesh::' <<<"${view}"; then
    echo "ERROR: ${KEYS} names no crate::mesh:: path — check 1 would be reading nothing. If the key ring moved, move this guard with it." >&2
    exit 2
  fi

  log "Checking that the mesh module is named in one file under relay/ and nostr/, and offered to once ..."

  # Check 1: the mesh module's name.
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    [[ "${rel}" == "${KEYS}" ]] && continue
    view="$(code_view "${file}")"
    if [[ "${rel}" == "${MANAGER}" ]]; then
      # The child module's declaration, and paths into the child.
      view="$(sed -E 's/^mod mesh;$//; s/self::mesh::/self::CHILD::/g' <<<"${view}")"
    fi
    hits="$(grep -nE "${WORD}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names the mesh module (line(s) ${hits}). Under relay/ and nostr/ only ${KEYS} may: it is where a circle's packet keys are kept, beside the one MLS session they are read off. A second file that reaches crate::mesh is a second place a kind 445 can be wrapped, opened or handed to the radio."
    fi
  done < <(for tree in "${SEAM_TREES[@]}"; do find "${REPO_ROOT}/${tree}" -type f -name '*.rs'; done | LC_ALL=C sort)

  # Check 2: the key ring's own file.
  view="$(code_view "${REPO_ROOT}/${KEYS}")"
  hits="$(grep -nE '^[[:space:]]*pub(\([^)]*\))?[[:space:]]+use[[:space:]]' <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${KEYS} re-exports something (line(s) ${hits}). It re-exports nothing: through a re-export any file under relay/ or nostr/ reaches a mesh type without naming the mesh module, and check 1 reads names."
  fi
  hits="$(grep -nE '(^|[^A-Za-z0-9_])(AccountDeviceSession|async|message_store)([^A-Za-z0-9_]|$)|\.await|\.(engine|reading)\(|\.session([^A-Za-z0-9_]|$)' <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${KEYS} names the engine's type, awaits, or reaches the session's lock or its second store handle (line(s) ${hits}). The key ring reads the engine through the Held trait alone, off a session its caller already holds: it makes no engine call of its own, so it cannot run a convergence pass, and it reads the epoch state, the exporter secret and the routing id and nothing else."
  fi

  # Check 3: what relay/fanout.rs names.
  view="$(code_view "${REPO_ROOT}/${FANOUT}")"
  local -a allowed=()
  for entry in "${FANOUT_MAY_NAME[@]}"; do
    prefix="${entry%%|*}"
    items="${entry#*|}"
    range="$(fn_lines "${prefix}" <<<"${view}")"
    if [[ -z "${range}" ]]; then
      echo "ERROR: ${FANOUT} does not declare '${prefix}' exactly once — its row in FANOUT_MAY_NAME reads nothing. If the function is gone, remove its row." >&2
      exit 2
    fi
    for item in ${items}; do
      allowed+=("${range} ${item}")
    done
  done
  while IFS=: read -r n item; do
    [[ -n "${n}" ]] || continue
    local ok=0
    for entry in "${allowed[@]}"; do
      read -r first last body <<<"${entry}"
      if (( n >= first && n <= last )) && [[ "${item}" == "${body}" ]]; then
        ok=1
      fi
    done
    if (( ok == 0 )); then
      fail "${FANOUT}:${n} names the mesh item '${item}' where no row of FANOUT_MAY_NAME admits it. The relay driver meets the mesh at the calls listed there and nowhere else; a new one is added to that list, with the function it is in, when it is reviewed."
    fi
  done < <(grep -noE "${ITEM}" <<<"${view}" || true)

  # Check 4: the one hand-off.
  local sites=""
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    n="$({ code_view "${file}" | grep -oE '(^|[^A-Za-z0-9_])(fn[[:space:]]+)?mesh_offer[[:space:]]*\(' | grep -vE 'fn[[:space:]]+mesh_offer' || true; } | wc -l | tr -d ' ')"
    if (( n > 0 )); then
      sites+="${rel}:${n} "
    fi
  done < <(for tree in "${SOURCE_ROOTS[@]}"; do find "${REPO_ROOT}/${tree}" -type f -name '*.rs'; done | LC_ALL=C sort)
  if [[ "${sites}" != "${FANOUT}:1 " ]]; then
    fail "mesh_offer( must be called exactly once, in ${FANOUT} (found: ${sites:-nowhere}). It is the one hand-off of a sealed location to the mesh; a second call is a second way onto it, and none is the hand-off gone — retire this guard with it."
  else
    range="$(fn_lines 'pub async fn publish_location(' <<<"${view}")"
    read -r first last <<<"${range}"
    body="$(sed -n "${first},${last}p" <<<"${view}" | tr -d '[:space:]')"
    local checked="${body%%mesh_offer(*}"
    local after="${body#*mesh_offer(}"
    if [[ "${body}" != *"mesh_offer("* ]]; then
      fail "the one mesh_offer( call is not inside pub async fn publish_location."
    elif [[ "${checked}" != *"if!record.may_be_sent{"* || "${checked}" != *"iflocation_is_spent("* ]]; then
      fail "mesh_offer( is called before publish_location's send-time checks (location_is_spent, record.may_be_sent). A location the relay path answers Expired or Superseded would then still go out by Bluetooth — to a member removed since it was sealed."
    elif [[ "${checked}" == *"self.fanout.publish_location("* || "${after}" != *"self.fanout.publish_location("* ]]; then
      fail "mesh_offer( is not called before publish_location's relay send. After it, the mesh waits on a relay, and the send no longer ends its record with the transport's answer and nothing in between."
    fi
  fi

  # Check 5: the files that name no mesh item at all — every file of the two
  # trees but the key ring, the session manager, the driver (check 3) and,
  # for the names it re-exports, nostr/mls/mod.rs.
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    case "${rel}" in "${KEYS}" | "${MANAGER}" | "${FANOUT}") continue ;; esac
    view="$(code_view "${file}")"
    if [[ "${rel}" == "${MLS_MOD}" ]]; then
      for item in "${MOD_MAY_NAME[@]}"; do
        view="$(sed -E "s/(^|[^A-Za-z0-9_])${item}([^A-Za-z0-9_]|$)/\\1\\2/g" <<<"${view}")"
      done
    fi
    hits="$(grep -nE "${ITEM}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names a mesh item (line(s) ${hits}). Under relay/ and nostr/ the mesh is reached from the key ring's file, the session manager that owns it and the driver's admitted functions, and nostr/mls/mod.rs re-exports the names of MOD_MAY_NAME. The publish pool, the receive planes, the catch-up sweep, the verifying client and every other file there are the relay path itself: nothing of the mesh is read, called or waited on from them."
    fi
  done < <(for tree in "${SEAM_TREES[@]}"; do find "${REPO_ROOT}/${tree}" -type f -name '*.rs'; done | LC_ALL=C sort)

  if (( FAILED )); then
    exit 1
  fi
  log "OK: one file names the mesh module, it reads the engine through Held alone, a location is offered to the mesh once, after its send-time checks and before its relay send, and no other file of the relay path names a mesh item."
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
    mkdir -p "${t}/haven-core/src/relay/live_sync" "${t}/haven-core/src/nostr/mls/manager" \
      "${t}/haven-core/src/mesh" "${t}/haven/rust_builder/src" "${t}/tooling/soak/src"
    cat >"${t}/${FANOUT}" <<'RS'
// The mesh is offered to once: session.mesh_offer(event, &record), below.
pub trait FanoutSend {
    async fn publish_location(&self, event: &Event, targets: &[String]) -> Sent;
}

impl<T: FanoutSend + ?Sized> Publishing<'_, T> {
    pub async fn publish_location(&self, circle: &CircleManager, event: &Event) -> LocationPublish {
        let session = circle.session();
        let record = session.location_to_send(&message).await;
        if location_is_spent(record.expires_at_secs, now_ms) {
            return LocationPublish::Expired;
        }
        if !record.may_be_sent {
            return LocationPublish::Superseded;
        }
        session.mesh_offer(event, &record);
        let sent = self.fanout.publish_location(event, &record.relays).await;
        let _ = session.end_location(&message).await;
        LocationPublish::Sent(sent)
    }

    pub async fn mesh_drive(
        &self,
        circle: &CircleManager,
        taken: Vec<crate::nostr::mls::MeshPacket>,
    ) -> crate::nostr::mls::MeshDrive {
        let session = circle.session();
        let mut drive = crate::nostr::mls::MeshDrive::default();
        for (group_id, events) in session.mesh_read(taken, &mut drive).await {
            for event in events {
                if session.ingest_from_mesh(&event, now_ms).await.is_ok() {
                    session.mesh_taken_in(&group_id, &event, &mut drive);
                }
            }
        }
        circle.fold_mesh_counts(drive.from_circles, 0);
        drive
    }

    async fn older(&self, circle: &CircleManager) {}
}
RS
    printf 'pub struct RelayManager;\n' >"${t}/haven-core/src/relay/manager.rs"
    printf 'pub async fn run_catchup() {}\n' >"${t}/haven-core/src/relay/catchup.rs"
    printf 'pub fn verified_client() {}\n' >"${t}/haven-core/src/relay/verified.rs"
    printf 'pub struct LiveSyncCore;\n' >"${t}/haven-core/src/relay/live_sync/session.rs"
    cat >"${t}/${MANAGER}" <<'RS'
mod mesh;

use self::mesh::MeshKeys;
pub use self::mesh::{MeshKeyStore, MESH_ON_MAX_MS};

pub struct SessionManager {
    // The mesh packet keys: crate::mesh is named in the child module alone.
    mesh_keys: MeshKeys,
}

impl self::mesh::Held for AccountDeviceSession {}

pub struct LocationToSend {
    mesh_turn: Option<self::mesh::Turn>,
}
RS
    cat >"${t}/${KEYS}" <<'RS'
use super::{GroupId, LocationToSend, SessionManager};
use crate::mesh::handoff::Handoff;
use crate::mesh::packet::{wrap, MeshKey};

pub(super) trait Held {}

impl SessionManager {
    pub fn mesh_handoff(&self) -> Arc<Handoff> {
        self.mesh_keys.handoff()
    }

    pub(crate) fn mesh_offer(&self, event: &Event, record: &LocationToSend) {}
}
RS
    printf 'pub use manager::{MeshDrive, MeshKeyStore, MeshPacket, MESH_ON_MAX_MS};\n' >"${t}/haven-core/src/nostr/mls/mod.rs"
    printf 'pub mod packet;\n' >"${t}/haven-core/src/mesh/mod.rs"
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

  echo "check_mesh_seams.sh --self-test"
  local t="${tmp}/ok"; _tree "${t}"
  _case "the tree shape passes: one hand-off, the ingress, the child module, identifiers and comments that only mention the mesh" 0 '' "${t}"

  # Check 1: the mesh module's name, however it is reached.
  t="${tmp}/crate-path"; _tree "${t}"
  printf 'use crate::mesh::engine::MeshEngine;\n' >>"${t}/haven-core/src/nostr/mls/mod.rs"
  _case "crate::mesh in a second file under nostr/ fails" 1 'names the mesh module' "${t}"

  t="${tmp}/super-path"; _tree "${t}"
  printf 'fn f(p: &super::mesh::packet::Packet) {}\n' >"${t}/haven-core/src/relay/negentropy.rs"
  _case "super::mesh in a file under relay/ fails" 1 'names the mesh module' "${t}"

  t="${tmp}/grouped-use"; _tree "${t}"
  printf 'use crate::{log_alias, mesh};\n' >"${t}/haven-core/src/nostr/event.rs"
  _case "the mesh module in a grouped use fails" 1 'names the mesh module' "${t}"

  t="${tmp}/bare-path"; _tree "${t}"
  printf 'fn f() { let _ = mesh::packet::open(&key, &packet); }\n' >>"${t}/${MANAGER}"
  _case "a bare mesh:: path in the session manager fails" 1 "${MANAGER} names the mesh module" "${t}"

  t="${tmp}/sibling"; _tree "${t}"
  printf 'use crate::mesh::packet::open;\n' >"${t}/haven-core/src/nostr/mls/manager/drive.rs"
  _case "a second child module that names crate::mesh fails" 1 'names the mesh module' "${t}"

  t="${tmp}/fanout-path"; _tree "${t}"
  sed -i 's|        session.mesh_offer(event, &record);|        session.mesh_offer(event, \&record);\n        let _ = crate::mesh::packet::cover_packet(\&mut rng);|' "${t}/${FANOUT}"
  _case "crate::mesh inside publish_location itself fails" 1 'names the mesh module' "${t}"

  t="${tmp}/comment"; _tree "${t}"
  printf '// Never crate::mesh::packet::wrap here, nor session.mesh_offer(event, &record).\n' >>"${t}/haven-core/src/relay/catchup.rs"
  _case "a comment naming the mesh module and the hand-off passes" 0 '' "${t}"

  # Check 2: the key ring's own file.
  t="${tmp}/reexport"; _tree "${t}"
  printf 'pub use crate::mesh::handoff::Handoff as Outbox;\n' >>"${t}/${KEYS}"
  _case "a pub use in the key ring fails" 1 're-exports something' "${t}"

  t="${tmp}/reexport-crate"; _tree "${t}"
  printf '    pub(crate) use crate::mesh::packet::Packet;\n' >>"${t}/${KEYS}"
  _case "a pub(crate) use in the key ring fails" 1 're-exports something' "${t}"

  t="${tmp}/engine-type"; _tree "${t}"
  printf 'fn read(held: &AccountDeviceSession) {}\n' >>"${t}/${KEYS}"
  _case "the engine's type in the key ring fails" 1 "names the engine's type" "${t}"

  t="${tmp}/awaits"; _tree "${t}"
  printf 'impl SessionManager { pub async fn mesh_on(&self) { let _ = self.reading().await; } }\n' >>"${t}/${KEYS}"
  _case "the session's lock taken in the key ring fails" 1 "names the engine's type" "${t}"

  t="${tmp}/second-handle"; _tree "${t}"
  printf 'impl SessionManager { fn rows(&self) { let _ = self.message_store.list_groups(); } }\n' >>"${t}/${KEYS}"
  _case "the second store handle in the key ring fails" 1 "names the engine's type" "${t}"

  # Check 3: what the relay driver names.
  t="${tmp}/other-item"; _tree "${t}"
  sed -i 's|        session.mesh_offer(event, &record);|        session.mesh_offer(event, \&record);\n        let _ = session.mesh_handoff().take();|' "${t}/${FANOUT}"
  _case "another mesh item inside publish_location fails" 1 "names the mesh item 'mesh_handoff'" "${t}"

  t="${tmp}/other-fn"; _tree "${t}"
  sed -i 's|    async fn older(&self, circle: &CircleManager) {}|    async fn older(\&self, circle: \&CircleManager) { circle.session().mesh_sharing_stopped(); }|' "${t}/${FANOUT}"
  _case "a mesh item in another function of the driver fails" 1 "names the mesh item 'mesh_sharing_stopped'" "${t}"

  t="${tmp}/type-item"; _tree "${t}"
  printf 'fn store(keys: &dyn MeshKeyStore) {}\n' >>"${t}/${FANOUT}"
  _case "a mesh type named in the driver fails" 1 "names the mesh item 'MeshKeyStore'" "${t}"

  t="${tmp}/drive-other-item"; _tree "${t}"
  sed -i 's|        circle.fold_mesh_counts(drive.from_circles, 0);|        let _ = session.mesh_handoff().take();|' "${t}/${FANOUT}"
  _case "a mesh item mesh_drive is not admitted for fails" 1 "names the mesh item 'mesh_handoff'" "${t}"

  t="${tmp}/drive-item-elsewhere"; _tree "${t}"
  sed -i 's|        let record = session.location_to_send(&message).await;|        let record = session.location_to_send(\&message).await;\n        let _ = session.ingest_from_mesh(event, now_ms).await;|' "${t}/${FANOUT}"
  _case "an item admitted for mesh_drive named in publish_location fails" 1 "names the mesh item 'ingest_from_mesh'" "${t}"

  t="${tmp}/drive-type-outside"; _tree "${t}"
  sed -i '1s|^|use crate::nostr::mls::MeshDrive;\n|' "${t}/${FANOUT}"
  _case "the drive's type named outside mesh_drive fails" 1 "names the mesh item 'MeshDrive'" "${t}"

  t="${tmp}/drive-module"; _tree "${t}"
  sed -i 's|        taken: Vec<crate::nostr::mls::MeshPacket>,|        taken: Vec<crate::mesh::packet::Packet>,|' "${t}/${FANOUT}"
  _case "the mesh module named in mesh_drive's own signature fails" 1 "${FANOUT} names the mesh module" "${t}"

  # Check 4: the one hand-off.
  t="${tmp}/second-call"; _tree "${t}"
  sed -i 's|    async fn older(&self, circle: &CircleManager) {}|    async fn older(\&self, circle: \&CircleManager) { circle.session().mesh_offer(event, \&record); }|' "${t}/${FANOUT}"
  _case "a second mesh_offer( call fails" 1 'must be called exactly once' "${t}"

  t="${tmp}/bridge-call"; _tree "${t}"
  printf 'pub fn offer(s: &SessionManager, e: &Event, r: &LocationToSend) { s.mesh_offer(e, r); }\n' >>"${t}/haven/rust_builder/src/api.rs"
  _case "mesh_offer( called from the FFI crate fails" 1 'must be called exactly once' "${t}"

  t="${tmp}/qualified-call"; _tree "${t}"
  printf 'pub fn offer(s: &SessionManager, e: &Event, r: &LocationToSend) { SessionManager::mesh_offer(s, e, r); }\n' >>"${t}/haven/rust_builder/src/api.rs"
  _case "mesh_offer( called by its path, not as a method, fails" 1 'must be called exactly once' "${t}"

  t="${tmp}/qualified-only"; _tree "${t}"
  sed -i 's|        session.mesh_offer(event, &record);|        SessionManager::mesh_offer(session, event, \&record);|' "${t}/${FANOUT}"
  _case "the one hand-off made by its path is still the one hand-off" 0 '' "${t}"

  t="${tmp}/no-call"; _tree "${t}"
  sed -i '/session.mesh_offer(event, &record);/d' "${t}/${FANOUT}"
  _case "no mesh_offer( call at all fails" 1 'must be called exactly once' "${t}"

  t="${tmp}/before-checks"; _tree "${t}"
  sed -i '/session.mesh_offer(event, &record);/d; s|        if !record.may_be_sent {|        session.mesh_offer(event, \&record);\n        if !record.may_be_sent {|' "${t}/${FANOUT}"
  _case "mesh_offer( before the may-be-sent check fails" 1 "before publish_location's send-time checks" "${t}"

  t="${tmp}/before-expiry"; _tree "${t}"
  sed -i '/session.mesh_offer(event, &record);/d; s|        if location_is_spent(record.expires_at_secs, now_ms) {|        session.mesh_offer(event, \&record);\n        if location_is_spent(record.expires_at_secs, now_ms) {|' "${t}/${FANOUT}"
  _case "mesh_offer( before the expiry check fails" 1 "before publish_location's send-time checks" "${t}"

  t="${tmp}/after-send"; _tree "${t}"
  sed -i '/session.mesh_offer(event, &record);/d; s|        let _ = session.end_location(&message).await;|        session.mesh_offer(event, \&record);\n        let _ = session.end_location(\&message).await;|' "${t}/${FANOUT}"
  _case "mesh_offer( after the relay send fails" 1 "not called before publish_location's relay send" "${t}"

  # Check 5: the relay path's own files.
  t="${tmp}/pool"; _tree "${t}"
  printf 'fn f(s: &SessionManager) { let _ = s.mesh_handoff(); }\n' >>"${t}/haven-core/src/relay/manager.rs"
  _case "a mesh item in the publish pool fails" 1 'haven-core/src/relay/manager.rs names a mesh item' "${t}"

  t="${tmp}/live"; _tree "${t}"
  printf 'fn f(store: &dyn MeshKeyStore) {}\n' >"${t}/haven-core/src/relay/live_sync/processor.rs"
  _case "a mesh item in a receive plane fails" 1 'haven-core/src/relay/live_sync/processor.rs names a mesh item' "${t}"

  t="${tmp}/sweep"; _tree "${t}"
  printf 'fn f(s: &SessionManager, g: &GroupId) { s.mesh_silence(g); }\n' >>"${t}/haven-core/src/relay/catchup.rs"
  _case "a mesh item in the catch-up sweep fails" 1 'haven-core/src/relay/catchup.rs names a mesh item' "${t}"

  t="${tmp}/other-relay-file"; _tree "${t}"
  printf 'fn f(s: &SessionManager) { let _ = s.mesh_handoff().take(); }\n' >"${t}/haven-core/src/relay/negentropy.rs"
  _case "a mesh item in any other file under relay/ fails" 1 'haven-core/src/relay/negentropy.rs names a mesh item' "${t}"

  t="${tmp}/other-nostr-file"; _tree "${t}"
  printf 'fn f(s: &SessionManager) { s.mesh_sharing_stopped(); }\n' >"${t}/haven-core/src/nostr/event.rs"
  _case "a mesh item in any other file under nostr/ fails" 1 'haven-core/src/nostr/event.rs names a mesh item' "${t}"

  t="${tmp}/mod-other-item"; _tree "${t}"
  printf 'pub(crate) use manager::MeshKeys;\n' >>"${t}/haven-core/src/nostr/mls/mod.rs"
  _case "a mesh item nostr/mls/mod.rs does not re-export by the list fails" 1 'haven-core/src/nostr/mls/mod.rs names a mesh item' "${t}"

  # Misconfiguration.
  t="${tmp}/no-mod"; _tree "${t}"
  rm "${t}/${MLS_MOD}"
  _case "a missing nostr/mls/mod.rs is a misconfiguration" 2 '' "${t}"

  t="${tmp}/no-keys"; _tree "${t}"
  rm "${t}/${KEYS}"
  _case "a missing key ring is a misconfiguration" 2 '' "${t}"

  t="${tmp}/vacuous"; _tree "${t}"
  sed -i '/crate::mesh::/d' "${t}/${KEYS}"
  _case "a key ring that names no mesh path is a misconfiguration, not a pass" 2 '' "${t}"

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
