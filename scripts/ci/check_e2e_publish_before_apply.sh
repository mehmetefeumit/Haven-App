#!/usr/bin/env bash
# CI guard: a harness must deliver what it founds, and never resolve a staged
# commit itself; the product rolls a commit back from one site.
#
# ## The first root: integration tests that found a circle on the FFI
#
# A founded circle is canonical the moment `RelayManagerFfi.createCircleDriven`
# returns (MDK v0.10.4 `PublishWork::FoundingGroupCreated`): there is no staged
# create left to confirm or roll back. The driven create records each founding
# Welcome and sends it from that record; no Welcome event reaches Dart, and the
# plain publish refuses a gift wrap. What a harness can still get wrong is to
# take a Welcome no relay acknowledged as delivered — an invitee whose Welcome
# never reached a relay never joins, and the scenario then fails on the
# RECEIVE path ("peer location never surfaced", a timeout) with nothing
# pointing back at the create.
#
# The shared helper `createCircleDelivered`
# (haven/integration_test/e2e/_lib/circle_creation.dart) is the one place a
# harness calls the driven create, and it requires every Welcome to be
# acknowledged during the call. This guard keeps every direct-FFI create on it,
# and keeps the shapes of the deleted Dart-published create (its result type,
# its `welcomeEvents`, `publishWelcome`, `GiftWrappedWelcome`) out of the
# integration tests.
#
# Nor can a harness resolve a staged commit: the bridge carries no confirm, no
# rollback and no pending ref since the fanout driver became the only way a
# commit leaves the device (Security Rule 13). The guard keeps the deleted
# symbols out of the integration tests, so a stale harness fails here rather
# than as a compile error far from its cause.
#
# ## The second root: the Tier-1 soak rig
#
# `tooling/soak` reaches the same engine from Rust, and the rule binds it
# harder: it is the world's only publisher, and the soak grades the SHIPPED
# publish path only if every commit it makes is staged, sent, confirmed and
# rolled back by the product's own durable-fanout driver
# (`haven_core::relay::fanout::Publishing`, the rig's `DeviceDriver`). A rig
# that resolved a staged commit itself — `confirm_published`,
# `finalize_relay_update`, `publish_failed`, or the legacy receive entry that
# hands a commit back to its caller, `decrypt_location_collecting_commits` —
# would grade a publish path the product does not have, and could merge a
# commit no relay ever acknowledged.
#
# ## The third: the one rollback
#
# The engine's fanout rollback, `publish_failed_fanout`, is called from one
# site in the three source trees: the driver's own rollback of a record every
# relay proved it refused (`haven-core/src/nostr/mls/manager.rs`).
#
# Pure-grep gate (no Flutter or Rust toolchain) so it runs fast and
# independently; file-level granularity keeps it a flat grep.
#
# Checks:
#   1. No integration-test file names a deleted resolution or Welcome-publish
#      symbol — `confirmPublished(`, `publishFailed(`, `finalizeRelayUpdate(`,
#      `decryptLocationCollectingCommits(`, `PendingStateRefFfi`,
#      `CommitToPublishFfi`, `publishWelcome(`, `GiftWrappedWelcome`,
#      `CircleCreationResultFfi`, `.welcomeEvents` — in code rather than in a
#      comment; and none but the helper file calls `.createCircleDriven(`.
#   2. No file under tooling/soak resolves a staged commit itself: none calls
#      `confirm_published(`, `finalize_relay_update(`, `publish_failed(` or
#      `decrypt_location_collecting_commits(`, in code rather than in a
#      comment; and the rig's publish path, `src/rig/circle.rs`, builds the
#      product's driver (`Publishing {`).
#   3. `publish_failed_fanout(` is called, in code, exactly once across
#      haven-core/src, haven/rust_builder/src and tooling/soak/src, and that
#      once is in haven-core/src/nostr/mls/manager.rs.
#
# Usage:
#   check_e2e_publish_before_apply.sh              run both checks over the tree
#   check_e2e_publish_before_apply.sh --self-test  fixtures, both directions
#
# Exit codes:
#   0  all checks pass
#   1  a harness founds a circle it never delivers or names a deleted
#      resolution symbol, the rig resolves a staged commit itself, or the
#      fanout rollback is called from a second site
#   2  expected paths missing (misconfiguration) or the self-test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly IT_REL='haven/integration_test'
readonly HELPER_REL="${IT_REL}/e2e/_lib/circle_creation.dart"
readonly SOAK_REL='tooling/soak'
readonly ROLLBACK_SITE_REL='haven-core/src/nostr/mls/manager.rs'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=24

log() {
  printf '\033[1;34m[check_e2e_publish_before_apply]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_e2e_publish_before_apply] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

# ---------------------------------------------------------------------------
# Check 1: no integration test names a deleted resolution symbol, and none
# founds a circle it never delivers.
# ---------------------------------------------------------------------------
check_dart_names_no_resolution() { # <root>
  local root="$1" it="$1/${IT_REL}"
  [[ -d "${it}" ]] || return 0
  local violations="" file
  local symbols='confirmPublished\(|publishFailed\(|finalizeRelayUpdate\(|decryptLocationCollectingCommits\(|PendingStateRefFfi|CommitToPublishFfi|publishWelcome\(|GiftWrappedWelcome|CircleCreationResultFfi|\.welcomeEvents'
  while IFS= read -r file; do
    if grep -vE '^[[:space:]]*//' "${file}" 2>/dev/null | grep -E "${symbols}" >/dev/null; then
      violations+="  ${file#"${root}/"}"$'\n'
    fi
  done < <(find "${it}" -type f -name '*.dart' | sort)

  if [[ -n "${violations}" ]]; then
    printf '%s' "${violations}" >&2
    fail "the file(s) above name a resolution or a Welcome publish the bridge no longer carries. A commit is staged, sent, confirmed and rolled back by the fanout driver alone, and a founding Welcome is sent from its record (Security Rule 13); drive the change through its driven entry (a create through createCircleDelivered) and read its typed outcome"
  fi
}

check_dart_creates_are_delivered() { # <root>
  local root="$1" it="$1/${IT_REL}" helper="$1/${HELPER_REL}"
  [[ -d "${it}" ]] || return 0
  local violations="" file
  while IFS= read -r file; do
    # The helper itself defines the sanctioned wrapper — skip it.
    [[ "${file}" == "${helper}" ]] && continue
    # Comment lines are dropped: prose naming the call has not made it. No
    # `-q` on the reader: an early exit would SIGPIPE the filter and
    # `pipefail` would report the match as a miss.
    if grep -vE '^[[:space:]]*//' "${file}" 2>/dev/null \
         | grep -F '.createCircleDriven(' >/dev/null; then
      violations+="  ${file#"${root}/"}"$'\n'
    fi
  done < <(find "${it}" -type f -name '*.dart' | sort)

  if [[ -n "${violations}" ]]; then
    printf '%s' "${violations}" >&2
    fail "the file(s) above call createCircleDriven() themselves, so nothing requires its Welcomes to have been acknowledged — an invitee whose Welcome never reached a relay never joins, and the scenario times out on the receive path. Route the create through createCircleDelivered() in e2e/_lib/circle_creation.dart"
  fi
}

# ---------------------------------------------------------------------------
# Check 2: no soak source or test resolves a staged commit itself; the rig's
# publish path is the product's driver.
# ---------------------------------------------------------------------------
check_soak_commits_go_through_the_driver() { # <root>
  local root="$1" soak="$1/${SOAK_REL}"
  [[ -d "${soak}" ]] || return 0
  local violations="" file
  local rungs='confirm_published\(|finalize_relay_update\(|publish_failed\(|decrypt_location_collecting_commits\('
  while IFS= read -r file; do
    # Comment lines are dropped: prose naming a rung has not called it.
    if grep -vE '^[[:space:]]*//' "${file}" 2>/dev/null | grep -E "${rungs}" >/dev/null; then
      violations+="  ${file#"${root}/"}"$'\n'
    fi
  done < <(find "${soak}/src" "${soak}/tests" -type f -name '*.rs' 2>/dev/null | sort)

  if [[ -n "${violations}" ]]; then
    printf '%s' "${violations}" >&2
    fail "the file(s) above resolve a staged commit themselves. Every commit the rig makes goes through the product's driver (rig/circle.rs DeviceDriver over haven_core::relay::fanout::Publishing), which confirms only on a relay's OK and rolls back only on a proven refusal (Security Rule 13); a rig that resolves commits itself grades a publish path the product does not have"
  fi
  local circle="${soak}/src/rig/circle.rs"
  if ! grep -vE '^[[:space:]]*//' "${circle}" 2>/dev/null | grep -F 'Publishing {' >/dev/null; then
    fail "${circle#"${root}/"} no longer builds the product's driver (Publishing { … }): the rig's one publish path for commits is gone or moved — restore it, or update this guard"
  fi
}

# ---------------------------------------------------------------------------
# Check 3: the fanout rollback has one call site.
# ---------------------------------------------------------------------------
check_one_fanout_rollback_site() { # <root>
  local root="$1" sites="" file count=0 n
  while IFS= read -r file; do
    n="$(grep -vE '^[[:space:]]*//' "${file}" 2>/dev/null | grep -cF 'publish_failed_fanout(' || true)"
    if (( n > 0 )); then
      count=$(( count + n ))
      sites+="  ${file#"${root}/"} (${n})"$'\n'
    fi
  done < <(find "${root}/haven-core/src" "${root}/haven/rust_builder/src" "${root}/${SOAK_REL}/src" \
             -type f -name '*.rs' 2>/dev/null | sort)
  if (( count != 1 )) || [[ "${sites}" != "  ${ROLLBACK_SITE_REL} (1)"$'\n' ]]; then
    printf '%s' "${sites}" >&2
    fail "publish_failed_fanout( must be called exactly once, in ${ROLLBACK_SITE_REL}: the driver's rollback of a record every relay proved it refused, and no other — a second site could roll back a commit a relay may hold (Security Rule 13)"
  fi
}

run_all() { # <root>
  check_dart_names_no_resolution "$1"
  check_dart_creates_are_delivered "$1"
  check_soak_commits_go_through_the_driver "$1"
  check_one_fanout_rollback_site "$1"
}

# ---------------------------------------------------------------------------
# Self-test. Every check has a fixture in BOTH directions — the shape that must
# pass and the exact regression that must fail — plus the routes by which each
# could rot into a rubber stamp (a root that is absent, a helper that is
# skipped).
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <fn> <root>
    local label="$1" want="$2" fn="$3" root="$4" got=0
    checked=$(( checked + 1 ))
    ( FAILED=0; "${fn}" "${root}" >/dev/null 2>&1; exit "${FAILED}" ) || got=1
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _mk() { # _mk <root> — a tree in the shape every root expects
    local r="$1"
    mkdir -p "${r}/${IT_REL}/e2e/_lib" "${r}/${SOAK_REL}/src/rig" "${r}/${SOAK_REL}/tests" \
      "${r}/haven-core/src/nostr/mls" "${r}/haven/rust_builder/src"
    printf 'async fn roll_back_fanout() { session.publish_failed_fanout(p, f).await; }\n' \
      > "${r}/${ROLLBACK_SITE_REL}"
    printf 'pub fn api() {}\n' > "${r}/haven/rust_builder/src/api.rs"
    printf 'Future<void> createCircleDelivered() async { final o = await rm.createCircleDriven(); require(o); }\n' \
      > "${r}/${HELPER_REL}"
    printf 'void main() { createCircleDelivered(); }\n' \
      > "${r}/${IT_REL}/e2e/flow_test.dart"
    printf 'pub fn publishing(&self) -> Publishing<T> { Publishing { fanout: &self.t } }\n' \
      > "${r}/${SOAK_REL}/src/rig/circle.rs"
    printf 'fn control() { let _ = world.change(d, c); }\n' \
      > "${r}/${SOAK_REL}/tests/oracles.rs"
  }

  echo "check_e2e_publish_before_apply.sh --self-test"

  # The compliant tree, both roots.
  local ok="${tmp}/ok"; _mk "${ok}"
  _case "a Dart create routed through the helper passes" 0 check_dart_creates_are_delivered "${ok}"
  _case "a soak commit through the driver passes" 0 check_soak_commits_go_through_the_driver "${ok}"
  _case "an integration test naming no resolution passes" 0 check_dart_names_no_resolution "${ok}"
  _case "the one fanout rollback site passes" 0 check_one_fanout_rollback_site "${ok}"

  local resolves="${tmp}/resolves"; _mk "${resolves}"
  printf 'void main() async { await manager.confirmPublished(pending: p); }\n' \
    > "${resolves}/${IT_REL}/e2e/flow_test.dart"
  _case "an integration test confirming a commit itself fails" 1 check_dart_names_no_resolution "${resolves}"

  local holds_ref="${tmp}/holds-ref"; _mk "${holds_ref}"
  printf 'void keep(PendingStateRefFfi p) {}\n' \
    > "${holds_ref}/${IT_REL}/e2e/flow_test.dart"
  _case "an integration test holding a pending ref fails" 1 check_dart_names_no_resolution "${holds_ref}"

  local names_in_comment="${tmp}/names-in-comment"; _mk "${names_in_comment}"
  printf '// publishFailed( once lived here.\nvoid main() { createCircleDelivered(); }\n' \
    > "${names_in_comment}/${IT_REL}/e2e/flow_test.dart"
  _case "a comment naming a deleted symbol is not a use" 0 check_dart_names_no_resolution "${names_in_comment}"

  local second_site="${tmp}/second-site"; _mk "${second_site}"
  printf 'pub async fn undo() { s.publish_failed_fanout(p, f).await; }\n' \
    > "${second_site}/haven/rust_builder/src/api.rs"
  _case "a second fanout rollback site fails" 1 check_one_fanout_rollback_site "${second_site}"

  local moved_site="${tmp}/moved-site"; _mk "${moved_site}"
  printf 'fn none() {}\n' > "${moved_site}/${ROLLBACK_SITE_REL}"
  mkdir -p "${moved_site}/haven-core/src/relay"
  printf 'async fn settle() { s.publish_failed_fanout(p, f).await; }\n' \
    > "${moved_site}/haven-core/src/relay/fanout.rs"
  _case "a rollback moved out of its reviewed file fails" 1 check_one_fanout_rollback_site "${moved_site}"

  local no_site="${tmp}/no-site"; _mk "${no_site}"
  printf '// publish_failed_fanout( is the driver'"'"'s.\nfn none() {}\n' > "${no_site}/${ROLLBACK_SITE_REL}"
  _case "no rollback site at all fails" 1 check_one_fanout_rollback_site "${no_site}"

  # The regressions, one per check.
  local handed="${tmp}/handed"; _mk "${handed}"
  printf 'void main() async { final c = await ffi.createCircle(); bob.process(c.welcomeEvents.first); }\n' \
    > "${handed}/${IT_REL}/e2e/flow_test.dart"
  _case "a test handing over the old create's welcomeEvents fails" 1 check_dart_names_no_resolution "${handed}"

  local publishes_welcome="${tmp}/publishes-welcome"; _mk "${publishes_welcome}"
  printf 'void main() async { await relay.publishWelcome(welcomeEvent: w); }\n' \
    > "${publishes_welcome}/${IT_REL}/e2e/flow_test.dart"
  _case "a test publishing a Welcome itself fails" 1 check_dart_names_no_resolution "${publishes_welcome}"

  local old_result="${tmp}/old-result"; _mk "${old_result}"
  printf 'final CircleCreationResultFfi creation;\n' \
    > "${old_result}/${IT_REL}/e2e/flow_test.dart"
  _case "a test naming the deleted create result fails" 1 check_dart_names_no_resolution "${old_result}"

  local bad_dart="${tmp}/bad-dart"; _mk "${bad_dart}"
  printf 'void main() { rm.createCircleDriven(circle: m, foreground: true); }\n' \
    > "${bad_dart}/${IT_REL}/e2e/flow_test.dart"
  _case "a driven create outside the helper fails" 1 check_dart_creates_are_delivered "${bad_dart}"

  local commented_dart="${tmp}/commented-dart"; _mk "${commented_dart}"
  printf '// rm.createCircleDriven( is what the helper calls.\nvoid main() { createCircleDelivered(); }\n' \
    > "${commented_dart}/${IT_REL}/e2e/flow_test.dart"
  _case "a comment naming the driven create is not a call" 0 check_dart_creates_are_delivered "${commented_dart}"

  local bad_confirm="${tmp}/bad-confirm"; _mk "${bad_confirm}"
  printf 'fn helper() { mgr.confirm_published(p); }\n' \
    > "${bad_confirm}/${SOAK_REL}/tests/oracles.rs"
  _case "a soak confirm of its own fails" 1 check_soak_commits_go_through_the_driver "${bad_confirm}"

  local bad_finalize="${tmp}/bad-finalize"; _mk "${bad_finalize}"
  printf 'fn helper() { mgr.finalize_relay_update(p, g); }\n' \
    > "${bad_finalize}/${SOAK_REL}/tests/oracles.rs"
  _case "a soak finalize of its own fails" 1 check_soak_commits_go_through_the_driver "${bad_finalize}"

  local bad_rollback="${tmp}/bad-rollback"; _mk "${bad_rollback}"
  mkdir -p "${bad_rollback}/${SOAK_REL}/src/scenarios"
  printf 'async fn arm() { mgr.publish_failed(staged.pending).await; }\n' \
    > "${bad_rollback}/${SOAK_REL}/src/scenarios/s18.rs"
  _case "a soak rollback of its own, in a scenario source, fails" 1 check_soak_commits_go_through_the_driver "${bad_rollback}"

  local bad_receive="${tmp}/bad-receive"; _mk "${bad_receive}"
  printf 'async fn arm() { let i = mgr.decrypt_location_collecting_commits(&e).await; }\n' \
    > "${bad_receive}/${SOAK_REL}/tests/oracles.rs"
  _case "the legacy receive entry that hands a commit back fails" 1 check_soak_commits_go_through_the_driver "${bad_receive}"

  local commented="${tmp}/commented"; _mk "${commented}"
  printf '// confirm_published( is what the product calls inside its driver.\nfn helper() { let _ = world.change(d, c); }\n' \
    > "${commented}/${SOAK_REL}/tests/oracles.rs"
  _case "a comment naming a rung is not a call" 0 check_soak_commits_go_through_the_driver "${commented}"

  local no_driver="${tmp}/no-driver"; _mk "${no_driver}"
  printf '// Publishing { fanout } once lived here.\npub fn nothing() {}\n' \
    > "${no_driver}/${SOAK_REL}/src/rig/circle.rs"
  _case "a rig whose publish path no longer builds the driver fails" 1 check_soak_commits_go_through_the_driver "${no_driver}"

  # The helper is the one allowed definition site; skipping it must not skip
  # anything else.
  local helper_only="${tmp}/helper-only"; _mk "${helper_only}"
  rm -f "${helper_only}/${IT_REL}/e2e/flow_test.dart"
  _case "the sanctioned helper alone passes" 0 check_dart_creates_are_delivered "${helper_only}"

  # An absent root is inert rather than clean-by-accident in the other
  # direction: the full run below is what requires both to exist.
  local no_soak="${tmp}/no-soak"; _mk "${no_soak}"
  rm -rf "${no_soak:?}/${SOAK_REL}"
  _case "an absent soak root is inert" 0 check_soak_commits_go_through_the_driver "${no_soak}"
  local no_dart="${tmp}/no-dart"; _mk "${no_dart}"
  rm -rf "${no_dart:?}/${IT_REL}"
  _case "an absent integration-test root is inert" 0 check_dart_creates_are_delivered "${no_dart}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
  return 0
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
  fi
  if [[ $# -gt 0 ]]; then
    echo "usage: $(basename "$0") [--self-test]" >&2
    exit 2
  fi

  [[ -d "${REPO_ROOT}/${IT_REL}" ]] || {
    echo "ERROR: ${IT_REL} not found" >&2; exit 2;
  }
  [[ -f "${REPO_ROOT}/${HELPER_REL}" ]] || {
    echo "ERROR: ${HELPER_REL} not found — the sanctioned publish-before-apply" \
         "helper is missing; restore it or update this guard" >&2
    exit 2
  }
  [[ -d "${REPO_ROOT}/${SOAK_REL}/src" ]] || {
    echo "ERROR: ${SOAK_REL}/src not found — the rig is the second root this" \
         "guard owns; restore it or update this guard" >&2
    exit 2
  }

  FAILED=0
  log "Scanning ${IT_REL}, ${SOAK_REL} and the fanout rollback for unwitnessed staged commits ..."
  run_all "${REPO_ROOT}"
  if (( FAILED )); then
    exit 1
  fi
  log "OK: every founded circle in the harnesses goes through the delivering helper, no harness resolves a commit, every commit the rig makes goes through the product's driver, and the fanout rollback has its one site."
}

main "$@"
