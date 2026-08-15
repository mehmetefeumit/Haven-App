#!/usr/bin/env bash
# CI guard: per-path coverage FLOORS, with a ratchet.
#
# ## Why this exists
#
# Coverage is gated by exactly two numbers — 80% for haven-core, 50% for haven
# — and both are AGGREGATES over an entire crate/package. An aggregate is a
# BUDGET: every line above the threshold is slack that any other file is free
# to spend. Measured on the real reports this manifest was pinned from:
#
#     haven-core   90.74%  (19419/21400)  ->  ~2290 lines of slack
#     haven        64.82%  ( 6944/10712)  ->  ~1588 lines of slack
#
# 2290 lines is larger than any single file in haven-core. src/nostr/mls/
# manager.rs (755 instrumented lines), src/nostr/giftwrap.rs (208), all of
# src/nostr/encryption/ (126) — every one of those could drop to ZERO coverage,
# simultaneously, and the 80% gate would still print a green check.
#
# On the Flutter side it is not hypothetical. The same reports showed:
#
#     lib/src/services/nostr_relay_preferences_service.dart    0.00%  (0/88)
#     lib/src/services/nostr_relay_service.dart                0.63%  (1/158)
#     lib/src/services/background_location_task.dart           1.69%  (4/236)
#     lib/src/services/nostr_circle_service.dart              11.63%  (60/516)
#     lib/src/services/       (the whole service layer)       48.96%  (1317/2690)
#
# The service layer — every relay connection, every MLS call, the background
# publisher — sits BELOW the 50% package gate, and the package is green anyway
# because the widget and provider suites pay its bill out of the shared budget.
# `background_location_task.dart` at 1.69% is the file P0-1 lives in.
#
# So this guard adds the thing an aggregate cannot express: a MINIMUM PER PATH,
# written down, reviewed as a diff, and enforced against the same real lcov the
# aggregate gate reads. It does not replace the aggregate — coverage.yml keeps
# both thresholds exactly as they were. It is strictly additive.
#
# ## The ratchet, and why the margin is 5 points
#
# A floor nobody raises is just a floor. Coverage climbs, the declared number
# stays put, and within a few releases every entry is vacuous: it permits a
# regression back to a level the code left long ago, so it protects nothing
# while still LOOKING like protection. That is this repo's recurring failure
# mode (CI_HARDENING_BACKLOG.md), not a hypothetical.
#
# Therefore exceeding a floor by more than the margin is ALSO a failure, and
# the message carries the number to write down.
#
# 5 percentage points, chosen against this repo's actual distribution:
#
#   * Floors are pinned at `floor(measured) - 2`, so a fresh pin sits ~2 points
#     under its path and has ~3 points of room before the ratchet speaks. Real
#     churn does not move a pinned path 3 points by accident: the median pinned
#     path here carries 200+ instrumented lines, where 3 points is 6+ lines.
#   * Below ~3 the guard would demand a manifest edit on routine PRs and would
#     be commented out inside a month. A guard people route around is worse
#     than no guard, because it still reads as coverage in the workflow list.
#   * Above ~10 it stops ratcheting at the paths that most need it:
#     src/relay/catchup.rs could climb 28% -> 38% and still license a fall back
#     to 26%.
#   * Small paths need MORE room per line, not less (one line of a 20-line file
#     is 5 whole points), so an entry may override the margin in a 4th column.
#     Overriding is a declaration, visible in review, not a hidden exception.
#   * 100% is the one value the margin rule cannot police — there is no 103% to
#     reach — so a fully covered path is pinned EXACTLY at 100 and ratchets the
#     moment its floor is anything less. Otherwise src/nostr/tags.rs (the kind-
#     445 tag allowlist) and src/nostr/mls/welcome.rs (Security Rule 3: kind 444
#     stays unsigned), both at 100% today, would sit behind a 98 floor forever.
#
# ## Why a stale entry is a hard failure
#
# An entry matching no file passes vacuously — it measures nothing, so it can
# never be below its floor. That is the exact false green the expected-skip
# manifest was built to stop (`check_no_undeclared_skips.sh`, rule 2): a
# declaration that outlives the thing it declares is indistinguishable from a
# deleted proof. Rename `nostr_relay_service.dart` and, without this rule, its
# floor would sit in the manifest forever, green, guarding nothing. So: every
# manifest entry MUST match at least one file carrying at least one
# instrumented line, or the run fails.
#
# The same reasoning applies one level up, which is why a report that parses to
# zero files, or a stack with zero manifest entries, exits 2 (misconfigured)
# rather than 0. A guard whose input silently became empty must not report
# success — it has to say it is broken.
#
# ## Note on Dart files absent from the report
#
# `flutter test --coverage` only emits records for libraries some test actually
# imported. A lib/ file no test ever touches is not "0%" in lcov — it is ABSENT,
# invisible to the aggregate gate in both directions. Under this guard such a
# path is a stale entry and fails loudly, which is the intended reading: a file
# no test imports is exactly the case the aggregate cannot see.
#
# ## The pin rule, and the lint that enforces it
#
# Every floor is `floor(measured) - 2`, or exactly 100 for a fully covered path.
# That rule is what makes the two-sided band work: two points of headroom below
# (run-to-run wobble, a few new lines landing in a pinned path) and three above
# before the ratchet asks for a re-pin.
#
# It only works if the rule is actually APPLIED. It was not. Three rows had been
# hand-tightened over time — `lib/src/services/` pinned at 51 against a measured
# 51.06%, `src/relay/catchup.rs` at 97 against 97.14%, and
# `geolocator_location_service.dart` at 86 against 86.72% — leaving 0.06, 0.14
# and 0.72 points of headroom on rows the rule would have pinned at 49, 95 and
# 84. Those are not floors; they are tripwires. The first of them reddened CI
# (run 30964250098) when unrelated work moved the services aggregate by
# 0.07 points, and the other two were one line of new code away from the same.
#
# So the manifest is now checked against its own rule, statically:
#
#   check_coverage_floors.sh --lint          # no report, no toolchain, ~50 ms
#
# Every row must carry its `# measured N%` provenance, and its floor must be
# no HIGHER than the rule produces from that number. (Lower is allowed — the
# ratchet already governs floors that are too low.) The lint needs no coverage
# run, so it goes in repo-guards.yml and in the pre-commit hook, and a
# hand-edited floor fails in under a second on the machine that wrote it
# instead of an hour into the coverage workflow.
#
# `--repin` is the writer that keeps the manifest rule-shaped, so nobody has to
# compute a pin by hand again. It RAISES floors that coverage has outgrown and
# refreshes their provenance; it never lowers one. A row whose coverage FELL is
# left completely untouched — floor and comment — because re-pinning downward is
# how a measured regression gets laundered into a permitted one, and because
# rewriting the provenance alone would leave the row failing its own lint.
#
# ## Usage
#
#   check_coverage_floors.sh <stack> <lcov-file>   # enforce (stack: rust|flutter)
#   check_coverage_floors.sh --lint [--fix]        # static: floors obey the pin rule
#   check_coverage_floors.sh --repin <stack> <lcov> # raise earned floors in place
#   check_coverage_floors.sh --list <stack> <lcov> # print measured rows to re-pin
#   check_coverage_floors.sh --self-test           # hermetic fixtures, no toolchain
#
# Produce the inputs with (exactly what coverage.yml runs):
#   cd haven-core && cargo llvm-cov --all-features --lcov \
#       --output-path coverage.lcov --ignore-filename-regex 'frb_generated'
#   cd haven && flutter test --coverage    # then coverage.yml's `lcov --remove`
#
# Paths in the manifest are relative to the STACK ROOT (`haven-core/`, `haven/`);
# the parser normalises absolute and relative SF records to that form, so the
# same manifest works from a workflow, a git hook, or a bare shell.
#
# A pattern ending in `/` is a directory prefix and AGGREGATES every file under
# it (sum of hits / sum of found), which is how `lib/src/services/` can be
# pinned as one number. Anything else is a glob over the normalised path.
#
# Exit codes:
#   0  every pinned path is at or above its floor, and none has outgrown it
#   1  a path fell below its floor, outgrew it, or an entry matched nothing
#   2  misconfiguration (missing/unparsable report, empty manifest, parser rot)

set -euo pipefail

SCRIPT_NAME="check_coverage_floors"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_MANIFEST="${REPO_ROOT}/scripts/ci/coverage_floors.txt"

# Points a path may exceed its floor by before the ratchet demands a re-pin.
# See the header for why 5. Overridable per entry (4th column) and per run
# (env), so a deliberate exception is always written down somewhere reviewable.
DEFAULT_RATCHET_MARGIN="${COVERAGE_RATCHET_MARGIN:-5}"

# Points of headroom a fresh pin leaves under the measured value. Together with
# the margin above this defines the band a row may move in without a manifest
# edit: [measured - 2, measured + 3). Both `--list` and `--repin` write pins at
# this rule, and `--lint` fails any row pinned tighter than it.
PIN_HEADROOM=2

# Below this much headroom a row is one small change away from reddening CI.
# Reported as a NOTICE rather than a failure: the row is still above its floor,
# so failing here would punish a legal state, but staying silent is how
# `src/location/nostr.rs` reached exactly 50.00% against a floor of 50 with
# nothing anywhere saying so. The notice earned itself on that row: chasing it
# found the uncovered half had no caller in the tree at all, and the file was
# deleted (2026-08-14) rather than tested. A floor that will not move is a
# reachability signal before it is a testing debt.
LOW_HEADROOM_POINTS=1

# The floor a freshly measured percentage pins to. Single definition, used by
# --list, --repin and --lint so the three can never disagree about the rule.
# 100 is pinned exactly: the margin rule cannot ratchet a fully covered path
# (there is no 103% to reach), so anything less would under-declare it forever.
pin_for() { # <pct>
  awk -v p="$1" -v hr="${PIN_HEADROOM}" 'BEGIN {
    if (p + 0 >= 100) { print 100; exit }
    v = int(p) - hr; if (v < 0) v = 0; printf "%d", v
  }'
}

# Resolved per invocation, NOT once at load: --self-test points
# HAVEN_COVERAGE_FLOORS at each fixture in turn, and binding it at load time
# would silently reconcile every fixture against the REAL manifest — a
# self-test that proves the guard works on data it never saw.
manifest_path() { printf '%s\n' "${HAVEN_COVERAGE_FLOORS:-${DEFAULT_MANIFEST}}"; }

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; RESET=''
fi

log()       { printf '%s\n' "$*"; }
fail()      { printf '%s%s%s\n' "${RED}" "$*" "${RESET}" >&2; exit 1; }
misconfig() { printf '%s%s: %s%s\n' "${RED}" "${SCRIPT_NAME}" "$*" "${RESET}" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Measurement.
#
# Emits one `path<TAB>hit<TAB>found` row per source file in the report, with the
# path normalised to stack-root-relative. Records are SUMMED per path rather
# than overwritten: some producers emit a file more than once (a Rust source
# compiled into several test binaries), and taking the last record would silently
# report one binary's view of a shared file as the whole truth.
#
# LF/LH are used rather than counting DA lines because they are what both
# producers (cargo-llvm-cov, package:coverage) and the existing aggregate gates
# already agree on — this guard must measure the SAME metric the 80%/50% gates
# do, or the two can disagree about the same file.
# ---------------------------------------------------------------------------
measure() { # <lcov-file>
  local lcov="$1"
  awk '
    /^SF:/ {
      sf = substr($0, 4)
      sub(/\r$/, "", sf)
      sub(/^\.\//, "", sf)
      # Absolute or nested records are cut back to the stack root. BOTH anchors
      # are tried regardless of which stack is being checked: the two can never
      # both match (a haven-core path has no `/haven/` SEGMENT — `haven-core/`
      # is not `haven/` — and a haven path has no `haven-core/`), and keying the
      # rule on the stack name instead meant fixtures under the selftest stack
      # were normalised by a different branch than production input. That is
      # exactly the seam where a guard passes its fixtures and then mis-reads a
      # real report.
      # A relative record (the common case: cargo emits src/..., flutter emits
      # lib/...) matches neither and is left as-is.
      sub(/^.*haven-core\//, "", sf)
      sub(/^.*\/haven\//,    "", sf)
      cur = sf
      seen[cur] = 1
      next
    }
    /^LF:/ { if (cur != "") lf[cur] += substr($0, 4); next }
    /^LH:/ { if (cur != "") lh[cur] += substr($0, 4); next }
    /^end_of_record/ { cur = ""; next }
    END {
      for (f in seen) printf "%s\t%d\t%d\n", f, lh[f] + 0, lf[f] + 0
    }
  ' "${lcov}"
}

# Read the manifest rows for one stack into the global MAN_* arrays.
# Parsing is strict: a malformed row is a misconfiguration, never a skipped
# line, because a typo'd row that is quietly ignored is a floor that silently
# stopped being enforced.
read_manifest() { # <stack>
  local stack="$1" manifest lineno=0 line
  manifest="$(manifest_path)"
  [ -f "${manifest}" ] || misconfig "manifest not found: ${manifest}"

  MAN_PATTERN=(); MAN_FLOOR=(); MAN_MARGIN=(); MAN_LINE=()
  while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    [ -n "${line}" ] || continue
    case "${line}" in \#*) continue ;; esac

    # Strip a TRAILING comment (whitespace + '#') and any padding before it.
    # Every row carries `# measured N% (hit/found)` as its provenance: the
    # number a floor was pinned from is the only way a reviewer can tell a
    # ratchet-driven raise from someone quietly relaxing a floor. Requiring
    # whitespace before the '#' keeps a '#' inside a path from being eaten.
    line="${line%%[[:space:]]#*}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "${line}" ] || continue

    local f_stack f_pattern f_floor f_margin rest
    IFS='|' read -r f_stack f_pattern f_floor f_margin rest <<<"${line}"
    [ -z "${rest:-}" ] \
      || misconfig "${manifest}:${lineno}: too many fields (expected 3 or 4): ${line}"
    [ -n "${f_stack:-}" ] && [ -n "${f_pattern:-}" ] && [ -n "${f_floor:-}" ] \
      || misconfig "${manifest}:${lineno}: expected <stack>|<path>|<floor>[|<margin>]: ${line}"
    case "${f_stack}" in
      rust|flutter|selftest) ;;
      *) misconfig "${manifest}:${lineno}: unknown stack '${f_stack}'" ;;
    esac
    case "${f_floor}" in
      ''|*[!0-9]*) misconfig "${manifest}:${lineno}: floor must be a whole percent: ${f_floor}" ;;
    esac
    [ "${f_floor}" -le 100 ] || misconfig "${manifest}:${lineno}: floor above 100: ${f_floor}"
    if [ -n "${f_margin:-}" ]; then
      case "${f_margin}" in
        ''|*[!0-9]*) misconfig "${manifest}:${lineno}: margin must be a whole percent: ${f_margin}" ;;
      esac
    else
      f_margin="${DEFAULT_RATCHET_MARGIN}"
    fi

    [ "${f_stack}" = "${stack}" ] || continue
    MAN_PATTERN+=("${f_pattern}")
    MAN_FLOOR+=("${f_floor}")
    MAN_MARGIN+=("${f_margin}")
    MAN_LINE+=("${lineno}")
  done <"${manifest}"

  # A stack with no rows would sail through every check below and print a
  # cheerful "0 violations". Same class of false green as a stale entry, one
  # level up — so it is a misconfiguration, not a pass.
  [ "${#MAN_PATTERN[@]}" -gt 0 ] \
    || misconfig "manifest ${manifest} declares no floors for stack '${stack}' — nothing would be enforced"
}

# ---------------------------------------------------------------------------
# The check.
#
# Every violation is collected and reported together: a run that stopped at the
# first bad path would hide the other four behind it and turn one fix into five
# round trips, which is the same reason repo-guards.yml runs every guard step
# even after one fails.
# ---------------------------------------------------------------------------
run_check() { # <stack> <lcov-file>
  local stack="$1" lcov="$2"
  case "${stack}" in
    rust|flutter|selftest) ;;
    *) misconfig "unknown stack '${stack}' (expected: rust | flutter)" ;;
  esac
  [ -f "${lcov}" ] || misconfig "coverage report not found: ${lcov}"

  local -a paths=() hits=() founds=()
  local p h f
  while IFS=$'\t' read -r p h f; do
    [ -n "${p}" ] || continue
    paths+=("${p}"); hits+=("${h}"); founds+=("${f}")
  done < <(measure "${lcov}")

  # Parser rot, self-diagnosed. If the extractor ever stops matching SF records
  # (a producer changes format, the file is truncated, the wrong artifact is
  # downloaded) then EVERY entry below would report "matched nothing" — which is
  # a real failure mode with a misleading message. Say the true thing instead.
  [ "${#paths[@]}" -gt 0 ] \
    || misconfig "parsed 0 source records from ${lcov} — the report is empty or not lcov"

  read_manifest "${stack}"

  local -a violations=() notices=()
  local i j pattern floor margin agg_h agg_f matched pct verdict
  log "${BOLD}Per-path coverage floors — stack '${stack}' (${#MAN_PATTERN[@]} pinned paths)${RESET}"
  log ""
  printf '  %-7s %-9s %-56s %s\n' 'ACTUAL' 'FLOOR' 'PATH' 'LINES'

  for ((i = 0; i < ${#MAN_PATTERN[@]}; i++)); do
    pattern="${MAN_PATTERN[$i]}"
    floor="${MAN_FLOOR[$i]}"
    margin="${MAN_MARGIN[$i]}"
    agg_h=0; agg_f=0; matched=0

    # A trailing slash means "directory": aggregate every file beneath it, so a
    # whole layer can be pinned as one number instead of file by file. Bash glob
    # `*` spans `/`, which is what makes the prefix form work at any depth.
    local glob="${pattern}"
    case "${glob}" in */) glob="${glob}*" ;; esac

    for ((j = 0; j < ${#paths[@]}; j++)); do
      # Intentionally unquoted: this is glob matching, not string equality.
      # shellcheck disable=SC2053
      if [[ "${paths[$j]}" == ${glob} ]]; then
        matched=$((matched + 1))
        agg_h=$((agg_h + hits[j]))
        agg_f=$((agg_f + founds[j]))
      fi
    done

    if [ "${matched}" -eq 0 ]; then
      printf '  %-7s %-9s %-56s %s\n' '  --' "${floor}%" "${pattern}" 'NO MATCH'
      violations+=("$(printf 'STALE   %s\n          matches no file in the report (manifest line %s).\n          Either the path moved — update the entry — or nothing imports it any\n          more, in which case its coverage is unmeasurable, not zero, and the\n          floor is guarding nothing.' "${pattern}" "${MAN_LINE[$i]}")")
      continue
    fi
    if [ "${agg_f}" -eq 0 ]; then
      printf '  %-7s %-9s %-56s %s\n' '  --' "${floor}%" "${pattern}" '0 lines'
      violations+=("$(printf 'STALE   %s\n          matched %s file(s) but 0 instrumented lines (manifest line %s), so its\n          floor can never fail. Pin a path that carries executable code.' "${pattern}" "${matched}" "${MAN_LINE[$i]}")")
      continue
    fi

    pct="$(awk -v h="${agg_h}" -v f="${agg_f}" 'BEGIN { printf "%.2f", (h / f) * 100 }')"

    # awk, not bash arithmetic: percentages are fractional and `[ ]` is integer
    # only. Truncating to compare would let 79.99% pass an 80 floor.
    #
    # The 100% clause closes the one place the margin rule goes vacuous. A fully
    # covered path pinned below 100 can never reach floor+margin (there is no
    # 103%), so its floor would sit under the real value FOREVER, permanently
    # licensing a regression the ratchet is structurally unable to notice —
    # precisely the "a ratchet nobody tightens is just a floor" failure, only
    # arithmetic rather than social. Full coverage is a terminal state and must
    # be pinned exactly.
    verdict="$(awk -v p="${pct}" -v fl="${floor}" -v m="${margin}" 'BEGIN {
      if (p + 0 <  fl + 0)                 { print "below"; exit }
      if (p + 0 >= 100 && fl + 0 < 100)    { print "ratchet"; exit }
      if (p + 0 >= fl + m + 0)             { print "ratchet"; exit }
      print "ok"
    }')"

    case "${verdict}" in
      below)
        printf '  %s%-7s%s %-9s %-56s %s\n' "${RED}" "${pct}" "${RESET}" "${floor}%" "${pattern}" "${agg_h}/${agg_f}"
        violations+=("$(printf 'BELOW   %s\n          %s%% < floor %s%% (%s/%s lines, manifest line %s).\n          Add tests for the uncovered lines. Lowering the floor is not a fix —\n          it converts a measured regression into a permitted one.' "${pattern}" "${pct}" "${floor}" "${agg_h}" "${agg_f}" "${MAN_LINE[$i]}")")
        ;;
      ratchet)
        # Pin at the integer part of the measured value: it is the highest floor
        # provably satisfied right now, and it cannot round a path up into an
        # instant failure the way ceil() would.
        local suggested
        suggested="$(awk -v p="${pct}" 'BEGIN { printf "%d", int(p) }')"
        printf '  %s%-7s%s %-9s %-56s %s\n' "${YELLOW}" "${pct}" "${RESET}" "${floor}%" "${pattern}" "${agg_h}/${agg_f}"
        violations+=("$(printf 'RATCHET %s\n          %s%% now exceeds floor %s%% by >= %s points (manifest line %s).\n          Raise the floor to %s in scripts/ci/coverage_floors.txt.\n          The coverage is already earned; leaving the floor low licenses a\n          silent fall back to %s%%.' "${pattern}" "${pct}" "${floor}" "${margin}" "${MAN_LINE[$i]}" "${suggested}" "${floor}")")
        ;;
      *)
        printf '  %s%-7s%s %-9s %-56s %s\n' "${GREEN}" "${pct}" "${RESET}" "${floor}%" "${pattern}" "${agg_h}/${agg_f}"
        # A row that is above its floor but has all but consumed the two points
        # of headroom the pin rule gave it. Not a failure — it is legal, and
        # failing here would redden a build for a state the band exists to
        # permit — but it is the LAST run before the next small change turns it
        # into a BELOW, so it must not pass in silence.
        #
        # Floors of 0 and 100 are excluded, and not as a convenience: both are
        # TERMINAL pins where the rule gives no headroom by construction — a
        # fully covered path is pinned exactly (there is no 103% for the ratchet
        # to reach) and the pin clamps at 0 below ~2%. Warning there would fire
        # forever on rows in their intended state, which is how a notice gets
        # tuned out and stops being read on the rows that mean something.
        if [ "${floor}" -gt 0 ] && [ "${floor}" -lt 100 ] \
           && awk -v p="${pct}" -v fl="${floor}" -v lim="${LOW_HEADROOM_POINTS}" \
                'BEGIN { exit (p + 0 - fl + 0 < lim + 0) ? 0 : 1 }'; then
          notices+=("$(printf '%s\n          %s%% is within %s point of floor %s%% (%s/%s lines, manifest line %s).\n          The band has been spent: the next uncovered lines to land here turn\n          this into a build failure. Add tests now, while it is a notice.' \
            "${pattern}" "${pct}" "${LOW_HEADROOM_POINTS}" "${floor}" "${agg_h}" "${agg_f}" "${MAN_LINE[$i]}")")
        fi
        ;;
    esac
  done

  log ""
  if [ "${#notices[@]}" -gt 0 ]; then
    printf '%s%s row(s) with less than %s point of headroom:%s\n' \
      "${YELLOW}" "${#notices[@]}" "${LOW_HEADROOM_POINTS}" "${RESET}"
    for v in "${notices[@]}"; do
      printf '  %s\n\n' "${v}"
      if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::warning file=scripts/ci/coverage_floors.txt::%s has under %s point of coverage headroom\n' \
          "${v%%$'\n'*}" "${LOW_HEADROOM_POINTS}"
      fi
    done
  fi
  if [ "${#violations[@]}" -gt 0 ]; then
    printf '%s%s violation(s):%s\n' "${RED}" "${#violations[@]}" "${RESET}" >&2
    for v in "${violations[@]}"; do printf '  %s\n\n' "${v}" >&2; done
    fail "Per-path coverage floors not satisfied (stack '${stack}')."
  fi
  printf '%sOK: all %s pinned paths are at or above their floor, none has outgrown it.%s\n' \
    "${GREEN}" "${#MAN_PATTERN[@]}" "${RESET}"
}

# `--list` prints the measured value for every pinned path plus a ready-to-paste
# row at the standard `floor(measured) - 2` pin. Re-pinning after a ratchet
# failure is then mechanical rather than a hand-computed guess.
run_list() { # <stack> <lcov-file>
  local stack="$1" lcov="$2"
  [ -f "${lcov}" ] || misconfig "coverage report not found: ${lcov}"
  local -a paths=() hits=() founds=()
  local p h f
  while IFS=$'\t' read -r p h f; do
    [ -n "${p}" ] || continue
    paths+=("${p}"); hits+=("${h}"); founds+=("${f}")
  done < <(measure "${lcov}")
  [ "${#paths[@]}" -gt 0 ] || misconfig "parsed 0 source records from ${lcov}"
  read_manifest "${stack}"

  local i j pattern agg_h agg_f matched pct pin
  for ((i = 0; i < ${#MAN_PATTERN[@]}; i++)); do
    pattern="${MAN_PATTERN[$i]}"; agg_h=0; agg_f=0; matched=0
    local glob="${pattern}"
    case "${glob}" in */) glob="${glob}*" ;; esac
    for ((j = 0; j < ${#paths[@]}; j++)); do
      # shellcheck disable=SC2053
      if [[ "${paths[$j]}" == ${glob} ]]; then
        matched=$((matched + 1)); agg_h=$((agg_h + hits[j])); agg_f=$((agg_f + founds[j]))
      fi
    done
    if [ "${matched}" -eq 0 ] || [ "${agg_f}" -eq 0 ]; then
      printf '# NO MATCH  %s\n' "${pattern}"
      continue
    fi
    pct="$(awk -v h="${agg_h}" -v f="${agg_f}" 'BEGIN { printf "%.2f", (h / f) * 100 }')"
    pin="$(pin_for "${pct}")"
    # Carry any per-entry margin through. Re-pinning must not silently DELETE
    # an override: the rows that carry one are the small paths where a single
    # line is worth several points, and dropping it would make the next honest
    # improvement fail the ratchet for no reason a reader could see.
    local suffix=''
    [ "${MAN_MARGIN[$i]}" = "${DEFAULT_RATCHET_MARGIN}" ] || suffix="|${MAN_MARGIN[$i]}"
    printf '%s|%s|%s%s   # measured %s%% (%s/%s)\n' \
      "${stack}" "${pattern}" "${pin}" "${suffix}" "${pct}" "${agg_h}" "${agg_f}"
  done
}

# ---------------------------------------------------------------------------
# Manifest writing.
#
# Both `--lint --fix` and `--repin` funnel through here so there is exactly one
# piece of code that edits the manifest, and so an edit can never disturb
# anything but the floor field and the `measured N%` token: every comment,
# section header, blank line, ordering choice and margin override survives
# byte-for-byte, and the `#` column is held steady so the diff shows the number
# that changed and nothing else. A rewriter that reformatted the file would
# bury a floor change in whitespace noise, which is the one thing review has to
# be able to see.
#
# Edits arrive as `lineno<TAB>new-floor<TAB>new-measured-text` (empty third
# field = leave the comment alone).
# ---------------------------------------------------------------------------
rewrite_manifest() { # <edits-file>
  local edits="$1" manifest tmp
  manifest="$(manifest_path)"
  tmp="$(mktemp)"
  awk -v edits="${edits}" '
    BEGIN {
      while ((getline line < edits) > 0) {
        n = split(line, a, "\t")
        if (n < 2) continue
        nf[a[1] + 0] = a[2]
        nm[a[1] + 0] = (n >= 3 ? a[3] : "")
      }
      close(edits)
    }
    {
      if (!(FNR in nf)) { print; next }

      # Split the row into its code half and its trailing comment, at the same
      # first whitespace-then-# the parser uses, so writer and reader agree on
      # where the declaration ends.
      idx = match($0, /[ \t]+#/)
      if (idx > 0) { code = substr($0, 1, idx - 1); rest = substr($0, idx) }
      else         { code = $0; rest = "" }
      width = length(code)

      n = split(code, f, "|")
      f[3] = nf[FNR]
      out = f[1] "|" f[2] "|" f[3]
      for (i = 4; i <= n; i++) out = out "|" f[i]

      # Hold the comment column: pad when the new floor is narrower, and eat
      # the same number of leading spaces when it is wider (never the last one,
      # so `#` keeps the whitespace the parser needs in front of it).
      if (length(out) < width) {
        while (length(out) < width) out = out " "
      } else if (length(out) > width && rest != "") {
        drop = length(out) - width
        while (drop-- > 0 && rest ~ /^  /) rest = substr(rest, 2)
      }

      if (nm[FNR] != "") {
        sub(/measured[ \t]+[0-9]+(\.[0-9]+)?%([ \t]*\([0-9]+\/[0-9]+\))?/,
            "measured " nm[FNR], rest)
      }
      print out rest
    }
  ' "${manifest}" >"${tmp}" || { rm -f "${tmp}"; misconfig "could not rewrite ${manifest}"; }

  # An in-place writer that truncates its own input on a bad day is worse than
  # no writer: the manifest IS the record of what is enforced, and an empty one
  # reads to every downstream check as "nothing to enforce". A rewrite may only
  # change the CONTENT of lines, never how many there are, so a line-count
  # mismatch means the transform went wrong and the original stands.
  local before after
  before="$(wc -l <"${manifest}")"
  after="$(wc -l <"${tmp}")"
  if [ "${after}" -ne "${before}" ]; then
    rm -f "${tmp}"
    misconfig "rewrite would change the manifest from ${before} to ${after} lines — refusing, ${manifest} is unchanged"
  fi
  cat "${tmp}" >"${manifest}"
  rm -f "${tmp}"
}

# Pull the `# measured N%` provenance out of a row's trailing comment. Empty if
# the row carries none — which is itself a lint failure, because a floor with no
# recorded measurement cannot be checked against the pin rule, and a number
# nobody can re-derive is a number nobody can review.
provenance_of() { # <raw-line>
  local comment="$1"
  if [[ "${comment}" =~ measured[[:space:]]+([0-9]+(\.[0-9]+)?)% ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# ---------------------------------------------------------------------------
# --lint — the manifest checked against its own pin rule. No report, no
# toolchain, milliseconds. This is the half of the guard that can run at commit
# time, and it is the half that would have caught the three hand-tightened rows
# (see the header) the day each one was written.
# ---------------------------------------------------------------------------
run_lint() { # [--fix]
  local fix=0
  [ "${1:-}" = "--fix" ] && fix=1

  local manifest; manifest="$(manifest_path)"
  [ -f "${manifest}" ] || misconfig "manifest not found: ${manifest}"

  # Strict syntax first, via the same parser the enforcing run uses, so --lint
  # is a superset of "the manifest parses" and one command answers the whole
  # static question. Driven off the stacks the file actually declares rather
  # than a hardcoded rust+flutter, because read_manifest treats an absent stack
  # as a misconfiguration — correct when enforcing, wrong here, and it would
  # make every hermetic fixture below unrunnable.
  local st
  while read -r st; do
    [ -n "${st}" ] || continue
    read_manifest "${st}" >/dev/null
  done < <(awk -F'|' '!/^[[:space:]]*#/ && NF >= 3 { print $1 }' "${manifest}" | sort -u)

  local -a problems=()
  local -A seen_key=()
  local edits; edits="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${edits}'" RETURN

  local lineno=0 line code comment f_stack f_pattern f_floor f_margin
  local measured want key rows=0 fixed=0
  while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    [ -n "${line}" ] || continue
    case "${line}" in \#*) continue ;; esac

    # Split exactly the way read_manifest does, so lint and enforcement agree
    # on where a declaration ends. This also drops CONTINUATION lines — the
    # indented `#` rows that carry a row's narrative onto a second line. They
    # are pure comment, but they do not start at column 0, so a naive
    # leading-`#` skip reads each one as a floor declaration and reports it as
    # a row with no provenance.
    code="${line%%[[:space:]]#*}"
    code="${code%"${code##*[![:space:]]}"}"
    [ -n "${code}" ] || continue
    comment="${line#"${code}"}"

    IFS='|' read -r f_stack f_pattern f_floor f_margin _ <<<"${code}"
    f_margin="${f_margin:-${DEFAULT_RATCHET_MARGIN}}"
    rows=$((rows + 1))

    key="${f_stack}|${f_pattern}"
    if [ -n "${seen_key[${key}]:-}" ]; then
      problems+=("$(printf 'DUPLICATE  %s (line %s, first declared on line %s).\n           Two floors for one path means one of them is dead: the loop takes\n           whichever it reads, and the other is a number nobody enforces.' \
        "${key}" "${lineno}" "${seen_key[${key}]}")")
      continue
    fi
    seen_key["${key}"]="${lineno}"

    measured="$(provenance_of "${comment}")"
    if [ -z "${measured}" ]; then
      problems+=("$(printf 'NO-PROVENANCE  %s (line %s).\n               Every row must record the value it was pinned from, as\n               `# measured N%%`. Without it the floor cannot be checked\n               against the pin rule, and a reviewer cannot tell a ratchet-\n               driven raise from someone quietly relaxing a floor.\n               Re-pin with: %s --repin %s <lcov>' \
        "${f_pattern}" "${lineno}" "${SCRIPT_NAME}.sh" "${f_stack}")")
      continue
    fi

    want="$(pin_for "${measured}")"

    # TOO TIGHT — the floor sits above what the rule allows, so the row has
    # less than the two points of headroom every other row gets. This is the
    # defect that reddened run 30964250098.
    if [ "${f_floor}" -gt "${want}" ]; then
      problems+=("$(printf 'TOO-TIGHT  %s (line %s)\n           floor %s%% against a measured %s%%: %s point(s) of headroom, where the\n           pin rule (floor(measured) - %s, or exactly 100) gives %s%%.\n           A floor this close to its measurement is a tripwire, not a floor —\n           the next unrelated change to land in this path reddens CI.\n           Fix: set the floor to %s (or run --lint --fix).' \
        "${f_pattern}" "${lineno}" "${f_floor}" "${measured}" \
        "$(awk -v m="${measured}" -v fl="${f_floor}" 'BEGIN { printf "%.2f", m - fl }')" \
        "${PIN_HEADROOM}" "${want}" "${want}")")
      printf '%s\t%s\t\n' "${lineno}" "${want}" >>"${edits}"
      continue
    fi

    # TOO LOOSE — the recorded measurement already sits at or past floor+margin,
    # so the row was stale the moment it was written. The live ratchet would
    # catch this on the next coverage run; catching it here costs no test run.
    if awk -v m="${measured}" -v fl="${f_floor}" -v mg="${f_margin}" \
         'BEGIN { exit (m + 0 >= fl + mg + 0) ? 0 : 1 }'; then
      problems+=("$(printf 'TOO-LOOSE  %s (line %s)\n           floor %s%% against a measured %s%% — already %s or more points below\n           its own provenance, which is where the ratchet fires. The floor was\n           stale when it was written.\n           Fix: set the floor to %s (or run --lint --fix).' \
        "${f_pattern}" "${lineno}" "${f_floor}" "${measured}" "${f_margin}" "${want}")")
      printf '%s\t%s\t\n' "${lineno}" "${want}" >>"${edits}"
      continue
    fi
  done <"${manifest}"

  log "${BOLD}Coverage-floor manifest lint — ${rows} rows in ${manifest#"${REPO_ROOT}/"}${RESET}"
  log ""

  if [ "${#problems[@]}" -eq 0 ]; then
    printf '%sOK: every floor obeys the pin rule (floor(measured) - %s, 100 pinned exactly).%s\n' \
      "${GREEN}" "${PIN_HEADROOM}" "${RESET}"
    return 0
  fi

  printf '%s%s problem(s):%s\n' "${RED}" "${#problems[@]}" "${RESET}" >&2
  local p
  for p in "${problems[@]}"; do printf '  %s\n\n' "${p}" >&2; done

  if [ "${fix}" -eq 1 ] && [ -s "${edits}" ]; then
    fixed="$(wc -l <"${edits}" | tr -d ' ')"
    rewrite_manifest "${edits}"
    printf '%s--fix: rewrote %s floor(s) to the pin rule. Review the diff before committing.%s\n' \
      "${GREEN}" "${fixed}" "${RESET}"
    # Re-run clean so --fix cannot report success on a file it failed to mend
    # (a row with no provenance is unfixable and must still be a failure).
    run_lint
    return $?
  fi

  fail "Coverage-floor manifest does not obey its own pin rule (${SCRIPT_NAME}.sh --lint --fix rewrites the mechanical ones)."
}

# ---------------------------------------------------------------------------
# --repin — raise earned floors in place, from a fresh report.
#
# The direction is the whole design. Coverage climbing past a floor is the
# routine case and used to require hand arithmetic against a `--list` dump,
# which is how the manifest acquired hand-tightened rows in the first place.
# Coverage FALLING is not routine, and this deliberately cannot express it: a
# row whose measurement dropped is left byte-for-byte alone, so `--repin` can
# never be the tool that turns a measured regression into a permitted one. When
# a drop matters, it surfaces as BELOW on the next enforcing run, with tests as
# the only remedy.
# ---------------------------------------------------------------------------
run_repin() { # <stack> <lcov-file>
  local stack="$1" lcov="$2"
  case "${stack}" in
    rust|flutter|selftest) ;;
    *) misconfig "unknown stack '${stack}' (expected: rust | flutter)" ;;
  esac
  [ -f "${lcov}" ] || misconfig "coverage report not found: ${lcov}"

  local -a paths=() hits=() founds=()
  local p h f
  while IFS=$'\t' read -r p h f; do
    [ -n "${p}" ] || continue
    paths+=("${p}"); hits+=("${h}"); founds+=("${f}")
  done < <(measure "${lcov}")
  [ "${#paths[@]}" -gt 0 ] \
    || misconfig "parsed 0 source records from ${lcov} — the report is empty or not lcov"

  read_manifest "${stack}"

  local edits; edits="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${edits}'" RETURN

  local i j pattern floor agg_h agg_f matched pct target
  local raised=0 held=0 dropped=0 stale=0
  log "${BOLD}Re-pinning coverage floors — stack '${stack}'${RESET}"
  log ""

  for ((i = 0; i < ${#MAN_PATTERN[@]}; i++)); do
    pattern="${MAN_PATTERN[$i]}"; floor="${MAN_FLOOR[$i]}"
    agg_h=0; agg_f=0; matched=0
    local glob="${pattern}"
    case "${glob}" in */) glob="${glob}*" ;; esac
    for ((j = 0; j < ${#paths[@]}; j++)); do
      # shellcheck disable=SC2053
      if [[ "${paths[$j]}" == ${glob} ]]; then
        matched=$((matched + 1)); agg_h=$((agg_h + hits[j])); agg_f=$((agg_f + founds[j]))
      fi
    done

    if [ "${matched}" -eq 0 ] || [ "${agg_f}" -eq 0 ]; then
      printf '  %sSTALE  %s%s — no measurable file; left untouched (the enforcing run will fail on it)\n' \
        "${RED}" "${pattern}" "${RESET}"
      stale=$((stale + 1))
      continue
    fi

    pct="$(awk -v h="${agg_h}" -v f="${agg_f}" 'BEGIN { printf "%.2f", (h / f) * 100 }')"
    target="$(pin_for "${pct}")"

    if [ "${target}" -gt "${floor}" ]; then
      printf '  %sRAISE  %-52s %s%% -> %s%%%s   (measured %s%%)\n' \
        "${GREEN}" "${pattern}" "${floor}" "${target}" "${RESET}" "${pct}"
      printf '%s\t%s\t%s%% (%s/%s)\n' "${MAN_LINE[$i]}" "${target}" "${pct}" "${agg_h}" "${agg_f}" >>"${edits}"
      raised=$((raised + 1))
    elif [ "${target}" -lt "${floor}" ]; then
      # The pin rule would LOWER this row. Never done, and never even recorded:
      # rewriting the provenance while holding the floor would leave the row
      # failing its own lint, and rewriting both would be the laundering this
      # tool exists not to do.
      printf '  %sHOLD   %-52s %s%% kept%s   (measured %s%% — coverage fell; add tests, do not re-pin)\n' \
        "${YELLOW}" "${pattern}" "${floor}" "${RESET}" "${pct}"
      dropped=$((dropped + 1))
    else
      held=$((held + 1))
    fi
  done

  log ""
  if [ -s "${edits}" ]; then
    rewrite_manifest "${edits}"
  fi
  printf '%s raised, %s already at the pin, %s held (coverage fell), %s stale.\n' \
    "${raised}" "${held}" "${dropped}" "${stale}"
  if [ "${raised}" -gt 0 ]; then
    printf '%sManifest updated — review the diff, then commit it with the change that earned it.%s\n' \
      "${GREEN}" "${RESET}"
  else
    printf 'Manifest unchanged.\n'
  fi
  [ "${stale}" -eq 0 ] || fail "${stale} stale entr(ies) — fix the pattern(s) before re-pinning."
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no toolchain, no repo state.
#
# Each fixture isolates ONE way this guard could be wrong. The three that carry
# the most weight are (2) a path that fell below its floor, (4) a floor the code
# has outgrown, and (5) an entry matching nothing: those are, in order, the
# regression it exists to catch, the way it decays into a rubber stamp, and the
# way an individual entry becomes a false green.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # A report covering the shapes that matter: an exactly-at-floor file, a
  # comfortably-inside-band file, a directory holding one fully covered and one
  # untouched file (so prefix aggregation is exercised, not assumed), and a
  # small file where one line is worth 5 points.
  cat >"${tmp}/report.lcov" <<'EOF'
SF:/build/checkout/haven-core/src/nostr/mls/manager.rs
LF:100
LH:90
end_of_record
SF:src/nostr/giftwrap.rs
LF:200
LH:174
end_of_record
SF:./src/nostr/encryption/mod.rs
LF:100
LH:100
end_of_record
SF:src/nostr/encryption/aead.rs
LF:100
LH:0
end_of_record
SF:src/relay/gate.rs
LF:20
LH:19
end_of_record
EOF

  # manager.rs 90.00, giftwrap 87.00, encryption/ aggregates to 50.00,
  # gate.rs 95.00 with a WIDENED margin: one line of a 20-line file is 5 whole
  # points, so at the default margin that row would sit exactly on the ratchet
  # threshold and demand a re-pin for a single covered line. Fixture (13)
  # removes the override and pins that this is the only reason it passes.
  cat >"${tmp}/manifest.ok" <<'EOF'
# comments and blank lines are ignored

selftest|src/nostr/mls/manager.rs|90
selftest|src/nostr/giftwrap.rs|85
selftest|src/nostr/encryption/|48
selftest|src/relay/gate.rs|90|10
rust|src/not/my/stack.rs|99
EOF

  _case() { # _case <label> <expect-rc> <manifest> <report>
    local label="$1" want="$2" man="$3" report="$4" got=0
    # SUBSHELL, not a bare call: run_check exits on failure, which would abort
    # the self-test at its first negative fixture and leave every later one
    # silently unrun — a self-test that only ever proves the happy path.
    ( HAVEN_COVERAGE_FLOORS="${man}" run_check selftest "${report}" ) >/dev/null 2>&1 || got=$?
    if [ "${got}" -eq "${want}" ]; then
      printf '  %sPASS%s %s (rc=%d)\n' "${GREEN}" "${RESET}" "${label}" "${got}"
    else
      printf '  %sFAIL%s %s (want rc=%d, got rc=%d)\n' "${RED}" "${RESET}" "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  log "self-test: floors"

  # (1) Happy path. Every pinned path is inside its band: at floor, above it but
  #     within the margin, aggregated across a directory, and margin-overridden.
  _case "all paths within band pass" 0 "${tmp}/manifest.ok" "${tmp}/report.lcov"

  # (2) THE CRITICAL FIXTURE — a path fell below its floor. This is the defect
  #     A5 exists for: with only an aggregate gate, this run is green.
  sed 's/^LH:90$/LH:89/' "${tmp}/report.lcov" >"${tmp}/report.below.lcov"
  _case "path below its floor fails" 1 "${tmp}/manifest.ok" "${tmp}/report.below.lcov"

  # (3) The boundary, pinned explicitly so a future `>` written for `>=` is
  #     caught: a floor set to the EXACT measured value must pass. A guard that
  #     failed here could never be landed at a freshly measured pin, and would
  #     get deleted rather than fixed.
  printf 'selftest|src/nostr/giftwrap.rs|87\n' >"${tmp}/manifest.atfloor"
  _case "floor equal to the measured value passes" 0 "${tmp}/manifest.atfloor" "${tmp}/report.lcov"

  # (4) THE RATCHET FIXTURE — coverage climbed past floor+margin. Nothing is
  #     broken in the code; the FLOOR is broken, because it now licenses a
  #     silent fall back to a level the code has left. Must fail, must name the
  #     new number.
  sed 's|^LF:200$|LF:200\nLH:191|; s|^LH:174$||' "${tmp}/report.lcov" >"${tmp}/report.ratchet.lcov"
  _case "path that outgrew its floor fails (needs raise)" 1 "${tmp}/manifest.ok" "${tmp}/report.ratchet.lcov"

  # …and the message must actually carry the number to write down, or the
  # failure is a puzzle rather than an instruction.
  local msg
  msg="$( ( HAVEN_COVERAGE_FLOORS="${tmp}/manifest.ok" run_check selftest "${tmp}/report.ratchet.lcov" ) 2>&1 || true )"
  if printf '%s' "${msg}" | grep -q 'Raise the floor to 95'; then
    printf '  %sPASS%s ratchet message names the new floor\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s ratchet message did not name the new floor (95)\n' "${RED}" "${RESET}" >&2
    fails=1
  fi

  # (5) THE STALE-ENTRY FIXTURE — a floor for a path the report has no record
  #     of. It can never be below its floor, so without this rule it is a
  #     permanent false green: the same lesson as a stale row in
  #     expected_test_skips.txt.
  cat "${tmp}/manifest.ok" >"${tmp}/manifest.stale"
  printf 'selftest|src/nostr/mls/renamed_away.rs|80\n' >>"${tmp}/manifest.stale"
  _case "manifest entry matching no file fails" 1 "${tmp}/manifest.stale" "${tmp}/report.lcov"

  # (6) A path that exists but carries no instrumented lines is the same false
  #     green wearing a different hat: 0/0 has no percentage to fall below.
  cat >"${tmp}/report.empty_file.lcov" <<'EOF'
SF:src/nostr/mls/manager.rs
LF:100
LH:90
end_of_record
SF:src/nostr/consts.rs
LF:0
LH:0
end_of_record
EOF
  printf 'selftest|src/nostr/consts.rs|0\nselftest|src/nostr/mls/manager.rs|90\n' >"${tmp}/manifest.zero_lines"
  _case "entry matching only zero-line files fails" 1 "${tmp}/manifest.zero_lines" "${tmp}/report.empty_file.lcov"

  # (7) Directory aggregation must be a real sum, not the first or last file
  #     under the prefix. encryption/ is 100/200 = 50%; a guard that read only
  #     mod.rs would see 100% and pass a floor of 90.
  printf 'selftest|src/nostr/encryption/|90\n' >"${tmp}/manifest.dir"
  _case "directory prefix aggregates (not first/last file)" 1 "${tmp}/manifest.dir" "${tmp}/report.lcov"

  # (8) Parser rot. If SF extraction ever matches nothing, every entry would
  #     report "matched no file" — a true failure with a false explanation. It
  #     must be reported as a BROKEN GUARD (rc 2), never as a clean run.
  printf 'no source records here\n' >"${tmp}/report.garbage.lcov"
  _case "unparsable report is misconfig, not pass" 2 "${tmp}/manifest.ok" "${tmp}/report.garbage.lcov"

  # (9) The vacuous-manifest case, one level up from (5): a stack with zero
  #     entries enforces nothing while printing a pass.
  printf 'rust|src/other.rs|50\n' >"${tmp}/manifest.wrongstack"
  _case "manifest with no rows for the stack is misconfig" 2 "${tmp}/manifest.wrongstack" "${tmp}/report.lcov"

  # (10) A malformed row must not be silently skipped — a typo'd entry that is
  #      ignored is a floor that quietly stopped being enforced.
  printf 'selftest|src/nostr/mls/manager.rs|ninety\n' >"${tmp}/manifest.badfloor"
  _case "non-numeric floor is misconfig" 2 "${tmp}/manifest.badfloor" "${tmp}/report.lcov"
  printf 'selftest|src/nostr/mls/manager.rs\n' >"${tmp}/manifest.short"
  _case "row missing the floor field is misconfig" 2 "${tmp}/manifest.short" "${tmp}/report.lcov"

  # (11) A missing report must not read as "nothing to check".
  _case "absent report is misconfig, not pass" 2 "${tmp}/manifest.ok" "${tmp}/does-not-exist.lcov"

  # (12) The per-entry margin override must actually APPLY, not merely parse.
  #      gate.rs is 95.00 against floor 90: at the default margin of 5 that is
  #      exactly on the ratchet threshold and must fail, and it passes in
  #      fixture (1) only because that row widens the margin to 10. Without
  #      this pair, an override could be read and then silently discarded.
  printf 'selftest|src/relay/gate.rs|90\n' >"${tmp}/manifest.nooverride"
  _case "same row without its margin override ratchets" 1 "${tmp}/manifest.nooverride" "${tmp}/report.lcov"

  # (13) A fully covered path pinned BELOW 100 must ratchet. Without this the
  #      margin rule is arithmetically unable to fire on it (100 < 98+5), so the
  #      floor would under-declare the real value permanently — a floor that
  #      LOOKS ratcheted and never can be. encryption/mod.rs is 100/100.
  printf 'selftest|src/nostr/encryption/mod.rs|98\n' >"${tmp}/manifest.full100_low"
  _case "100% path pinned below 100 ratchets" 1 "${tmp}/manifest.full100_low" "${tmp}/report.lcov"

  # (14) …and pinned AT 100 it passes, so the rule above is satisfiable rather
  #      than an unlandable trap.
  printf 'selftest|src/nostr/encryption/mod.rs|100\n' >"${tmp}/manifest.full100_exact"
  _case "100% path pinned at 100 passes" 0 "${tmp}/manifest.full100_exact" "${tmp}/report.lcov"

  # ---- the static lint ----------------------------------------------------
  # These fixtures cover the failure that actually happened: a floor hand-set
  # above what the pin rule allows, leaving a row one small change from red.

  _lint() { # _lint <label> <expect-rc> <manifest>
    local label="$1" want="$2" man="$3" got=0
    ( HAVEN_COVERAGE_FLOORS="${man}" run_lint ) >/dev/null 2>&1 || got=$?
    if [ "${got}" -eq "${want}" ]; then
      printf '  %sPASS%s %s (rc=%d)\n' "${GREEN}" "${RESET}" "${label}" "${got}"
    else
      printf '  %sFAIL%s %s (want rc=%d, got rc=%d)\n' "${RED}" "${RESET}" "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  # (15) A manifest whose every floor is exactly the pin rule applied to its own
  #      provenance. 93.29 -> 91, 100.00 -> 100 (exact), 1.69 -> 0 (clamped, not
  #      negative), and a widened margin carried through.
  cat >"${tmp}/lint.ok" <<'EOF'
selftest|src/nostr/mls/|91                    # measured 93.29% (1419/1521)
selftest|src/nostr/mls/welcome.rs|100         # measured 100.00% (124/124)
selftest|lib/src/services/task.dart|0         # measured 1.69% (4/236)
selftest|src/relay/gate.rs|90|10              # measured 95.00% (19/20)
EOF
  _lint "manifest obeying the pin rule passes" 0 "${tmp}/lint.ok"

  # (16) THE FIXTURE FOR THE DEFECT THIS LINT EXISTS FOR — the exact shape of
  #      the row that reddened run 30964250098: floor 51 against a measured
  #      51.06%, i.e. 0.06 points of headroom where the rule gives 49.
  printf 'selftest|lib/src/services/|51        # measured 51.06%% (1373/2689)\n' >"${tmp}/lint.tight"
  _lint "floor pinned tighter than the rule fails" 1 "${tmp}/lint.tight"

  # …and the message must name the value to write down, or the failure is a
  # puzzle rather than an instruction.
  msg="$( ( HAVEN_COVERAGE_FLOORS="${tmp}/lint.tight" run_lint ) 2>&1 || true )"
  if printf '%s' "${msg}" | grep -q 'set the floor to 49'; then
    printf '  %sPASS%s lint names the corrected floor\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s lint did not name the corrected floor (49)\n' "${RED}" "${RESET}" >&2
    fails=1
  fi

  # (17) `--fix` must actually rewrite the number, and must leave the rest of the
  #      row — the margin override, the provenance comment, the alignment —
  #      untouched. A fixer that reformatted the file would hide the change it
  #      made inside a whitespace diff.
  printf 'selftest|src/relay/gate.rs|94|10     # measured 95.00%% (19/20)\n' >"${tmp}/lint.fix"
  ( HAVEN_COVERAGE_FLOORS="${tmp}/lint.fix" run_lint --fix ) >/dev/null 2>&1 || true
  if grep -qF 'selftest|src/relay/gate.rs|93|10     # measured 95.00% (19/20)' "${tmp}/lint.fix"; then
    printf '  %sPASS%s --fix rewrites only the floor, preserving margin/comment/columns\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s --fix mangled the row: %s\n' "${RED}" "${RESET}" "$(cat "${tmp}/lint.fix")" >&2
    fails=1
  fi

  # (18) A floor so far below its own provenance that the ratchet would fire on
  #      sight. Caught statically, before any suite runs.
  printf 'selftest|src/nostr/mls/|80           # measured 93.29%% (1419/1521)\n' >"${tmp}/lint.loose"
  _lint "floor already past the ratchet in its own provenance fails" 1 "${tmp}/lint.loose"

  # (19) A row with no `# measured` provenance cannot be checked against the
  #      rule at all, so it must fail rather than pass unchecked — and `--fix`
  #      must not report success on it.
  printf 'selftest|src/nostr/mls/|91\n' >"${tmp}/lint.noprov"
  _lint "row without provenance fails" 1 "${tmp}/lint.noprov"
  local frc=0
  ( HAVEN_COVERAGE_FLOORS="${tmp}/lint.noprov" run_lint --fix ) >/dev/null 2>&1 || frc=$?
  if [ "${frc}" -ne 0 ]; then
    printf '  %sPASS%s --fix still fails on an unfixable row (rc=%d)\n' "${GREEN}" "${RESET}" "${frc}"
  else
    printf '  %sFAIL%s --fix reported success on a row it cannot mend\n' "${RED}" "${RESET}" >&2
    fails=1
  fi

  # (20) Two floors for one path: the loop enforces one of them and the other is
  #      a number nobody reads. Same false-green shape as a stale entry.
  cat >"${tmp}/lint.dup" <<'EOF'
selftest|src/nostr/mls/|91                    # measured 93.29% (1419/1521)
selftest|src/nostr/mls/|60                    # measured 93.29% (1419/1521)
EOF
  _lint "duplicate path rows fail" 1 "${tmp}/lint.dup"

  # ---- --repin ------------------------------------------------------------
  # (21) A floor the code has outgrown must be RAISED and its provenance
  #      refreshed. giftwrap.rs measures 87.00 in the fixture report, so a floor
  #      of 80 becomes 85.
  printf 'selftest|src/nostr/giftwrap.rs|80    # measured 82.00%% (164/200)\n' >"${tmp}/repin.up"
  ( HAVEN_COVERAGE_FLOORS="${tmp}/repin.up" run_repin selftest "${tmp}/report.lcov" ) >/dev/null 2>&1 || true
  if grep -qF 'selftest|src/nostr/giftwrap.rs|85    # measured 87.00% (174/200)' "${tmp}/repin.up"; then
    printf '  %sPASS%s --repin raises an outgrown floor and refreshes its provenance\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s --repin did not raise correctly: %s\n' "${RED}" "${RESET}" "$(cat "${tmp}/repin.up")" >&2
    fails=1
  fi

  # (22) THE CRITICAL --repin FIXTURE — coverage FELL. The tool must leave the
  #      row byte-for-byte alone: neither the floor nor the provenance may move
  #      down, or `--repin` becomes the one-command way to launder a measured
  #      regression into a permitted one.
  local before after
  printf 'selftest|src/nostr/giftwrap.rs|89    # measured 91.50%% (183/200)\n' >"${tmp}/repin.down"
  before="$(cat "${tmp}/repin.down")"
  ( HAVEN_COVERAGE_FLOORS="${tmp}/repin.down" run_repin selftest "${tmp}/report.lcov" ) >/dev/null 2>&1 || true
  after="$(cat "${tmp}/repin.down")"
  if [ "${before}" = "${after}" ]; then
    printf '  %sPASS%s --repin never lowers a floor when coverage fell\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s --repin rewrote a row whose coverage dropped: %s\n' "${RED}" "${RESET}" "${after}" >&2
    fails=1
  fi

  # (23) …and whatever --repin writes must satisfy the lint, or the two writers
  #      of this manifest disagree about its rule.
  _lint "a --repin'd manifest passes the lint" 0 "${tmp}/repin.up"

  # (24) The CHECKED-IN manifest must obey the pin rule. This is the fixture
  #      that turns the whole lint into a standing invariant rather than a
  #      facility nobody points at the real file.
  local lrc=0
  ( run_lint ) >/dev/null 2>&1 || lrc=$?
  if [ "${lrc}" -eq 0 ]; then
    printf '  %sPASS%s checked-in manifest obeys the pin rule\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s checked-in manifest violates the pin rule (rc=%d) — run --lint\n' "${RED}" "${RESET}" "${lrc}" >&2
    fails=1
  fi

  # (25) The REAL manifest must parse for both real stacks. A syntax error in a
  #      checked-in row would otherwise only surface in the coverage workflow,
  #      an hour of test runtime later.
  local rc=0
  ( read_manifest rust ) >/dev/null 2>&1 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    printf '  %sPASS%s checked-in manifest parses (stack rust)\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s checked-in manifest does not parse for stack rust (rc=%d)\n' "${RED}" "${RESET}" "${rc}" >&2
    fails=1
  fi
  rc=0
  ( read_manifest flutter ) >/dev/null 2>&1 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    printf '  %sPASS%s checked-in manifest parses (stack flutter)\n' "${GREEN}" "${RESET}"
  else
    printf '  %sFAIL%s checked-in manifest does not parse for stack flutter (rc=%d)\n' "${RED}" "${RESET}" "${rc}" >&2
    fails=1
  fi

  log ""
  if [ "${fails}" -ne 0 ]; then
    fail "self-test failed — this guard cannot be trusted until it is fixed"
  fi
  printf '%sOK: self-test passed (31 fixtures).%s\n' "${GREEN}" "${RESET}"
}

main() {
  case "${1:---help}" in
    --self-test)
      self_test
      ;;
    --lint)
      [ "$#" -le 2 ] || misconfig "usage: ${SCRIPT_NAME}.sh --lint [--fix]"
      [ "$#" -eq 1 ] || [ "${2}" = "--fix" ] \
        || misconfig "unknown option '${2}' (usage: ${SCRIPT_NAME}.sh --lint [--fix])"
      run_lint "${2:-}"
      ;;
    --repin)
      [ "$#" -eq 3 ] || misconfig "usage: ${SCRIPT_NAME}.sh --repin <rust|flutter> <lcov-file>"
      run_repin "$2" "$3"
      ;;
    --list)
      [ "$#" -eq 3 ] || misconfig "usage: ${SCRIPT_NAME}.sh --list <rust|flutter> <lcov-file>"
      run_list "$2" "$3"
      ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
      ;;
    *)
      [ "$#" -eq 2 ] || misconfig "usage: ${SCRIPT_NAME}.sh <rust|flutter> <lcov-file> | --lint [--fix] | --repin <stack> <lcov> | --list <stack> <lcov> | --self-test"
      run_check "$1" "$2"
      ;;
  esac
}

main "$@"
