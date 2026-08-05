#!/usr/bin/env bash
# Aggregate line-coverage gate over an lcov report.
#
# ## Why this replaced a third-party action
#
# The Flutter aggregate was enforced by `VeryGoodOpenSource/very_good_coverage@v3`
# in CI and by a hand-written awk sum in scripts/ci/check_coverage.sh locally.
# Two implementations again, and this pair had a shelf life: the action still
# targets Node.js 20, deprecated since June 2026 and already being force-run on
# Node 24 by the runner, with no upstream release. The workflow carried a NOTE
# saying "replace before GitHub forces Node 24" — which is a plan that only
# works if someone reads it in time.
#
# The computation is four lines of awk over LH/LF, which is precisely what the
# action does. Sharing it removes the deprecated dependency, removes the
# divergence, and lets a developer see the same number the workflow will print.
#
# ## Usage
#
#   check_lcov_aggregate.sh <lcov-file> <min-percent> [<label>]
#   check_lcov_aggregate.sh --self-test
#
# Exit codes:
#   0  coverage >= min
#   1  coverage < min
#   2  misconfiguration (missing/unparsable report, no instrumented lines)

set -euo pipefail

SCRIPT_NAME="check_lcov_aggregate"

misconfig() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# LH/LF summed over every record the report contains. The report handed in is
# expected to be already filtered (scripts/ci/filter_lcov.sh) — this gate takes
# no view on which files count, so there is exactly one place that decides.
aggregate() { # <lcov> -> "pct<TAB>hit<TAB>found"
  awk '
    /^LF:/ { lf += substr($0, 4) }
    /^LH:/ { lh += substr($0, 4) }
    END {
      # 0 instrumented lines is not 0% and it is certainly not 100%: it means
      # the report never described anything. Reporting either number would be a
      # gate voting on data it does not have.
      if (lf + 0 == 0) exit 3
      printf "%.2f\t%d\t%d", (lh / lf) * 100, lh + 0, lf + 0
    }
  ' "$1"
}

run_check() { # <lcov> <min> [label]
  local lcov="$1" min="$2" label="${3:-coverage}"
  [ -f "${lcov}" ] || misconfig "report not found: ${lcov}"
  case "${min}" in
    ''|*[!0-9.]*) misconfig "minimum must be numeric, got '${min}'" ;;
  esac

  local out pct hit found
  out="$(aggregate "${lcov}")" \
    || misconfig "no instrumented lines in ${lcov} — the report is empty or not lcov"
  IFS=$'\t' read -r pct hit found <<<"${out}"

  if awk -v p="${pct}" -v m="${min}" 'BEGIN { exit (p + 0 >= m + 0) ? 0 : 1 }'; then
    printf '✅ %s line coverage %s%% (%s/%s) meets threshold %s%%\n' "${label}" "${pct}" "${hit}" "${found}" "${min}"
    return 0
  fi
  printf '❌ %s line coverage %s%% (%s/%s) is BELOW threshold %s%%\n' "${label}" "${pct}" "${hit}" "${found}" "${min}" >&2
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::error::%s line coverage %s%% is below the %s%% threshold\n' "${label}" "${pct}" "${min}"
  fi
  return 1
}

self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  printf 'SF:a.dart\nLF:100\nLH:60\nend_of_record\nSF:b.dart\nLF:100\nLH:40\nend_of_record\n' >"${tmp}/half.lcov"

  _case() { # <label> <expect-rc> <lcov> <min>
    local label="$1" want="$2" got=0
    ( run_check "$3" "$4" selftest ) >/dev/null 2>&1 || got=$?
    if [ "${got}" -eq "${want}" ]; then
      printf '  PASS %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  FAIL %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  printf 'self-test: lcov aggregate\n'
  # Records must SUM, not be read one at a time: 60/100 and 40/100 is 50%, and a
  # reader that took the first record would see 60% and pass a 55 threshold.
  _case "sums every record (50%, not 60%)" 1 "${tmp}/half.lcov" 55
  _case "above threshold passes"           0 "${tmp}/half.lcov" 50
  _case "exactly at threshold passes"      0 "${tmp}/half.lcov" 50
  _case "below threshold fails"            1 "${tmp}/half.lcov" 50.01
  _case "absent report is misconfig"       2 "${tmp}/nope.lcov" 50

  # A report with no instrumented lines must not read as 0% (a fail that looks
  # like a real measurement) or 100% (a pass). It has no measurement at all.
  printf 'SF:a.dart\nLF:0\nLH:0\nend_of_record\n' >"${tmp}/empty.lcov"
  _case "zero instrumented lines is misconfig" 2 "${tmp}/empty.lcov" 50
  printf 'nothing here\n' >"${tmp}/garbage.lcov"
  _case "unparsable report is misconfig"       2 "${tmp}/garbage.lcov" 50
  _case "non-numeric threshold is misconfig"   2 "${tmp}/half.lcov" fifty

  printf '\n'
  [ "${fails}" -eq 0 ] || { printf 'self-test failed — the aggregate gate cannot be trusted.\n' >&2; exit 1; }
  printf 'OK: self-test passed (8 fixtures).\n'
}

main() {
  case "${1:---help}" in
    --self-test) self_test ;;
    -h|--help)   sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' ;;
    *)
      [ "$#" -ge 2 ] || misconfig "usage: ${SCRIPT_NAME}.sh <lcov-file> <min-percent> [label] | --self-test"
      run_check "$1" "$2" "${3:-coverage}"
      ;;
  esac
}

main "$@"
