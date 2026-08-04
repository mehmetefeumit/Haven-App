#!/usr/bin/env bash
#
# CI guard: the background catch-up lane must assert DELIVERY, not just
# bootstrap — and the mechanism that lets it must not drift into production.
#
# ## What went wrong (docs/CI_HARDENING_BACKLOG.md B2)
#
# `run-m7-background-catchup.sh` has always carried a `M7_REQUIRE_DECRYPT`
# switch that hard-asserts the cold worker decrypted the seeded peer location.
# It defaulted to 0 and was set in NO workflow, so for its entire life the
# `e2e-background-catchup` lane proved that a WorkManager wake BOOTS (Rust +
# keyring + SQLCipher + a sweep over >=1 circle) and never that anything was
# RECEIVED. It could not have: the debug `ws://` loopback opt-in is an
# install-once `OnceLock` with no on-disk form, so the cold worker rejected the
# plaintext CI relay before opening a socket — `circles=1 locations=0
# relayErrors=1`, verbatim, in CI run 30792258968.
#
# The fix has three load-bearing parts, and losing ANY one silently returns the
# lane to proving bootstrap under a name that says delivery. This guard pins
# all three, plus the boundary that keeps the fix out of the shipped app:
#
#   1. The workflow SETS M7_REQUIRE_DECRYPT=1, and the script still hard-fails
#      when delivery is not observed.
#   2. The CI-only dispatcher arms the opt-in in the cold process AND delegates
#      to the PRODUCTION wake body — a hand-copied gate chain would drift and
#      the lane would prove the copy.
#   3. Each m7_worker_* target registers that dispatcher.
#   4. The production worker library contains NO test hook: no ws:// opt-in, no
#      E2E dart-define. The opt-in relaxes the wss://-only transport policy, so
#      a call site inside `haven/lib` is a privacy boundary violation
#      (Security Rule 10), not a tidiness issue — release builds stub the Rust
#      side, but the call site itself must never exist there.
#
# Pure grep/bash, no toolchain — belongs in repo-guards.yml.
#
# Usage:
#   bash scripts/ci/check_m7_background_delivery_assertion.sh
#   bash scripts/ci/check_m7_background_delivery_assertion.sh --self-test

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

readonly WORKFLOW='.github/workflows/e2e-background-catchup.yml'
readonly RUNNER='tooling/e2e/ci/run-m7-background-catchup.sh'
readonly DISPATCHER='haven/integration_test/e2e/_lib/m7_worker_ci_oneoff.dart'
readonly PROD_WORKER='haven/lib/src/services/background_catchup_worker.dart'
readonly TARGETS=(
  'haven/integration_test/m7_worker_setup_test.dart'
  'haven/integration_test/m7_worker_pending_wipe_test.dart'
  'haven/integration_test/m7_worker_disable_test.dart'
)

# The production wake body the CI dispatcher must delegate to, and the opt-in
# it must arm. Named once so a rename fails here instead of rotting silently.
readonly WAKE_FN='runBackgroundCatchupWake'
readonly OPTIN_FN='allowWsLoopbackForTest'

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

# Strip Dart `//` line comments and `///` doc comments so a doc mention of a
# symbol can never satisfy a check that wants a real call. (Block comments are
# not used for code in these files; the checks below all match call shapes.)
dart_code() { grep -vE '^[[:space:]]*(///|//|\*)' "$1"; }

# Strip shell `#` comment lines for the same reason.
sh_code() { grep -vE '^[[:space:]]*#' "$1"; }

# ---------------------------------------------------------------------------
# Checks. Each takes an explicit root so --self-test can point them at fixtures.
# ---------------------------------------------------------------------------

# 1. The workflow declares M7_REQUIRE_DECRYPT: "1" (quoted or bare), in a real
#    env mapping and not in a comment.
check_workflow_sets_flag() {
  local root="$1" f="$1/${WORKFLOW}"
  [[ -f "${f}" ]] || { fail "${WORKFLOW} not found — the delivery lane is gone; update or delete this guard"; return 1; }
  local decl
  decl="$(grep -vE '^[[:space:]]*#' "${f}" | grep -cE '^[[:space:]]*M7_REQUIRE_DECRYPT:[[:space:]]*"?1"?[[:space:]]*$')"
  if (( decl < 1 )); then
    fail "${WORKFLOW} does not set M7_REQUIRE_DECRYPT: \"1\" — Phase A falls back to asserting bootstrap only, which is exactly the B2 regression (a lane proving less than its name)."
    return 1
  fi
  # A "0" anywhere would win depending on scope; refuse the ambiguity.
  if grep -vE '^[[:space:]]*#' "${f}" | grep -qE '^[[:space:]]*M7_REQUIRE_DECRYPT:[[:space:]]*"?0"?[[:space:]]*$'; then
    fail "${WORKFLOW} sets M7_REQUIRE_DECRYPT to 0 somewhere — the delivery assertion is disabled."
    return 1
  fi
  return 0
}

# 2. The runner still hard-fails on a missing decrypt, and its default is 1.
check_runner_still_asserts() {
  local root="$1" f="$1/${RUNNER}" code
  [[ -f "${f}" ]] || { fail "${RUNNER} not found"; return 1; }
  code="$(sh_code "${f}")"
  local rc=0
  grep -qE 'REQUIRE_DECRYPT="\$\{M7_REQUIRE_DECRYPT:-1\}"' <<<"${code}" || {
    fail "${RUNNER}: M7_REQUIRE_DECRYPT no longer defaults to 1 — a local or future caller that omits it silently drops the delivery assertion."
    rc=1
  }
  grep -qE 'fail "BACKGROUND DELIVERY FAILED' <<<"${code}" || {
    fail "${RUNNER}: the Phase-A delivery hard-fail is gone — nothing turns a missed peer location red."
    rc=1
  }
  return "${rc}"
}

# 3. The CI dispatcher arms the opt-in AND delegates to the production body.
check_dispatcher_shape() {
  local root="$1" f="$1/${DISPATCHER}" code
  [[ -f "${f}" ]] || { fail "${DISPATCHER} not found — the cold worker cannot reach the CI relay without it"; return 1; }
  code="$(dart_code "${f}")"
  local rc=0
  grep -qF "${OPTIN_FN}(" <<<"${code}" || {
    fail "${DISPATCHER}: does not call ${OPTIN_FN}() — the cold worker process cannot inherit the opt-in, so it will reject ws:// and Phase A will fail on a HARNESS gap that reads like a delivery regression."
    rc=1
  }
  grep -qF "${WAKE_FN}(" <<<"${code}" || {
    fail "${DISPATCHER}: does not delegate to ${WAKE_FN}() — a re-implemented gate chain drifts from production, and the lane would then prove the copy rather than the app."
    rc=1
  }
  grep -qF "@pragma('vm:entry-point')" <<<"${code}" || {
    fail "${DISPATCHER}: the CI dispatcher is not annotated @pragma('vm:entry-point') — tree-shaking drops it and WorkManager resolves a dead handle."
    rc=1
  }
  grep -qF 'Workmanager().initialize(' <<<"${code}" || {
    fail "${DISPATCHER}: never calls Workmanager().initialize() — the stored callback handle keeps pointing at the production dispatcher and the opt-in is never armed."
    rc=1
  }
  return "${rc}"
}

# 4. Every m7_worker_* target registers the CI dispatcher.
check_targets_register() {
  local root="$1" rc=0 t
  for t in "${TARGETS[@]}"; do
    local f="${root}/${t}"
    [[ -f "${f}" ]] || { fail "${t} not found"; rc=1; continue; }
    dart_code "${f}" | grep -qF 'registerM7CiOneOffCatchup(' || {
      fail "${t}: does not call registerM7CiOneOffCatchup() — its wake runs the production dispatcher, the relay is unreachable, and that phase's proof collapses."
      rc=1
    }
  done
  return "${rc}"
}

# 5. No test hook in the production worker library.
check_no_prod_test_hook() {
  local root="$1" f="$1/${PROD_WORKER}" code
  [[ -f "${f}" ]] || { fail "${PROD_WORKER} not found"; return 1; }
  code="$(dart_code "${f}")"
  local rc=0
  if grep -qiE 'allowWsLoopback|ws_loopback' <<<"${code}"; then
    fail "${PROD_WORKER}: references the ws:// loopback opt-in in executable code. That opt-in relaxes the wss://-only transport policy; it belongs ONLY in ${DISPATCHER} (Security Rule 10)."
    rc=1
  fi
  if grep -qE "(String|bool|int)\.fromEnvironment\([[:space:]]*'HAVEN_E2E" <<<"${code}"; then
    fail "${PROD_WORKER}: reads a HAVEN_E2E_* dart-define. The lane must not be wired into the shipped wake path — put it in ${DISPATCHER}."
    rc=1
  fi
  return "${rc}"
}

run_all() {
  local root="$1"
  check_workflow_sets_flag "${root}"
  check_runner_still_asserts "${root}"
  check_dispatcher_shape "${root}"
  check_targets_register "${root}"
  check_no_prod_test_hook "${root}"
}

# ---------------------------------------------------------------------------
# Self-test. Fixtures pin BOTH directions for every check: the shape that must
# pass, and the exact regression that must fail. A guard made of greps is worth
# only what its fixtures prove, and the failure mode being defended against
# here — a switch that exists, reads plausibly, and is set nowhere — is
# precisely the kind that sits green forever.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <fn> <root>
    local label="$1" want="$2" fn="$3" root="$4" got=0
    ( FAILED=0; "${fn}" "${root}" >/dev/null 2>&1 ) || got=1
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  # --- fixture builder: a minimal tree in the shape the guard expects --------
  _mk() { # _mk <root>
    local r="$1"
    mkdir -p "${r}/.github/workflows" "${r}/tooling/e2e/ci" \
             "${r}/haven/integration_test/e2e/_lib" \
             "${r}/haven/lib/src/services"
    cat > "${r}/${WORKFLOW}" <<'YAML'
jobs:
  e2e_background_catchup:
    env:
      HAVEN_E2E_RELAY: ws://10.0.2.2:7777
      M7_REQUIRE_DECRYPT: "1"
YAML
    cat > "${r}/${RUNNER}" <<'SH'
readonly REQUIRE_DECRYPT="${M7_REQUIRE_DECRYPT:-1}"
fail "BACKGROUND DELIVERY FAILED: worker did not apply the seeded peer location"
SH
    cat > "${r}/${DISPATCHER}" <<'DART'
@pragma('vm:entry-point')
void m7CiCallbackDispatcher() {
  Workmanager().executeTask((t, i) async {
    allowWsLoopbackForTest();
    return runBackgroundCatchupWake();
  });
}
Future<void> registerM7CiOneOffCatchup() async {
  await Workmanager().initialize(m7CiCallbackDispatcher);
}
DART
    local t
    for t in "${TARGETS[@]}"; do
      mkdir -p "${r}/$(dirname "${t}")"
      printf 'await registerM7CiOneOffCatchup();\n' > "${r}/${t}"
    done
    printf 'Future<bool> runBackgroundCatchupWake() async => true;\n' \
      > "${r}/${PROD_WORKER}"
  }

  echo "self-test: check 1 — workflow sets the flag"
  local ok="${tmp}/ok"; _mk "${ok}"
  _case "healthy tree passes" 0 check_workflow_sets_flag "${ok}"

  # THE CRITICAL FIXTURE: the defect itself. The switch exists in the script,
  # reads plausibly, and no workflow sets it.
  local unset_flag="${tmp}/unset"; _mk "${unset_flag}"
  cat > "${unset_flag}/${WORKFLOW}" <<'YAML'
jobs:
  e2e_background_catchup:
    env:
      HAVEN_E2E_RELAY: ws://10.0.2.2:7777
YAML
  _case "workflow that sets NOTHING fails (the B2 defect)" 1 check_workflow_sets_flag "${unset_flag}"

  # A comment mentioning the flag must not count as setting it.
  local commented="${tmp}/commented"; _mk "${commented}"
  cat > "${commented}/${WORKFLOW}" <<'YAML'
jobs:
  e2e_background_catchup:
    env:
      # M7_REQUIRE_DECRYPT: "1"
      HAVEN_E2E_RELAY: ws://10.0.2.2:7777
YAML
  _case "commented-out flag does not count" 1 check_workflow_sets_flag "${commented}"

  local zeroed="${tmp}/zeroed"; _mk "${zeroed}"
  cat > "${zeroed}/${WORKFLOW}" <<'YAML'
jobs:
  e2e_background_catchup:
    env:
      M7_REQUIRE_DECRYPT: "0"
YAML
  _case "explicit 0 fails" 1 check_workflow_sets_flag "${zeroed}"

  echo "self-test: check 2 — runner still hard-fails"
  _case "healthy runner passes" 0 check_runner_still_asserts "${ok}"
  local defaulted0="${tmp}/default0"; _mk "${defaulted0}"
  cat > "${defaulted0}/${RUNNER}" <<'SH'
readonly REQUIRE_DECRYPT="${M7_REQUIRE_DECRYPT:-0}"
fail "BACKGROUND DELIVERY FAILED: nope"
SH
  _case "default reverted to 0 fails" 1 check_runner_still_asserts "${defaulted0}"
  local nofail="${tmp}/nofail"; _mk "${nofail}"
  printf 'readonly REQUIRE_DECRYPT="${M7_REQUIRE_DECRYPT:-1}"\necho "evidence only"\n' \
    > "${nofail}/${RUNNER}"
  _case "hard-fail removed fails" 1 check_runner_still_asserts "${nofail}"

  echo "self-test: check 3 — dispatcher arms the opt-in AND delegates"
  _case "healthy dispatcher passes" 0 check_dispatcher_shape "${ok}"
  local nooptin="${tmp}/nooptin"; _mk "${nooptin}"
  cat > "${nooptin}/${DISPATCHER}" <<'DART'
@pragma('vm:entry-point')
void m7CiCallbackDispatcher() {
  Workmanager().executeTask((t, i) async => runBackgroundCatchupWake());
}
Future<void> registerM7CiOneOffCatchup() async {
  await Workmanager().initialize(m7CiCallbackDispatcher);
}
DART
  _case "dispatcher without the opt-in fails" 1 check_dispatcher_shape "${nooptin}"

  local copied="${tmp}/copied"; _mk "${copied}"
  cat > "${copied}/${DISPATCHER}" <<'DART'
@pragma('vm:entry-point')
void m7CiCallbackDispatcher() {
  Workmanager().executeTask((t, i) async {
    allowWsLoopbackForTest();
    // a hand-rolled copy of the gate chain instead of the production body
    return runBackgroundCatchupTask(isRunningService: () async => false);
  });
}
Future<void> registerM7CiOneOffCatchup() async {
  await Workmanager().initialize(m7CiCallbackDispatcher);
}
DART
  _case "dispatcher that re-implements the wake fails" 1 check_dispatcher_shape "${copied}"

  local docmention="${tmp}/docmention"; _mk "${docmention}"
  cat > "${docmention}/${DISPATCHER}" <<'DART'
/// Calls allowWsLoopbackForTest() and runBackgroundCatchupWake().
/// @pragma('vm:entry-point')
void m7CiCallbackDispatcher() {}
DART
  _case "doc comments alone do not satisfy the shape" 1 check_dispatcher_shape "${docmention}"

  echo "self-test: check 4 — every target registers the dispatcher"
  _case "all targets register" 0 check_targets_register "${ok}"
  local onemissing="${tmp}/onemissing"; _mk "${onemissing}"
  printf '// forgot to register\n' > "${onemissing}/${TARGETS[2]}"
  _case "one target forgetting to register fails" 1 check_targets_register "${onemissing}"

  echo "self-test: check 5 — no test hook in production"
  _case "clean production worker passes" 0 check_no_prod_test_hook "${ok}"
  local leaked="${tmp}/leaked"; _mk "${leaked}"
  printf 'void wake() { allowWsLoopbackForTest(); }\n' > "${leaked}/${PROD_WORKER}"
  _case "opt-in leaked into production fails" 1 check_no_prod_test_hook "${leaked}"
  local defined="${tmp}/defined"; _mk "${defined}"
  printf "const r = String.fromEnvironment('HAVEN_E2E_RELAY');\n" \
    > "${defined}/${PROD_WORKER}"
  _case "HAVEN_E2E dart-define in production fails" 1 check_no_prod_test_hook "${defined}"
  local documented="${tmp}/documented"; _mk "${documented}"
  printf '/// See allowWsLoopbackForTest() in the harness.\nvoid wake() {}\n' \
    > "${documented}/${PROD_WORKER}"
  _case "doc mention in production is allowed" 0 check_no_prod_test_hook "${documented}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  echo "self-test: OK"
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

  run_all "${REPO_ROOT}"

  if (( FAILED )); then
    echo >&2
    echo "The e2e-background-catchup lane must prove BACKGROUND DELIVERY, not" >&2
    echo "just that a wake boots. See docs/CI_HARDENING_BACKLOG.md B2 and the" >&2
    echo "header of ${RUNNER}." >&2
    exit 1
  fi
  echo "M7 background-delivery assertion guard: OK (lane asserts peer decrypt; no test hook in production)."
}

main "$@"
