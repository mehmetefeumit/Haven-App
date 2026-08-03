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
# ## Usage
#
#   check_coverage_floors.sh <stack> <lcov-file>   # enforce (stack: rust|flutter)
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

  local -a violations=()
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
        ;;
    esac
  done

  log ""
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
    # Same rule the manifest is pinned with: two points of headroom, except at
    # 100 where the pin is exact (see run_check's verdict for why).
    pin="$(awk -v p="${pct}" 'BEGIN {
      v = int(p) - 2; if (p + 0 >= 100) v = 100; if (v < 0) v = 0; printf "%d", v
    }')"
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

  # (15) The REAL manifest must parse for both real stacks. A syntax error in a
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
  printf '%sOK: self-test passed (18 fixtures).%s\n' "${GREEN}" "${RESET}"
}

main() {
  case "${1:---help}" in
    --self-test)
      self_test
      ;;
    --list)
      [ "$#" -eq 3 ] || misconfig "usage: ${SCRIPT_NAME}.sh --list <rust|flutter> <lcov-file>"
      run_list "$2" "$3"
      ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
      ;;
    *)
      [ "$#" -eq 2 ] || misconfig "usage: ${SCRIPT_NAME}.sh <rust|flutter> <lcov-file> | --list <stack> <lcov> | --self-test"
      run_check "$1" "$2"
      ;;
  esac
}

main "$@"
