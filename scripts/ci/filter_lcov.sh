#!/usr/bin/env bash
# The Flutter coverage report's exclusion filter — ONE implementation, used by
# both .github/workflows/coverage.yml and scripts/ci/check_coverage.sh.
#
# ## Why this is its own script
#
# There used to be two filters. CI ran `lcov --remove` with five glob patterns;
# the local gate re-implemented the same five in awk because `lcov` is not
# installed on a typical dev machine (it is not on the maintainer's). Two
# implementations of "which files count" is two answers to the question the
# 50% gate and every per-path floor are computed FROM — and nothing compared
# them. The awk version's `/\/test\//` could not match a record emitted as
# `test/foo.dart` (no leading slash), where lcov's `**/test/**` does; that
# divergence was invisible only because `flutter test --coverage` happens not
# to emit test files today. "Happens not to" is not an invariant.
#
# So the filter lives here, both callers invoke it, and the equivalence is by
# construction rather than by comment. It also drops `lcov` from the coverage
# job's critical path — the workflow now installs it only for the HTML report,
# after the gates have already voted.
#
# ## What is excluded, and why each one
#
#   test/**                 Test code is not the thing under test.
#   lib/src/rust/**         flutter_rust_bridge output. Generated, not written;
#                           CLAUDE.md marks it DO NOT EDIT.
#   *.g.dart                build_runner output.
#   *.freezed.dart          freezed output.
#   l10n/app_localizations* gen-l10n output — 13 locales of generated getters
#                           would otherwise dominate the package aggregate.
#
# Every pattern matches a path SEGMENT, anchored so it works on both the
# package-relative records Flutter emits today (`lib/src/...`) and any
# absolute-path producer a future SDK might switch to.
#
# ## Usage
#
#   filter_lcov.sh <input.lcov> <output.lcov>
#   filter_lcov.sh --self-test
#
# Exit codes:
#   0  wrote a non-empty filtered report
#   2  misconfiguration (missing input, unparsable report, everything filtered)

set -euo pipefail

SCRIPT_NAME="filter_lcov"

misconfig() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# One record = SF: … end_of_record. A record is dropped whole; dropping only the
# SF line would leave its LF/LH counters attributed to the PREVIOUS file, which
# is worse than not filtering at all.
filter() { # <in> <out>
  awk '
    function excluded(p) {
      return (p ~ /(^|\/)test\//)                         \
          || (p ~ /(^|\/)lib\/src\/rust\//)               \
          || (p ~ /\.g\.dart$/)                           \
          || (p ~ /\.freezed\.dart$/)                     \
          || (p ~ /(^|\/)l10n\/app_localizations[^\/]*\.dart$/)
    }
    /^SF:/ {
      sf = substr($0, 4); sub(/\r$/, "", sf); sub(/^\.\//, "", sf)
      seen++
      drop = excluded(sf)
      if (drop) dropped++
      buf = $0 "\n"
      next
    }
    {
      buf = buf $0 "\n"
      if ($0 ~ /^end_of_record/) {
        if (!drop) { printf "%s", buf; kept++ }
        buf = ""; drop = 0
      }
      next
    }
    END {
      # Reported on stderr so stdout stays a clean lcov stream.
      printf "filter_lcov: %d source records, %d excluded, %d kept\n",
             seen + 0, dropped + 0, kept + 0 > "/dev/stderr"
      # A filter that parsed nothing, or that swallowed everything, must not
      # look like a clean pass: the aggregate gate downstream would read the
      # empty file as either 0% or (worse, with some readers) a vacuous 100%.
      if (seen + 0 == 0) { print "filter_lcov: parsed 0 SF records" > "/dev/stderr"; exit 3 }
      if (kept + 0 == 0) { print "filter_lcov: every record was excluded" > "/dev/stderr"; exit 3 }
    }
  ' "$1" >"$2" || { rm -f "$2"; misconfig "could not produce a filtered report from $1"; }
}

self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  cat >"${tmp}/in.lcov" <<'EOF'
SF:lib/src/services/nostr_relay_service.dart
DA:1,1
LF:10
LH:5
end_of_record
SF:lib/src/rust/api.dart
LF:400
LH:0
end_of_record
SF:test/services/relay_test.dart
LF:50
LH:50
end_of_record
SF:/abs/path/haven/test/widget_test.dart
LF:7
LH:7
end_of_record
SF:lib/src/models/circle.g.dart
LF:99
LH:1
end_of_record
SF:lib/src/models/circle.freezed.dart
LF:88
LH:2
end_of_record
SF:lib/l10n/app_localizations_tr.dart
LF:300
LH:0
end_of_record
SF:lib/l10n/app_localizations.dart
LF:120
LH:0
end_of_record
SF:lib/src/utils/npub_validator.dart
LF:20
LH:15
end_of_record
EOF

  filter "${tmp}/in.lcov" "${tmp}/out.lcov" 2>/dev/null

  _want() { # <label> <expect-present:0|1> <path>
    local label="$1" want="$2" path="$3" got=0
    grep -qF "SF:${path}" "${tmp}/out.lcov" && got=1
    if [ "${got}" = "${want}" ]; then
      printf '  PASS %s\n' "${label}"
    else
      printf '  FAIL %s (present=%s, wanted %s)\n' "${label}" "${got}" "${want}" >&2
      fails=1
    fi
  }

  printf 'self-test: lcov filter\n'
  _want "production lib file kept"            1 "lib/src/services/nostr_relay_service.dart"
  _want "second production file kept"         1 "lib/src/utils/npub_validator.dart"
  _want "generated FFI bindings excluded"     0 "lib/src/rust/api.dart"
  # The one the two old implementations disagreed on: a package-relative test
  # record has no leading slash, so a `/test/` pattern misses it.
  _want "relative test/ record excluded"      0 "test/services/relay_test.dart"
  _want "absolute test/ record excluded"      0 "/abs/path/haven/test/widget_test.dart"
  _want "*.g.dart excluded"                   0 "lib/src/models/circle.g.dart"
  _want "*.freezed.dart excluded"             0 "lib/src/models/circle.freezed.dart"
  _want "generated localizations excluded"    0 "lib/l10n/app_localizations_tr.dart"
  _want "localization base file excluded"     0 "lib/l10n/app_localizations.dart"

  # Counters must follow the record they belong to, not leak onto a neighbour.
  local lf
  lf="$(awk '/^LF:/ { s += substr($0, 4) } END { print s + 0 }' "${tmp}/out.lcov")"
  if [ "${lf}" = "30" ]; then
    printf '  PASS kept records carry exactly their own LF (30)\n'
  else
    printf '  FAIL kept LF total is %s, expected 30\n' "${lf}" >&2
    fails=1
  fi

  # An empty or non-lcov input must be reported as a broken filter, never as a
  # clean pass — the downstream aggregate cannot tell 0 records from 0%.
  local rc=0
  printf 'not an lcov file\n' >"${tmp}/garbage.lcov"
  ( filter "${tmp}/garbage.lcov" "${tmp}/garbage.out" ) >/dev/null 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf '  PASS unparsable input is a misconfiguration (rc=%d)\n' "${rc}"
  else
    printf '  FAIL unparsable input exited 0\n' >&2
    fails=1
  fi

  rc=0
  printf 'SF:lib/src/rust/api.dart\nLF:1\nLH:0\nend_of_record\n' >"${tmp}/allexcluded.lcov"
  ( filter "${tmp}/allexcluded.lcov" "${tmp}/allexcluded.out" ) >/dev/null 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf '  PASS filtering everything away is a misconfiguration (rc=%d)\n' "${rc}"
  else
    printf '  FAIL a fully-excluded report exited 0\n' >&2
    fails=1
  fi

  printf '\n'
  [ "${fails}" -eq 0 ] || { printf 'self-test failed — the coverage filter cannot be trusted.\n' >&2; exit 1; }
  printf 'OK: self-test passed (12 fixtures).\n'
}

main() {
  case "${1:---help}" in
    --self-test) self_test ;;
    -h|--help)   sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' ;;
    *)
      [ "$#" -eq 2 ] || misconfig "usage: ${SCRIPT_NAME}.sh <input.lcov> <output.lcov> | --self-test"
      [ -f "$1" ] || misconfig "input report not found: $1"
      filter "$1" "$2"
      ;;
  esac
}

main "$@"
