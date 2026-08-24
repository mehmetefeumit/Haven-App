#!/usr/bin/env bash
# CI guard: the admin-handoff convergence gate must be able to SEE a fork.
#
# When Alice (admin) leaves a 3-member circle, Bob and Carol each ingest her
# bare `SelfRemove` proposal and each auto-commits it — a genuine
# concurrent-commit fork, and the exact shape production hits. The engine
# resolves it (deterministic branch selection; the loser rolls back and adopts
# the winner), and `_reconcileHandoff` in e2e_combined.dart exists to prove it.
#
# For a long time that proof was "Alice gone from both peers AND equal MLS
# epochs". Under the pre-migration single-committer election that was sound:
# only ONE SelfRemove commit ever existed, so equal epochs implied one branch.
# DM-4b deleted the election. Now BOTH peers commit at epoch N and BOTH land on
# epoch N+1 — two branches, one number. Neither surviving term can tell them
# apart:
#
#   * the residual member SET matches (both branches remove Alice), and
#   * the epoch NUMBER matches (both advanced by exactly one).
#
# So the gate passed on its first probe round while the group was still forked,
# and runs stayed green only because an explicitly NON-GATING, try/catch-
# swallowed location probe happened to drain the winner's commit into the loser
# as a side effect. CI run 32688074045: that probe's publish was lost to a
# dropped relay socket, the exception was swallowed as designed, the fork
# reached Phase 6 intact, Carol's `SelfRemove` was minted on an orphan branch
# Bob could never apply, and the leave observation timed out 60s later with
# `groupUpdates=0 members=2 stillHasLeaver=true`.
#
# What actually discriminates is a CURRENT-EPOCH CROSS-DECRYPT. Two branches at
# the same epoch number derive different epoch secrets, hence different
# `marmot/group-event` exporter secrets, so "Carol decrypts a location Bob
# minted at his current epoch" means Carol holds Bob's current-epoch secret —
# she is on his branch. This guard pins that term in place, because the reason
# it went missing the first time was not that anyone removed it: it was that a
# migration silently invalidated the reasoning behind a check that still read
# plausibly.
#
# Checks (a union — each one alone is removable without the others noticing):
#   1. `_HandoffConvergence` declares a `crossDecrypted` field, so the sample
#      the poll renders on timeout carries the branch fact.
#   2. `_reconcileHandoff`'s `satisfied:` predicate consumes `crossDecrypted`.
#      A field that is recorded but not gated on is decoration.
#   3. `_reconcileHandoff` calls the cross-decrypt helper, so the term is
#      actually computed per round rather than hard-coded.
#   4. The helper matches the probe's OWN coordinates (indexes
#      `decryptedLocations` and compares within `_coordEpsilon`). "Some decrypt
#      succeeded" is not enough: the engine's epoch lookback lets a location
#      minted at a SHARED PAST epoch decrypt on either branch, which is the
#      documented historical false positive.
#
# Pure-grep gate (no Flutter toolchain).
#
# Self-test:
#   bash scripts/ci/check_e2e_handoff_convergence_oracle.sh --self-test
#
# Exit codes:
#   0  all checks pass
#   1  the convergence oracle can no longer distinguish a fork
#   2  expected paths missing (misconfiguration)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

readonly SCENARIO='haven/integration_test/e2e/e2e_combined.dart'
# Named once so a rename fails loudly here instead of rotting into a
# vacuously-passing grep.
readonly RECONCILE_FN='_reconcileHandoff'
readonly PROBE_FN='_bobLocationReadableByCarol'
readonly FIELD='crossDecrypted'
readonly SAMPLE_TYPE='_HandoffConvergence'

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

# Prints the body of `_reconcileHandoff` — from its signature to the first
# column-0 `}` — so checks 2 and 3 cannot be satisfied by an occurrence
# somewhere else in this 6k-line file.
reconcile_body() { # reconcile_body <root>
  awk -v fn="${RECONCILE_FN}" '
    index($0, fn "({") { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$1/${SCENARIO}"
}

# Same slice for the cross-decrypt helper.
probe_body() { # probe_body <root>
  awk -v fn="${PROBE_FN}" '
    index($0, "Future<bool> " fn "({") { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$1/${SCENARIO}"
}

# 1. The convergence sample carries the branch fact.
check_sample_declares_field() { # <root>
  local body
  body="$(awk -v t="${SAMPLE_TYPE}" '
    index($0, "typedef " t " = ({") { inside = 1 }
    inside { print }
    inside && /\}\);/ { exit }
  ' "$1/${SCENARIO}")"
  if [[ -z "${body}" ]]; then
    fail "${SAMPLE_TYPE} not found in ${SCENARIO} — the handoff convergence sample was renamed or removed; update this guard alongside it."
    return 1
  fi
  if ! grep -qE "bool[[:space:]]+${FIELD}," <<<"${body}"; then
    fail "${SAMPLE_TYPE} has no 'bool ${FIELD}' field. Without it the poll's timeout message cannot say whether the peers shared a branch, and the remaining terms (member set, epoch number) are BOTH satisfied by a concurrent-commit fork."
    return 1
  fi
  return 0
}

# 2. The predicate gates on it.
check_predicate_gates_on_field() { # <root>
  local body
  body="$(reconcile_body "$1")"
  if [[ -z "${body}" ]]; then
    fail "${RECONCILE_FN} not found in ${SCENARIO} — the admin-handoff reconciliation was renamed or removed; update this guard alongside it."
    return 1
  fi
  # The `satisfied:` argument runs to the closing `);` of the _pollUntil call.
  local predicate
  predicate="$(awk '/satisfied:/ { inside = 1 } inside { print } inside && /^  \);/ { exit }' <<<"${body}")"
  if ! grep -qE "\.${FIELD}\b" <<<"${predicate}"; then
    fail "${RECONCILE_FN}'s satisfied: predicate does not consume '${FIELD}'. Gating only on 'Alice gone + equal epochs' passes on a FORK: both branches remove Alice and both advance one epoch (CI run 32688074045)."
    return 1
  fi
  return 0
}

# 3. The term is computed per round, not hard-coded.
check_reconcile_calls_probe() { # <root>
  if ! grep -qF "${PROBE_FN}(" <<<"$(reconcile_body "$1")"; then
    fail "${RECONCILE_FN} never calls ${PROBE_FN}() — '${FIELD}' is no longer derived from a real cross-decrypt, so it proves nothing."
    return 1
  fi
  return 0
}

# 4. The helper matches the probe's own coordinates, not mere decrypt success.
check_probe_matches_coordinates() { # <root>
  local body
  body="$(probe_body "$1")"
  if [[ -z "${body}" ]]; then
    fail "${PROBE_FN} not found in ${SCENARIO} — the cross-decrypt oracle was renamed or removed; update this guard alongside it."
    return 1
  fi
  if ! grep -qF 'decryptedLocations[' <<<"${body}"; then
    fail "${PROBE_FN} does not read decryptedLocations[...] — a sender-presence check cannot tell this round's probe from a location minted at a shared PAST epoch, which the engine's lookback decrypts on either branch."
    return 1
  fi
  if ! grep -qF '_coordEpsilon' <<<"${body}"; then
    fail "${PROBE_FN} does not compare the decrypted coordinates against the minted ones within _coordEpsilon — without that comparison any older Bob location satisfies the oracle."
    return 1
  fi
  return 0
}

run_all() { # <root>
  check_sample_declares_field "$1"
  check_predicate_gates_on_field "$1"
  check_reconcile_calls_probe "$1"
  check_probe_matches_coordinates "$1"
}

# ---------------------------------------------------------------------------
# Self-test: each check is pinned in BOTH directions against a fixture that has
# the shape of the real file, so a rewrite that guts the oracle fails here
# before it reaches the lane.
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

  # A fixture in the real file's shape: sample typedef, reconcile function with
  # a _pollUntil whose satisfied: consumes the field, and the probe helper.
  _mk() { # _mk <root> [--drop-field|--drop-gate|--drop-call|--presence-only]
    local r="$1" variant="${2:-}"
    mkdir -p "${r}/haven/integration_test/e2e"
    {
      echo 'Future<({int bob, int carol})>'
      echo "${RECONCILE_FN}({"
      echo '  required SyntheticUser bob,'
      echo '}) async {'
      echo '  final converged = await _pollUntil<_HandoffConvergence>('
      echo "    describe: 'converging',"
      echo '    probe: () async {'
      if [[ "${variant}" != "--drop-call" ]]; then
        echo "      final crossDecrypted = await ${PROBE_FN}("
        echo '        bob: bob,'
        echo '        round: 0,'
        echo '      );'
      else
        echo '      const crossDecrypted = true;'
      fi
      echo '      return ('
      echo '        bobEpoch: 1,'
      echo '        carolEpoch: 1,'
      echo '        crossDecrypted: crossDecrypted,'
      echo '      );'
      echo '    },'
      if [[ "${variant}" == "--drop-gate" ]]; then
        echo '    satisfied: (s) => s.bobEpoch == s.carolEpoch,'
      else
        echo '    satisfied: (s) =>'
        echo '        s.bobEpoch == s.carolEpoch &&'
        echo "        s.${FIELD},"
      fi
      echo '  );'
      echo '  return converged;'
      echo '}'
      echo
      echo "Future<bool> ${PROBE_FN}({"
      echo '  required SyntheticUser bob,'
      echo '  required int round,'
      echo '}) async {'
      echo '  const perRoundOffset = _coordEpsilon * 10;'
      echo '  final latitude = bobFakeLatitude + round * perRoundOffset;'
      echo '  final summary = await carol.drainPendingCommits();'
      if [[ "${variant}" == "--presence-only" ]]; then
        echo '  return summary.decryptedLocationSenders.contains(bob.pubkeyHex);'
      else
        echo '  final coords = summary.decryptedLocations[bob.pubkeyHex];'
        echo '  return coords != null &&'
        echo '      (coords.latitude - latitude).abs() < _coordEpsilon;'
      fi
      echo '}'
      echo
      echo "typedef ${SAMPLE_TYPE} = ({"
      echo '  int bobEpoch,'
      echo '  int carolEpoch,'
      if [[ "${variant}" != "--drop-field" ]]; then
        echo "  bool ${FIELD},"
      fi
      echo '});'
    } > "${r}/${SCENARIO}"
  }

  echo "self-test: ${RECONCILE_FN} convergence-oracle guard"

  local ok="${tmp}/ok"; _mk "${ok}"
  _case 'intact oracle passes every check (sample)'  0 check_sample_declares_field    "${ok}"
  _case 'intact oracle passes every check (gate)'    0 check_predicate_gates_on_field "${ok}"
  _case 'intact oracle passes every check (call)'    0 check_reconcile_calls_probe    "${ok}"
  _case 'intact oracle passes every check (coords)'  0 check_probe_matches_coordinates "${ok}"

  # The four ways the fork becomes invisible again, one per check.
  local nofield="${tmp}/nofield"; _mk "${nofield}" --drop-field
  _case 'sample without the branch field is caught' 1 check_sample_declares_field "${nofield}"

  # The regression that actually shipped: the field exists and is computed, but
  # the predicate falls back to epoch equality — which a fork satisfies.
  local nogate="${tmp}/nogate"; _mk "${nogate}" --drop-gate
  _case 'predicate back to epoch-equality-only is caught' 1 check_predicate_gates_on_field "${nogate}"

  local nocall="${tmp}/nocall"; _mk "${nocall}" --drop-call
  _case 'hard-coded crossDecrypted (no probe call) is caught' 1 check_reconcile_calls_probe "${nocall}"

  # The historical FALSE POSITIVE: decrypt-presence instead of a coordinate
  # match, which the engine's epoch lookback satisfies across branches.
  local presence="${tmp}/presence"; _mk "${presence}" --presence-only
  _case 'presence-only decrypt check is caught' 1 check_probe_matches_coordinates "${presence}"

  # Rot direction: a rename must fail loudly, never pass vacuously.
  local gone="${tmp}/gone"
  mkdir -p "${gone}/haven/integration_test/e2e"
  echo 'void main() {}' > "${gone}/${SCENARIO}"
  _case 'renamed/removed reconcile fails loudly (sample)' 1 check_sample_declares_field    "${gone}"
  _case 'renamed/removed reconcile fails loudly (gate)'   1 check_predicate_gates_on_field "${gone}"
  _case 'renamed/removed reconcile fails loudly (call)'   1 check_reconcile_calls_probe    "${gone}"
  _case 'renamed/removed reconcile fails loudly (coords)' 1 check_probe_matches_coordinates "${gone}"

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

  [[ -f "${REPO_ROOT}/${SCENARIO}" ]] || {
    echo "ERROR: ${SCENARIO} not found — update or delete this guard" >&2
    exit 2
  }

  run_all "${REPO_ROOT}"

  if (( FAILED )); then
    echo >&2
    echo "The admin-handoff convergence gate must prove ONE BRANCH, not one" >&2
    echo "epoch NUMBER: Bob and Carol both auto-commit Alice's SelfRemove, so" >&2
    echo "a fork leaves them on equal epochs with equal member sets. See the" >&2
    echo "doc on ${RECONCILE_FN} in ${SCENARIO}." >&2
    exit 1
  fi
  echo "E2E handoff convergence oracle: OK (fork-visible: current-epoch cross-decrypt gates the poll)."
}

main "$@"
