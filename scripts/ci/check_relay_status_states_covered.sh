#!/usr/bin/env bash
# CI guard: every state the Relays page can show is proved somewhere, and
# every proof the device lane cites exists.
#
# The relay-management device target
# (haven/integration_test/relay_management_status_test.dart) maps each
# `KindPresence` value, in one exhaustive `switch` (`_proofOf`), either to
# `_SeenOnDevice()` — the drive asserts it saw that state on the real page —
# or to `_ProvedBy('<repo path>', '<test name>')`, a Rust (L1) or Flutter (L2)
# test that proves a state no device run can hold on screen (a transient
# between two polls, a hold the harness cannot reach). The compiler makes the
# switch exhaustive and the drive checks every `_SeenOnDevice` state was seen.
# What neither can see is a citation that names a test which does not exist —
# a renamed or deleted test would leave a state "proved" by nothing. That is
# this guard. A name grep would pass on a comment, so a test counts only as a
# DEFINITION: `fn <name>(` under a `#[test]`/`#[tokio::test…]` attribute, or a
# `test(` / `testWidgets(` whose first argument is the name, comments stripped.
#
# Checks:
#   1. `_proofOf` exists once, has no wildcard or default arm, and has exactly
#      one arm per `KindPresence` value declared in
#      haven/lib/src/providers/relay_status_provider.dart.
#   2. Every arm is `_SeenOnDevice()` or `_ProvedBy(<path>, <name>)`.
#   3. Every cited path exists and defines the cited test.
#
# Usage:
#   bash scripts/ci/check_relay_status_states_covered.sh
#   bash scripts/ci/check_relay_status_states_covered.sh --self-test
#
# Exit codes: 0 pass, 1 a check failed, 2 an expected file is missing.

set -euo pipefail

readonly TARGET_REL='haven/integration_test/relay_management_status_test.dart'
readonly ENUM_REL='haven/lib/src/providers/relay_status_provider.dart'

# Comment lines out, one line, whitespace squeezed, no space after `(`, and
# Dart's adjacent single-quoted literals ('a ' 'b') joined into one, the shape
# dart format gives a long test name.
flatten() { # reads stdin
  tr '\n' ' ' | tr -s '[:space:]' ' ' | sed -e 's/( /(/g' -e "s/' '//g"
}
collapse() { # <file>
  sed -e 's@^[[:space:]]*//.*$@@' -e 's@[[:space:]]//[^'"'"']*$@@' "$1" | flatten
}

enum_values() { # <enum file>
  collapse "$1" \
    | grep -oE 'enum KindPresence \{[^}]*\}' \
    | sed -e 's/^enum KindPresence {//' -e 's/}$//' -e 's/;.*//' \
    | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e 's/(.*//' | grep -E '^[a-zA-Z][a-zA-Z0-9]*$' \
    | LC_ALL=C sort
}

proof_body() { # <target file>
  awk '
    /_proofOf\(KindPresence/ { inside = 1; seen++ }
    inside && /^[[:space:]]*\/\// { next }
    inside { print }
    inside && /^[[:space:]]*};[[:space:]]*$/ { inside = 0 }
    END { if (seen != 1) exit 3 }
  ' "$1"
}

defines_rust_test() { # <file> <name>
  awk -v name="$2" '
    /^[[:space:]]*#\[(tokio::)?test/ { attr = NR }
    $0 ~ "^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn " name "[[:space:]]*\\(" {
      if (attr && NR - attr <= 3) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

defines_dart_test() { # <file> <name>
  local text
  text="$(collapse "$1")"
  grep -qF -- "test('$2'" <<<"${text}" || grep -qF -- "testWidgets('$2'" <<<"${text}"
}

check_root() { # <root>
  local root="$1" target enum_file body arms values fail=0 path name
  target="${root}/${TARGET_REL}"
  enum_file="${root}/${ENUM_REL}"
  for path in "${target}" "${enum_file}"; do
    if [[ ! -f "${path}" ]]; then
      echo "ERROR: ${path#"${root}/"} not found" >&2
      return 2
    fi
  done
  if ! body="$(proof_body "${target}")" || [[ -z "${body}" ]]; then
    echo "FAIL: ${TARGET_REL} must define _proofOf(KindPresence …) exactly once" >&2
    return 1
  fi
  local flat
  flat="$(flatten <<<"${body}")"
  if grep -qE '(^|[^A-Za-z0-9_.])_ *=>|default *:' <<<"${flat}"; then
    echo "FAIL: _proofOf has a wildcard or default arm, so a new KindPresence value would compile without a proof" >&2
    fail=1
  fi
  arms="$(grep -oE 'KindPresence\.[a-zA-Z][a-zA-Z0-9]* *=>' <<<"${flat}" | sed -e 's/^KindPresence\.//' -e 's/ *=>$//' | LC_ALL=C sort || true)"
  values="$(enum_values "${enum_file}")"
  if [[ -z "${values}" ]]; then
    echo "FAIL: no KindPresence values read from ${ENUM_REL}" >&2
    return 1
  fi
  if [[ "${arms}" != "${values}" ]]; then
    echo "FAIL: _proofOf arms ($(paste -sd, <<<"${arms}")) are not one per KindPresence value ($(paste -sd, <<<"${values}"))" >&2
    fail=1
  fi
  local arm_count proof_count
  arm_count="$(grep -cE '.' <<<"${arms}" || true)"
  proof_count="$(grep -oE "=> *(const +)?(_SeenOnDevice\(\)|_ProvedBy\('[^']+', *'[^']+',? *\))" <<<"${flat}" | grep -c . || true)"
  if (( arm_count != proof_count )); then
    echo "FAIL: ${proof_count} of _proofOf's ${arm_count} arms are _SeenOnDevice() or _ProvedBy('<path>', '<test name>'); every arm must be one of the two" >&2
    fail=1
  fi
  while IFS=$'\t' read -r path name; do
    [[ -n "${path}" ]] || continue
    if [[ ! -f "${root}/${path}" ]]; then
      echo "FAIL: KindPresence proof cites ${path}, which does not exist" >&2
      fail=1
      continue
    fi
    case "${path}" in
      *.rs)
        if [[ ! "${name}" =~ ^[A-Za-z0-9_]+$ ]] || ! defines_rust_test "${root}/${path}" "${name}"; then
          echo "FAIL: ${path} defines no test named '${name}' (a #[test] or #[tokio::test] fn)" >&2
          fail=1
        fi ;;
      *.dart)
        if ! defines_dart_test "${root}/${path}" "${name}"; then
          echo "FAIL: ${path} defines no test named '${name}' (a test( or testWidgets( whose first argument is that literal)" >&2
          fail=1
        fi ;;
      *)
        echo "FAIL: KindPresence proof cites ${path}, which is neither a Rust nor a Dart test file" >&2
        fail=1 ;;
    esac
  done < <(grep -oE "_ProvedBy\('[^']+', *'[^']+'" <<<"${flat}" \
             | sed -E "s/^_ProvedBy\('([^']+)', *'([^']+)'$/\1\t\2/")
  return "${fail}"
}

run_self_test() {
  local tmp fail=0 ran=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  write_fixture() { # <root>
    local r="$1"
    mkdir -p "${r}/haven/lib/src/providers" "${r}/haven/integration_test" \
             "${r}/haven-core/tests" "${r}/haven/test"
    cat > "${r}/${ENUM_REL}" <<'EOF'
/// States.
enum KindPresence {
  /// Never looked.
  notChecked,
  checking,
  current,
}
EOF
    cat > "${r}/haven-core/tests/l1.rs" <<'EOF'
#[tokio::test(flavor = "multi_thread")]
async fn proves_not_checked() {}
// fn mentioned_only_in_a_comment() {}
EOF
    cat > "${r}/haven/test/l2_test.dart" <<'EOF'
void main() {
  testWidgets(
    'renders '
    'checking',
    (tester) async {},
  );
  // test('only in a comment', () {});
}
EOF
    cat > "${r}/${TARGET_REL}" <<'EOF'
_Proof _proofOf(KindPresence state) => switch (state) {
  // A comment inside the switch is not an arm.
  KindPresence.notChecked => const _ProvedBy(
    'haven-core/tests/l1.rs',
    'proves_not_checked',
  ),
  KindPresence.checking => const _ProvedBy(
    'haven/test/l2_test.dart',
    'renders che'
        'cking',
  ),
  KindPresence.current => const _SeenOnDevice(),
};
EOF
  }
  # <name>|<sed expression on the target, or empty>|<file to edit>|<want rc>
  local case_line name expr file want got r
  while IFS='|' read -r name expr file want; do
    ran=$(( ran + 1 ))
    r="${tmp}/${ran}"
    write_fixture "${r}"
    if [[ -n "${expr}" ]]; then sed -i -e "${expr}" "${r}/${file}"; fi
    got=0
    check_root "${r}" >/dev/null 2>&1 || got=$?
    if (( got != want )); then
      echo "SELF-TEST FAIL (${name}): rc ${got}, want ${want}" >&2
      fail=1
    fi
  done <<EOF
every state proved|||0
a cited Rust test that does not exist|s/proves_not_checked/proves_nothing/|haven-core/tests/l1.rs|1
a Rust name only in a comment|s/'proves_not_checked'/'mentioned_only_in_a_comment'/|${TARGET_REL}|1
a Dart name only in a comment|s/'renders che'/'only in a comment'/; s/'cking',/'',/|${TARGET_REL}|1
a cited file that does not exist|s@haven/test/l2_test.dart@haven/test/gone_test.dart@|${TARGET_REL}|1
a wildcard arm|s/KindPresence.current => const _SeenOnDevice(),/_ => const _SeenOnDevice(),/|${TARGET_REL}|1
a value with no arm|s/  current,/  current,\\n  refused,/|${ENUM_REL}|1
an arm that is neither proof|s/const _SeenOnDevice()/null/|${TARGET_REL}|1
a duplicated arm|s/KindPresence.notChecked =>/KindPresence.checking =>/|${TARGET_REL}|1
no _proofOf at all|s/_proofOf(KindPresence/_other(KindPresence/|${TARGET_REL}|1
EOF
  ran=$(( ran + 1 ))
  r="${tmp}/absent"
  write_fixture "${r}"
  rm -f "${r}/${ENUM_REL}"
  got=0
  check_root "${r}" >/dev/null 2>&1 || got=$?
  if (( got != 2 )); then
    echo "SELF-TEST FAIL (an absent enum file): rc ${got}, want 2" >&2
    fail=1
  fi
  if (( fail )); then
    echo "check_relay_status_states_covered.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "check_relay_status_states_covered.sh: self-test passed (${ran} fixtures: every state proved passes; a cited test that is absent, named only in a comment, or in an absent file fails; a wildcard arm, a value with no arm, a duplicated arm, an arm that is neither proof and a missing _proofOf fail; an absent enum file is rc 2)."
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc=0
check_root "${REPO_ROOT}" || rc=$?
if (( rc == 0 )); then
  echo "[check_relay_status_states_covered] OK: every KindPresence value is seen on the device or proved by a test that exists."
fi
exit "${rc}"
