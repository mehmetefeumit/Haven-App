#!/usr/bin/env bash
#
# Guard: the Dart-side profile-relay override has exactly ONE install site.
#
# `set_profile_relays_for_test` retargets the kind-0 (profile) plane. Its Rust
# side is an install-once `OnceLock`
# (haven-core/src/profile/relay_pool.rs), so a SECOND install site does not
# override — it throws "set_profile_relays_for_test already installed", and
# which of the two racing sites wins depends on call order.
#
# That is not hypothetical. In CI run 30753193231 `e2e_profile_sharing` failed
# on both platforms for exactly this reason: `TestUser.bootstrapProcess` had
# gained an install (pointing the profile plane at the circle relay so it fails
# CLOSED for lanes that do not test profiles), while the profile scenario
# installed its own three-relay hermetic pool afterwards. The fix routed both
# through `bootstrapProcess`'s single call site — and this guard is what keeps
# that true, because the alternative is a comment asserting an invariant that
# nothing enforces. The ORIGINAL bug was likewise introduced under a comment
# claiming the profile lane "never calls this method".
#
# Why it matters beyond a broken lane: the profile plane is the one plane Haven
# PUBLISHES on (kind-0 with display name + Blossom picture URL, replaceable but
# not retractable). A second install site is also a second place a non-loopback
# relay could enter, and `bootstrapProcess` is where the loopback guard lives.
#
# Allowed:
#   * the FRB-generated bindings (haven/lib/src/rust/**) — the declaration.
#   * haven/integration_test/e2e/_lib/test_user.dart — THE call site.
#   * doc comments / prose mentioning the symbol (matched call-shape only).
#
set -euo pipefail

readonly SYMBOL='setProfileRelaysForTest'
readonly ALLOWED_CALL_SITE='haven/integration_test/e2e/_lib/test_user.dart'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

# Match the CALL shape (`setProfileRelaysForTest(`), not bare mentions, so
# documentation and `show` clauses do not trip the guard. Comment lines are
# dropped so a `/// ... setProfileRelaysForTest(...)` example stays legal.
violations="$(
  grep -rn --include='*.dart' "${SYMBOL}(" haven/lib haven/integration_test haven/test 2>/dev/null \
    | grep -v '^haven/lib/src/rust/' \
    | grep -v "^${ALLOWED_CALL_SITE}:" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(///|//|\*)' \
    || true
)"

if [[ -n "${violations}" ]]; then
  echo "ERROR: ${SYMBOL} must be called from exactly one place:" >&2
  echo "         ${ALLOWED_CALL_SITE}" >&2
  echo >&2
  echo "Unexpected call site(s):" >&2
  echo "${violations}" >&2
  echo >&2
  echo "The Rust override is install-once: a second call site throws" >&2
  echo "'already installed' and the winner depends on call order (CI run" >&2
  echo "30753193231). Pass the pool through instead —" >&2
  echo "  ScenarioHarness.bootstrap(profileRelays: <your pool>)" >&2
  echo "which reaches TestUser.bootstrapProcess, the one site that also" >&2
  echo "enforces the loopback guard on it." >&2
  exit 1
fi

echo "profile-override single-site guard: OK (only ${ALLOWED_CALL_SITE} installs ${SYMBOL})."
