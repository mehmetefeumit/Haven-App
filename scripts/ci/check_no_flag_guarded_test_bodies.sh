#!/usr/bin/env bash
#
# No integration-test body may begin by returning on a flag.
#
# `testWidgets('x', (tester) async { if (!liveSyncEnabled) return; … })` is a
# test that, on every build where the flag is off, does nothing and is
# reported PASSED: `integrationDriver` names no test, the reporter counts it
# under `+N`, and no skip is recorded anywhere (a `markTestSkipped` would at
# least be declared in tooling/e2e/expected_drive_skips.txt). e2e_combined.dart
# carried eight such M11 scenarios. A scenario that belongs to one build is
# REGISTERED only on that build (`if (!flag) return;` in the registering
# wrapper, before `testWidgets` is called), and the lane that runs it requires
# its end marker (tooling/e2e/expected_drive_markers.txt).
#
# What is flagged: under haven/integration_test, the callback handed to a
# test-registering call — `test(`, `testWidgets(`, `patrolTest(`, or any
# `…TestWidgets(` wrapper (`boundedTestWidgets`, `_m11ScenarioTestWidgets`,
# `_scenarioTestWidgets`) — whose first statement (after any
# `installThrowTimeErrorLogging();`) is `if (!<expr>) return;` or
# `if (!<expr>) { return; }`. What is not: an early return anywhere else — a
# helper's loop (`pump_helpers.dart`), a declared wrapper's registration gate,
# a later statement of a test body.
#
# Usage:
#   check_no_flag_guarded_test_bodies.sh [repo-root]
#   check_no_flag_guarded_test_bodies.sh --self-test
#
# Exit codes: 0 clean, 1 a flag-guarded body, 2 the guard cannot see (no Dart
# file, or no registration found — a scan that matched nothing proves nothing).

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
readonly SELF

# Prints `<file>:<line>` for every flag-guarded test body in the given files,
# then `REGISTRATIONS=<n>` (how many registering calls were read).
scan() {
  awk '
    function reset() { state = 0; seek = 0 }
    FNR == 1 { reset() }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    # A comment line never changes the state.
    line ~ /^[[:space:]]*(\/\/|\*|\/\*)/ { next }
    state == 2 {
      if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*installThrowTimeErrorLogging\(\);[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*if[[:space:]]*\([[:space:]]*!.*\)[[:space:]]*return[[:space:]]*;/) {
        print FILENAME ":" FNR
        reset()
        next
      }
      if (line ~ /^[[:space:]]*if[[:space:]]*\([[:space:]]*!.*\)[[:space:]]*\{[[:space:]]*$/) {
        state = 3
        at = FNR
        next
      }
      reset()
    }
    state == 3 {
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*return[[:space:]]*;/) print FILENAME ":" at
      reset()
      next
    }
    # A declaration of a wrapper is not a registration: its body is the gate.
    line ~ /^[[:space:]]*(void|Future<[^>]*>|static)[[:space:]]/ { next }
    line ~ /(^|[^A-Za-z0-9_.])(test|testWidgets|patrolTest|[A-Za-z_][A-Za-z0-9_]*TestWidgets)[[:space:]]*\(/ {
      registrations++
      state = 1
      seek = 0
    }
    state == 1 {
      if (line ~ /\)[[:space:]]*(async[[:space:]]*)?\{[[:space:]]*$/) {
        state = 2
        next
      }
      # The callback opens within a few lines of the call, or this was not one.
      if (++seek > 12) reset()
    }
    END { print "REGISTRATIONS=" registrations + 0 }
  ' "$@"
}

check() {
  local root="${1:-$(cd "$(dirname "${SELF}")/../.." && pwd)}" dir out hits n
  dir="${root}/haven/integration_test"
  local files=()
  if [[ -d "${dir}" ]]; then
    while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -name '*.dart' | sort)
  fi
  if (( ${#files[@]} == 0 )); then
    echo "ERROR: no .dart file under ${dir}; this guard has gone blind." >&2
    return 2
  fi
  out="$(scan "${files[@]}")"
  n="$(sed -n 's/^REGISTRATIONS=//p' <<<"${out}")"
  hits="$(grep -v '^REGISTRATIONS=' <<<"${out}" || true)"
  if (( n == 0 )); then
    echo "ERROR: no test registration found under ${dir}; this guard has gone blind." >&2
    return 2
  fi
  if [[ -n "${hits}" ]]; then
    echo "A test body under haven/integration_test begins by returning on a flag:" >&2
    sed 's/^/    * /' <<<"${hits}" >&2
    cat >&2 <<'EOF'

  On every build where that flag is off the test does nothing and is reported
  PASSED. Register it only where it can run — return from the registering
  wrapper before `testWidgets` is called (see `_m11ScenarioTestWidgets` in
  e2e_combined.dart) — and declare its end marker in
  tooling/e2e/expected_drive_markers.txt so the lane that runs it proves it ran.
EOF
    return 1
  fi
  echo "check_no_flag_guarded_test_bodies: OK — ${n} test registration(s) under" \
       "haven/integration_test, none begins by returning on a flag."
}

self_test() {
  local tmp fail=0 ran=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local d="${tmp}/haven/integration_test"
  mkdir -p "${d}"

  expect() { # <label> <want-rc> <fixture-body>
    local got=0
    ran=$(( ran + 1 ))
    rm -f "${d}"/*.dart
    printf '%s\n' "$3" > "${d}/fixture_test.dart"
    check "${tmp}" >/dev/null 2>&1 || got=$?
    if (( got != $2 )); then
      echo "SELF-TEST FAIL ($1): want rc $2, got rc ${got}" >&2
      fail=1
    fi
  }

  expect "testWidgets body returning on a flag" 1 "void main() {
  testWidgets('x', (tester) async {
    if (!liveSyncEnabled) return;
    await tester.pump();
  });
}"
  expect "a wrapper call with a split description" 1 "void main() {
  _m11ScenarioTestWidgets(
    'a — a peer location arrives '
    'well under the floor',
    (tester, generation) async {
      // why this scenario exists
      if (!liveSyncEnabled) return;
      await go();
    },
  );
}"
  expect "behind the error-logging install, in braces" 1 "void main() {
  boundedTestWidgets('y', (tester) async {
    installThrowTimeErrorLogging();

    if (!gatedInboxConfigured) {
      return;
    }
    await go();
  });
}"
  expect "a plain test() with a compound flag" 1 "void main() {
  test('z', () async {
    if (!a || b) return;
  });
}"
  expect "a wrapper declaration's registration gate is not a body" 0 "void main() {
  _m11ScenarioTestWidgets('a — x', (tester, generation) async {
    await go();
  });
}
void _m11ScenarioTestWidgets(
  String description,
  Future<void> Function(WidgetTester tester, int generation) callback,
) {
  if (!liveSyncEnabled) return;
  _scenarioTestWidgets(description, callback);
}"
  expect "a helper's early return is not a body" 0 "void main() {
  testWidgets('w', (tester) async {
    await poll();
  });
}
Future<void> poll() async {
  while (true) {
    if (!stillWaiting()) return;
  }
}"
  expect "a later statement of a body is not its start" 0 "void main() {
  testWidgets('v', (tester) async {
    final seen = await read();
    if (!seen) return;
  });
}"
  expect "a flag that fails the test is not an early return" 0 "void main() {
  testWidgets('u', (tester) async {
    if (!didInitCtx) {
      fail('setUpAll never ran');
    }
  });
}"
  expect "no registration at all is blindness" 2 "void helper() {}"

  if (( ran != 9 )); then
    echo "SELF-TEST FAIL: ran ${ran} fixture(s), expected 9" >&2
    fail=1
  fi
  if (( fail )); then
    echo "check_no_flag_guarded_test_bodies --self-test: FAILED" >&2
    return 1
  fi
  echo "check_no_flag_guarded_test_bodies --self-test: all ${ran} fixtures passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  *) check "${1:-}" ;;
esac
