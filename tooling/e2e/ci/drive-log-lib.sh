#!/usr/bin/env bash
#
# Shared predicate: did the ON-DEVICE test suite actually fail, regardless of
# what `flutter drive` reported as its exit code?
#
# ## Why this exists
#
# `flutter drive` CAN EXIT 0 ON A FAILED TEST. Observed in CI run 30753193231:
# `e2e_profile_android` printed
#
#     I/flutter ( 3849): 00:01 +0: (setUpAll) [E]
#     I/flutter ( 3849):   set_profile_relays_for_test already installed
#     I/flutter ( 3849): 00:01 +1 -1: Some tests failed.
#
# and the harness recorded `flutter drive attempt 1/3 (rc=0)`. The lane went
# GREEN on a red test. The same scenario on iOS — which runs under
# `flutter test -d <udid>` rather than `flutter drive` — failed correctly, which
# is what exposed the split.
#
# The mechanism is `package:integration_test`: its binding collects per-test
# results from `testWidgets` bodies only, and `integrationDriver()` passes when
# that results map contains no failures. A failure in `setUpAll` /
# `tearDownAll` is never entered into the map, so the driver is told everything
# passed and exits 0. Anything that fails OUTSIDE a `testWidgets` body is
# therefore invisible to every `flutter drive`-based lane in this repo.
#
# That is the CI_HARDENING_BACKLOG.md thesis in its purest form — "CI verifies
# structure, logic and liveness, but almost never verifies delivery" — so the
# fix is not to trust the exit code but to read what the APP said.
#
# ## The second lie: a test that SKIPS
#
# `markTestSkipped()` sets `Result.skipped`, and `Result.isPassing` reports that
# as TRUE (test_api/src/backend/state.dart). Everything downstream inherits it.
# `integrationDriver()` reads `_success` from the binding's results map, and
# flutter_test's own ON-DEVICE reporter files the test under `passed`
# (test_compat.dart's `_runLiveTest` branches on `isPassing`). So on a
# `flutter drive` lane the reporter's `~N` skipped column NEVER MOVES for a
# runtime skip: it counts only statically `skip:`ped tests, which go through
# `_runSkippedTest`. The iOS lanes run `flutter test -d <udid>` through
# package:test's compact reporter instead, where `~N` DOES move (test_core's
# LiveSuiteController files `Result.skipped` under `skipped`). Two reporters,
# two behaviours — and the one the backlog named as "the only signal" is the
# blind one on the lanes it was named for.
#
# What BOTH reporters emit is the skip MESSAGE: a line of exactly two spaces
# followed by the reason, verbatim (the `MessageType.skip` branch of
# test_compat.dart and of compact.dart alike; on a drive lane logcat forwards it
# as `I/flutter ( NNNN):   <reason>`, indentation intact). That is what this
# library asserts on, and it is the better signal anyway: it carries the reason,
# and the reason IS the gate — a gate that silently changes cause must not pass.
#
# The reasons live in tooling/e2e/expected_drive_skips.txt together with the
# argument for why each one cannot fire in the lane that drives its target.
# Every entry there is derived UNREACHABLE, so observing one is a lane failure.
# A NEW hatch cannot land undeclared, because `--check-manifest` reconciles that
# file against the source tree in repo-guards.yml on every PR.
#
# ## The two halves are not symmetric, so both are checked
#
# The static half above covers the whole tree. The runtime half only reaches a
# lane whose runner consults `drive_log_reports_test_failure`, and for most rows
# in the manifest that consultation is one DELEGATION hop away:
# run-integration-tests.sh, run-relay-customization.sh and run-flake-stress.sh
# drive each target through run-single-avd-scenario.sh, while
# run-b4-ios-real-gps.sh and run-b7-ios-auth-tier.sh go through
# run-ios-sim-scenario.sh, which reaches the predicate through the
# ios-flake-lib.sh it sources. A runner refactor that stopped delegating —
# inlining its own `flutter drive`, say — would delete the runtime backstop for
# every row those runners carry, and the static half would stay green over it.
# `--check-wiring` is that missing assertion: every run-*.sh must still REACH
# the predicate. It is run by `--check-manifest` too, so the one repo-guards
# step covers both halves of the contract the manifest states.
#
# ## Usage
#
#   source "$(dirname "${BASH_SOURCE[0]}")/drive-log-lib.sh"
#   if drive_log_reports_test_failure /tmp/flutter-drive.log; then ... fi
#
#   bash tooling/e2e/ci/drive-log-lib.sh --self-test        # hermetic, no device
#   bash tooling/e2e/ci/drive-log-lib.sh --check-manifest   # source <-> manifest
#                                                           # (+ --check-wiring)
#   bash tooling/e2e/ci/drive-log-lib.sh --check-wiring     # runners <-> predicate
#   bash tooling/e2e/ci/drive-log-lib.sh --scan <drive-log> # what did it skip?
#
# Deliberately does NOT `set` shell options at source time: a sourced library
# that flips `-e`/`-E`/`pipefail` silently changes error handling in whatever
# runner picked it up. Options are set only on the direct-execution path at the
# foot of this file.

# Include guard — `readonly` below would abort a second source.
if [[ -n "${_HAVEN_DRIVE_LOG_LIB_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_HAVEN_DRIVE_LOG_LIB_SOURCED=1

# App-side failure evidence, matched against the drive log (which carries the
# device's forwarded `I/flutter` output). Three independent signals so a
# reporter-format change cannot silently disable all of them:
#
#   1. `Some tests failed.` — the flutter_test reporter's own verdict.
#   2. A compact-reporter progress line with a NON-ZERO failure count
#      (`+3 -1:`). `-0` is never emitted, so `-[1-9]` cannot false-positive on
#      a clean run.
#   3. `(setUpAll) [E]` / `(tearDownAll) [E]` — the exact shape that is
#      invisible to integrationDriver, called out explicitly so this keeps
#      working even if the counters or the summary line ever change.
#
# Deliberately NOT matched: a bare `[E]`, which appears in unrelated device
# chatter, and `All tests passed.`, which is the DRIVER's claim rather than the
# app's and is precisely the string that lied in run 30753193231.
#   4. `All tests skipped.` — the app's summary when NOTHING ran.
#      `integrationDriver` treats an EMPTY results map as
#      `allTestsPassed == true`, so a target whose `main()` declares no
#      `testWidgets` (a bad conditional, a refactor that drops the call) is
#      green in every drive lane. A suite that ran nothing has proven nothing;
#      that is the same class of lie this whole predicate exists to catch.
#
#   5. A NON-ZERO `~N` skipped column (`+9 ~2:`). Zero tests are expected to
#      skip in any lane — derived per call site in
#      tooling/e2e/expected_drive_skips.txt, not assumed — so a moved counter is
#      a proof that stopped running. It catches every STATIC `skip:` on both
#      reporters and, on the iOS `flutter test -d <udid>` lanes, runtime
#      `markTestSkipped` too; the drive lanes' runtime skips never reach it and
#      are caught by the declared-reason scan below instead.
#
# The failure-counter rule tolerates an optional `~N` column (`+3 ~1 -2:`) and
# accepts end-of-line as a terminator, because a drive killed mid-line — the
# exact case fixture 4 is meant to cover — loses the trailing separator.
readonly DRIVE_LOG_FAILURE_RE='Some tests failed\.|All tests skipped\.|\+[0-9]+( ~[0-9]+)? -[1-9][0-9]*([[:space:]:]|$)|\+[0-9]+ ~[1-9][0-9]*([[:space:]:]|$)|\((setUpAll|tearDownAll)\) \[E\]'

# The progress-line shape both reporters emit (`MM:SS +N…`). Its ABSENCE means
# the suite never reported anything, so a skip scan of that log has proven
# nothing — reported as "cannot judge", never as "clean". Deliberately NOT a
# failure signal: a launch stall produces exactly this shape and
# ios-flake-lib.sh must stay free to retry it.
readonly DRIVE_LOG_REPORTER_RE='[0-9][0-9]:[0-9][0-9] \+[0-9]+'

# Resolved at source time (the library's own location never moves under it);
# the manifest is read per invocation so --self-test can point HAVEN_DRIVE_SKIP_
# MANIFEST at a fixture without the real file leaking into it.
_DRIVE_LOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DRIVE_LOG_E2E_DIR="$(cd "${_DRIVE_LOG_LIB_DIR}/.." && pwd)"

drive_log_skip_manifest_path() {
  printf '%s\n' \
    "${HAVEN_DRIVE_SKIP_MANIFEST:-${_DRIVE_LOG_E2E_DIR}/expected_drive_skips.txt}"
}

# The reporter wraps the counter and the `[E]` marker in SGR escapes when
# colour is on (`_green + "+N" + _noColor + _red + " -M" + …`), which splits
# both patterns and would silently collapse the three signals down to
# `Some tests failed.` alone. Colour is off today only because of a hardcoded
# `_Reporter(color: false)` upstream — one literal away from breaking this. So
# strip SGR sequences before matching rather than depending on that.
_drive_log_decolour() {
  local esc
  esc="$(printf '\033')"
  sed "s/${esc}\\[[0-9;]*m//g" -- "$1" 2>/dev/null || true
}

# Build one ERE alternation from the manifest's declared skip reasons.
#
# Reasons are stored as they appear in the Dart SOURCE, so a `${e.runtimeType}`
# or a `$label` interpolation is part of the text. Each becomes a wildcard —
# swapped for a sentinel BEFORE the ERE metacharacters are escaped, so the
# escaping pass cannot mangle it and the sentinel (which has no metacharacters
# of its own) survives untouched.
#
# Each alternative is anchored on the reporter's two-space indent, either at the
# start of the line (`flutter test`) or straight after logcat's tag prefix
# (`I/flutter ( 3849):   …`). Without that anchor a debugPrint that merely
# QUOTED a reason would trip the guard.
#
# Returns 1 when the manifest is missing or declares nothing — callers treat
# that as "cannot judge". The manifest going missing is caught, red, by
# --check-manifest in repo-guards.yml, which is where it belongs: an E2E lane
# must not be the thing that discovers a deleted file in the repo.
_drive_log_declared_skip_re() {
  local manifest re
  manifest="$(drive_log_skip_manifest_path)"
  [[ -f "${manifest}" ]] || return 1
  re="$(awk -F'|' '
    /^[[:space:]]*(#|$)/ { next }
    NF < 2 { next }
    {
      r = $2
      gsub(/\$\{[^}]*\}/, "@@HAVEN_SKIP_WILDCARD@@", r)
      gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, "@@HAVEN_SKIP_WILDCARD@@", r)
      gsub(/[][\\.^$*+?(){}|]/, "\\\\&", r)
      gsub(/@@HAVEN_SKIP_WILDCARD@@/, ".*", r)
      printf "%s(^|: )  %s", (n++ ? "|" : ""), r
    }
  ' "${manifest}")"
  [[ -n "${re}" ]] || return 1
  printf '%s\n' "${re}"
}

# drive_log_skip_scan <logfile> — did any DECLARED skip actually fire?
#
#   0  the log carries reporter output and none of the declared reasons appear
#   1  a declared reason appeared: a test did not run
#   2  cannot judge — no log, no reporter output in it, or no usable manifest
#
# rc 2 is deliberately NOT a lane failure. The reporter-less shape is exactly
# what a launch stall leaves behind, and ios-flake-lib.sh classifies those as
# retryable by asking drive_log_reports_test_failure; folding rc 2 in there
# would make every iOS retry impossible. It is still never reported as CLEAN,
# so a caller can tell "nothing skipped" from "I could not tell".
drive_log_skip_scan() {
  local log="${1:-}" re
  [[ -f "${log}" ]] || return 2
  _drive_log_decolour "${log}" | grep -aqE -- "${DRIVE_LOG_REPORTER_RE}" || return 2
  re="$(_drive_log_declared_skip_re)" || return 2
  _drive_log_decolour "${log}" | grep -aqE -- "${re}" && return 1
  return 0
}

# drive_log_reports_test_failure <logfile> — 0 (true) when the app reported a
# test failure. A missing or unreadable log returns 1 (no evidence of failure);
# callers already treat a missing drive log as their own error, and this
# predicate must never invent a failure it cannot see.
#
# A fired skip counts as a failure here so that every runner already sourcing
# this library inherits the check with no edit of its own — the same route by
# which `All tests skipped.` is treated as a failure: a proof that did not run
# has not been proven.
drive_log_reports_test_failure() {
  local log="${1:-}" rc=0
  [[ -f "${log}" ]] || return 1
  _drive_log_decolour "${log}" | grep -aqE -- "${DRIVE_LOG_FAILURE_RE}" && return 0
  drive_log_skip_scan "${log}" || rc=$?
  [[ "${rc}" -eq 1 ]]
}

# Print the matching evidence lines (for the error message). Capped so a
# pathological log cannot flood the step output.
drive_log_failure_evidence() {
  local log="${1:-}" rc=0 re
  [[ -f "${log}" ]] || return 0
  _drive_log_decolour "${log}" \
    | grep -aE -- "${DRIVE_LOG_FAILURE_RE}" | head -10 || true

  drive_log_skip_scan "${log}" || rc=$?
  if [[ "${rc}" -eq 1 ]] && re="$(_drive_log_declared_skip_re)"; then
    _drive_log_decolour "${log}" | grep -aE -- "${re}" | head -10 || true
    # Same stream as the matched lines above: every caller redirects this
    # function as a whole, and splitting the diagnosis across stdout and stderr
    # would interleave it with the runner's own output at random.
    cat <<EOF

  A TEST SKIPPED. The line(s) above are the reporter's skip message; the test
  they belong to is named on the progress line just before each one.

  Every entry in $(drive_log_skip_manifest_path)
  is declared UNREACHABLE in the lane that drives its target, so an observed
  skip means the derivation recorded there is now wrong. Reconcile it:

    1. Find the entry with that reason and re-read its argument block.
    2. Establish which half broke — the guard now fires in CI (a keyring that
       stopped being installed, a target driven on a platform its entry did not
       account for), or the target gained a lane.
    3. FIX THE LANE if the proof is meant to run there. Only if it genuinely
       cannot run, rewrite the entry's argument to say so, and say where the
       invariant is proven instead — a skip with no substitute proof is a
       deleted test wearing a disguise.

  Do NOT silence this by deleting the entry: an undeclared hatch fails
  \`drive-log-lib.sh --check-manifest\` in repo-guards.yml.
EOF
  fi
}

# ---------------------------------------------------------------------------
# Static reconciliation — the source tree against the manifest.
#
# The runtime scan above can only recognise a reason it was told about, so on
# its own it would be blind to a BRAND NEW hatch. This is the half that closes
# that: you cannot add a `markTestSkipped()` under haven/integration_test/
# without writing down which test, which gate, and why it cannot fire in CI.
# Needs no toolchain and no device, so it runs as an ordinary repo guard.
# ---------------------------------------------------------------------------

# Prints `<haven-relative target>|<reason source text>` for every call site.
# Exit 3 is the extractor's own rot alarm — a misconfiguration, never a policy
# verdict, because no manifest edit can fix it.
_drive_log_extract_call_sites() {
  local root="$1" dir="${1}/haven/integration_test" f
  if [[ ! -d "${dir}" ]]; then
    echo "PARSE-ERROR ${dir} does not exist — wrong repo root?" >&2
    return 3
  fi
  local files=()
  while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -name '*.dart' | sort)
  if (( ${#files[@]} == 0 )); then
    echo "PARSE-ERROR no .dart files under ${dir}" >&2
    return 3
  fi

  # An INDEPENDENT count of the same fact. The awk below joins adjacent Dart
  # string literals across lines, which is the part that can rot; a plain grep
  # for the call token cannot. Without this cross-check a rotted joiner would
  # report "0 call sites" and every manifest row would look stale — or, worse,
  # an empty manifest would look complete.
  local seen
  # `grep -o | wc -l`, not `grep -c`: -c counts LINES, so two calls on one line
  # would read as ONE and agree with the joiner, which also emits one row for
  # that line — the counts would match and the second hatch would be dropped in
  # silence. Counting occurrences is what makes them disagree and alarm.
  seen="$(grep -h -- 'markTestSkipped(' "${files[@]}" \
    | grep -vE '^[[:space:]]*(//|\*)' \
    | grep -o -- 'markTestSkipped(' | wc -l | tr -d '[:space:]')" || true

  awk -v root="${root}/haven/" -v seen="${seen:-0}" '
    function emit(   s, out, i, n, parts, rel, q) {
      q = sprintf("%c", 39)
      s = buf
      sub(/^.*markTestSkipped\(/, "", s)
      sub(/\)[[:space:]]*;[[:space:]]*$/, "", s)
      out = ""
      n = split(s, parts, q)
      for (i = 2; i <= n; i += 2) out = out parts[i]
      rel = FILENAME
      if (index(rel, root) == 1) rel = substr(rel, length(root) + 1)
      if (out == "") empty++
      if (index(out, "|") > 0) pipes++
      printf "%s|%s\n", rel, out
      parsed++
    }
    { sub(/\r$/, "") }
    inarg {
      buf = buf " " $0
      if ($0 ~ /\);[[:space:]]*$/) { emit(); inarg = 0 }
      next
    }
    /^[[:space:]]*(\/\/|\*)/ { next }
    /markTestSkipped\(/ {
      buf = $0
      if ($0 ~ /\);[[:space:]]*$/) { emit() } else { inarg = 1 }
      next
    }
    END {
      if (inarg) {
        print "PARSE-ERROR a markTestSkipped( argument list was never closed" > "/dev/stderr"
        exit 3
      }
      if (parsed != seen + 0) {
        printf "PARSE-ERROR joined %d markTestSkipped() argument(s) but a plain grep sees %d call site(s) — the extractor has rotted\n", parsed, seen > "/dev/stderr"
        exit 3
      }
      if (empty > 0) {
        printf "PARSE-ERROR %d call site(s) yielded an EMPTY reason — the literal joiner has rotted\n", empty > "/dev/stderr"
        exit 3
      }
      if (pipes > 0) {
        printf "PARSE-ERROR %d reason(s) contain a `|`, which is the manifest field separator\n", pipes > "/dev/stderr"
        exit 3
      }
    }
  ' "${files[@]}"
}

drive_log_check_manifest() {
  local root="${1:-${_DRIVE_LOG_LIB_DIR}/../../..}" manifest observed out rc=0
  root="$(cd "${root}" 2>/dev/null && pwd)" || {
    echo "ERROR: repo root '${1:-}' is not a directory" >&2
    return 2
  }
  manifest="$(drive_log_skip_manifest_path)"
  if [[ ! -f "${manifest}" ]]; then
    echo "ERROR: skip manifest not found: ${manifest}" >&2
    return 2
  fi

  observed="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${observed}'" RETURN
  _drive_log_extract_call_sites "${root}" > "${observed}" || rc=$?
  if (( rc != 0 )); then
    echo "ERROR: could not extract the markTestSkipped() call sites (see above)" >&2
    return 2
  fi

  rc=0
  out="$(awk -v manifest_file="${manifest}" -F'|' '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

    FILENAME == manifest_file {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*(#|$)/) next
      if (split(line, f, "|") != 2) {
        printf "MANIFEST-ERROR line %d: expected exactly `target|reason`, got: %s\n", FNR, line > "/dev/stderr"
        bad = 1
        next
      }
      k = trim(f[1]) "|" f[2]
      if (k in declared) {
        printf "MANIFEST-ERROR line %d: duplicate entry for `%s`\n", FNR, k > "/dev/stderr"
        bad = 1
        next
      }
      n++
      key[n] = k
      declared[k] = n
      next
    }

    {
      if ($0 ~ /^[[:space:]]*$/) next
      obs++
      if (($0) in declared) { matched[$0]++; next }
      und[++u] = $0
    }

    END {
      if (bad) exit 2

      # Bucket both sides BY TARGET first. A target holding an unmatched row on
      # each side is one hatch whose reason moved, not two defects — and saying
      # so is the difference between "this gate changed cause, re-confirm it"
      # and a reader hunting two ghosts. Surplus rows on either side after the
      # pairing are real additions / real deletions and are still reported, so
      # a file that both changes one reason and drops another hides nothing.
      for (i = 1; i <= u; i++) {
        split(und[i], p, "|")
        t = p[1]; tset[t] = 1
        ulist[t, ++ucnt[t]] = substr(und[i], length(t) + 2)
      }
      for (j = 1; j <= n; j++) {
        got = (key[j] in matched) ? matched[key[j]] : 0
        if (got == 1) continue
        split(key[j], p, "|")
        t = p[1]; tset[t] = 1
        if (got == 0) slist[t, ++scnt[t]] = substr(key[j], length(t) + 2)
        else dup[++d] = key[j] "\t" got
      }

      fails = 0
      for (t in tset) {
        pairs = (ucnt[t] < scnt[t]) ? ucnt[t] : scnt[t]
        for (i = 1; i <= pairs; i++) {
          if (!changed) {
            print "\n  SKIP REASON CHANGED — the gate moved; re-confirm the derivation:" > "/dev/stderr"
            changed = 1
          }
          printf "    * %s\n      declared: %s\n      source:   %s\n", \
                 t, slist[t, i], ulist[t, i] > "/dev/stderr"
          fails = 1
        }
        for (i = pairs + 1; i <= ucnt[t]; i++) {
          if (!undhdr) {
            print "\n  UNDECLARED markTestSkipped() — a new escape hatch nobody wrote down:" > "/dev/stderr"
            undhdr = 1
          }
          printf "    * %s\n      reason: %s\n", t, ulist[t, i] > "/dev/stderr"
          fails = 1
        }
        for (i = pairs + 1; i <= scnt[t]; i++) {
          if (!stalehdr) {
            print "\n  STALE DECLARATION — the manifest allows a hatch the source no longer has:" > "/dev/stderr"
            stalehdr = 1
          }
          printf "    * %s\n      reason: %s\n", t, slist[t, i] > "/dev/stderr"
          fails = 1
        }
      }
      for (j = 1; j <= d; j++) {
        split(dup[j], q, "\t")
        printf "\n  DUPLICATE CALL SITE — `%s` declared once, found %s times\n", \
               q[1], q[2] > "/dev/stderr"
        fails = 1
      }
      printf "OBSERVED=%d DECLARED=%d\n", obs, n
      exit (fails ? 1 : 0)
    }
  ' "${manifest}" "${observed}")" || rc=$?

  case "${rc}" in
    0) ;;
    2)
      echo "ERROR: ${manifest} is unparsable (see above)" >&2
      return 2
      ;;
    *)
      cat >&2 <<EOF

  Reconcile ${manifest}.
  Every markTestSkipped() under haven/integration_test/ must have a row there,
  and every row must still name a live call site. A row is not paperwork: it
  states, with its argument block, WHY that hatch cannot fire in the lane that
  drives its target — which is what lets the E2E lanes treat an observed skip as
  a failure instead of tolerating a silent one.

  Regenerate the raw rows with:
    bash tooling/e2e/ci/drive-log-lib.sh --list
EOF
      return 1
      ;;
  esac

  echo "drive-log-lib.sh --check-manifest: OK —" \
       "$(printf '%s\n' "${out}" | sed -n 's/^OBSERVED=\([0-9]*\) .*/\1/p')" \
       "markTestSkipped() call site(s) under haven/integration_test/, all" \
       "declared in $(basename "${manifest}"), no stale declarations."
}

# ---------------------------------------------------------------------------
# Runtime reachability — the DELEGATION, not just the manifest.
#
# `--check-manifest` proves every hatch is declared. What makes a declared hatch
# fail a lane is drive_log_reports_test_failure(), and most manifest rows reach
# it only through a delegate (see this file's header). This half asserts that
# path still exists: every run-*.sh must reach the predicate directly, through a
# library it sources, or through a sibling runner it invokes.
#
# Deliberately NOT phrased as "every runner that drives a device must reach it".
# Recognising a drive means matching `flutter drive` / `flutter test` in command
# position, and these runners print those words in ordinary echo prose — so the
# detector would be the fragile part, and the failure mode of a fragile detector
# here is a SILENT PASS. Requiring every runner to reach the predicate needs no
# such detector: a runner that stops delegating fails whether or not the thing
# it does instead is recognisable.
# ---------------------------------------------------------------------------

# Runners that legitimately reach nothing. Pinned by EQUALITY and required to
# EXIST: a name here that names no file is a stale exemption, and it doubles as
# this check's anti-vacuity anchor — if the run-*.sh glob ever went blind, the
# exemption would stop resolving and the check fails instead of passing over an
# empty set.
readonly DRIVE_LOG_WIRING_EXEMPT=(
  # A generic deadline wrapper: it runs whatever command line it is handed and
  # drives nothing of its own, so the predicate belongs in the runner it wraps.
  run-with-deadline.sh
)

# Everything a runner SAYS rather than does: full-line `#` comments, a ` # `
# trailing comment, and heredoc BODIES. Deliberately not a general bash comment
# stripper: `${var#word}` has no space after the `#`, so demanding whitespace on
# both sides cannot eat a parameter expansion. Erring toward stripping too much
# is safe here — every rule below is a POSITIVE requirement, so a swallowed line
# makes this check fail, never pass.
#
# A heredoc body is data, and every runner in this tree carries a usage or
# diagnostic block. Left in, `cat <<EOF … bash "${INNER}" … EOF` supplies both
# halves of the edge rule below from a block that invokes nothing.
#
# The delimiter must survive the quote-strip as an identifier, which is what
# keeps `<<<"${x}"` herestrings and `(a << 24)` arithmetic from opening one. A
# terminator is matched at column 0 (leading TABs only for `<<-`), as bash does;
# a heredoc that never terminates therefore blanks the rest of the file, which
# again fails this check rather than passing it.
_drive_log_strip_sh_prose() {
  awk '
    BEGIN { qcls = "[" sprintf("%c%c", 39, 34) "]" }
    hd != "" {
      t = $0
      if (hdtabs) sub(/^\t+/, "", t)
      if (t == hd) hd = ""
      print ""
      next
    }
    {
      line = $0
      sub(/^[[:space:]]*#.*$/, "", line)
      sub(/[[:space:]]#[[:space:]].*$/, "", line)
      if (match(line, /<<-?[[:space:]]*[^[:space:];&|<>]+/)) {
        d = substr(line, RSTART, RLENGTH)
        hdtabs = (substr(d, 3, 1) == "-")
        sub(/^<<-?[[:space:]]*/, "", d)
        gsub(qcls, "", d)
        if (d ~ /^[A-Za-z_][A-Za-z0-9_]*$/) hd = d
      }
      print line
    }
  ' < "$1"
}

# The contents of every quoted word, leaving the quoting context itself intact
# across lines so a string opened on one line and closed on the next is gone in
# full. Applied ONLY to the predicate rule: a call names the function in command
# position, outside quotes (`if drive_log_reports_test_failure "${LOG}"`), while
# the edge rule below reads a path that legitimately lives INSIDE the quotes of
# an assignment, so stripping there would delete every real delegation.
_drive_log_strip_sh_strings() {
  awk '
    BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34) }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q == "") {
          if (c == "\\") { i++; continue }
          if (c == sq || c == dq) { q = c; continue }
          out = out c
        } else if (c == q) {
          q = ""
        } else if (q == dq && c == "\\") {
          i++
        }
      }
      print out
    }
  '
}

# `declare -F drive_log_reports_test_failure` is excluded on purpose: several
# runners probe the symbol in their own --self-test. Proving the function is
# DEFINED is not consulting it, and counting that would let a runner that never
# asks the predicate anything read as wired.
#
# Prose and quoted words are stripped for the same reason, and it is sharper
# here than elsewhere: the failure message this check prints TELLS authors to
# document the delegation, so `echo "… drive_log_reports_test_failure …"` is the
# remedy it recommends, and crediting it would make the guard endorse its own
# evasion.
_drive_log_calls_predicate() {
  _drive_log_strip_sh_prose "$1" \
    | _drive_log_strip_sh_strings \
    | grep -F -- 'drive_log_reports_test_failure' \
    | grep -qv -- 'declare -F'
}

# The sibling files one script reaches: the libraries it sources, and the
# runners it invokes.
#
# Delegation is written the same way at every call site in this tree —
# `readonly VAR="${dir}/run-x.sh"` and then `bash "${VAR}" …` — and BOTH halves
# are required. Naming a script in an assignment is not running it: every
# delegating runner also lists its delegate in a `for dep in …` existence check,
# and accepting that would make a runner that only checks its delegate exists
# look like one that uses it.
_drive_log_wiring_edges() {
  local code line var target
  code="$(_drive_log_strip_sh_prose "$1")"

  while IFS= read -r line; do
    grep -oE -- '[A-Za-z0-9_.-]+\.sh' <<<"${line}" | tail -1
  done < <(grep -E -- '^[[:space:]]*(source|\.)[[:space:]]' <<<"${code}" || true)

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    var="${line%%=*}"
    var="${var##* }"
    target="$(grep -oE -- '[A-Za-z0-9_.-]+\.sh' <<<"${line}" | tail -1)"
    # The invocation must start its line (after indentation, optionally behind
    # `bash`), which is what distinguishes it from `for dep in "${VAR}"` and
    # `[[ -f "${VAR}" ]]`.
    if grep -qE -- "^[[:space:]]*(bash[[:space:]]+)?\"?\\\$\{${var}\}\"?([[:space:]]|\$)" \
        <<<"${code}"; then
      printf '%s\n' "${target}"
    fi
  done < <(grep -E -- '^[[:space:]]*(readonly[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*[A-Za-z0-9_.-]+\.sh"?[[:space:]]*$' \
    <<<"${code}" || true)
}

# Does <name> reach the predicate? <visited> breaks cycles, so two runners that
# delegate to each other are unreached rather than an infinite descent.
_drive_log_reaches_predicate() { # <dir> <basename> <visited>
  local dir="$1" name="$2" visited="$3" edge
  [[ -f "${dir}/${name}" ]] || return 1
  case " ${visited} " in *" ${name} "*) return 1 ;; esac
  visited="${visited} ${name}"
  if _drive_log_calls_predicate "${dir}/${name}"; then return 0; fi
  while IFS= read -r edge; do
    [[ -n "${edge}" ]] || continue
    if _drive_log_reaches_predicate "${dir}" "${edge}" "${visited}"; then
      return 0
    fi
  done < <(_drive_log_wiring_edges "${dir}/${name}")
  return 1
}

drive_log_check_wiring() {
  local root="${1:-${_DRIVE_LOG_LIB_DIR}/../../..}" dir f name
  root="$(cd "${root}" 2>/dev/null && pwd)" || {
    echo "ERROR: repo root '${1:-}' is not a directory" >&2
    return 2
  }
  dir="${root}/tooling/e2e/ci"
  if [[ ! -d "${dir}" ]]; then
    echo "ERROR: ${dir} does not exist — wrong repo root?" >&2
    return 2
  fi

  local runners=()
  while IFS= read -r f; do
    runners+=("$(basename "${f}")")
  done < <(find "${dir}" -maxdepth 1 -name 'run-*.sh' | sort)
  if (( ${#runners[@]} < 2 )); then
    echo "ERROR: found ${#runners[@]} run-*.sh under ${dir}; this check has" >&2
    echo "gone blind rather than found a clean tree." >&2
    return 2
  fi

  local missing=()
  for name in "${DRIVE_LOG_WIRING_EXEMPT[@]}"; do
    [[ -f "${dir}/${name}" ]] || missing+=("${name}")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: DRIVE_LOG_WIRING_EXEMPT names ${#missing[@]} script(s) that no" >&2
    echo "longer exist: ${missing[*]}" >&2
    echo "A stale exemption is indistinguishable from a deleted backstop —" >&2
    echo "drop the entry in the commit that drops the script." >&2
    return 2
  fi

  local unreached=()
  for name in "${runners[@]}"; do
    case " ${DRIVE_LOG_WIRING_EXEMPT[*]} " in *" ${name} "*) continue ;; esac
    _drive_log_reaches_predicate "${dir}" "${name}" "" || unreached+=("${name}")
  done

  if (( ${#unreached[@]} > 0 )); then
    cat >&2 <<EOF

  RUNNER NOT WIRED TO THE DRIVE-LOG PREDICATE:
$(printf '    * %s\n' "${unreached[@]}")

  Each of these runs an E2E lane but no longer reaches
  drive_log_reports_test_failure — neither directly, nor through a library it
  sources, nor through a sibling runner it invokes.

  That predicate is the RUNTIME half of the contract
  $(drive_log_skip_manifest_path)
  states. Without it, a target driven by this runner can skip a declared hatch,
  or fail outside a testWidgets body, and the lane still reports success:
  integrationDriver() records a skip as a pass and exits 0 (see this file's
  header). --check-manifest cannot see this — it reads the Dart source and the
  manifest, never the runners — which is why the delegation is asserted here
  instead of described in prose.

  Fix by restoring the delegation, or by sourcing this library and asking the
  predicate about the drive log directly, the way run-single-avd-scenario.sh
  does. Do NOT add the runner to DRIVE_LOG_WIRING_EXEMPT unless it genuinely
  drives nothing.
EOF
    return 1
  fi

  echo "drive-log-lib.sh --check-wiring: OK —" \
       "${#runners[@]} run-*.sh under tooling/e2e/ci/," \
       "${#DRIVE_LOG_WIRING_EXEMPT[@]} exempt, every other one still reaches" \
       "drive_log_reports_test_failure."
}

# Number of assertions drive_log_lib_self_test must make. Pinned by EQUALITY,
# not by a floor: a floor lets a fixture be deleted and the suite stay green,
# which is the same "reports coverage it does not have" shape this whole library
# exists to catch. Change it only in the commit that adds or removes a fixture.
readonly DRIVE_LOG_SELF_TEST_FIXTURES=42

drive_log_lib_self_test() {
  local tmp fail=0 ran=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # Hermetic manifest for every fixture below. `local` (not `export`): the
  # lookup reads it through dynamic scope, and binding it here means no fixture
  # can accidentally reconcile against the REAL manifest — the same trap
  # scripts/ci/check_no_undeclared_skips.sh documents for its own lookup.
  local HAVEN_DRIVE_SKIP_MANIFEST="${tmp}/manifest.ok"
  cat > "${tmp}/manifest.ok" <<'EOF'
# comments and blank lines are ignored

integration_test/alpha_test.dart|alpha needs an Android emulator; skipped on non-Android runtimes.
integration_test/beta_test.dart|Keyring unavailable on this runner (${e.runtimeType}); skipping BETA-1.
integration_test/beta_test.dart|Keyring unavailable on this runner (${e.runtimeType}); skipping $label.
EOF

  # `ran=$(( ran + 1 ))`, never `(( ran++ ))`: the latter returns 1 when ran is
  # 0, which `set -e` on the direct-execution path would treat as a failure.
  _dl_expect_fail() { # <label> <logfile>
    ran=$(( ran + 1 ))
    if ! drive_log_reports_test_failure "$2"; then
      echo "SELF-TEST FAIL ($1): expected a lane failure, got silence" >&2
      fail=1
    fi
  }
  _dl_expect_clean() { # <label> <logfile>
    ran=$(( ran + 1 ))
    if drive_log_reports_test_failure "$2"; then
      echo "SELF-TEST FAIL ($1): an honest run was flagged as failing" >&2
      fail=1
    fi
  }
  _dl_expect_scan_rc() { # <label> <want-rc> <logfile> [<manifest>]
    local got=0
    ran=$(( ran + 1 ))
    ( HAVEN_DRIVE_SKIP_MANIFEST="${4:-${HAVEN_DRIVE_SKIP_MANIFEST}}" \
        drive_log_skip_scan "$3" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -ne "$2" ]]; then
      echo "SELF-TEST FAIL ($1): skip scan want rc=$2, got rc=${got}" >&2
      fail=1
    fi
  }
  _dl_expect_manifest_rc() { # <label> <want-rc> <manifest> <repo-root>
    local got=0
    ran=$(( ran + 1 ))
    # SUBSHELL: a prefixed assignment on a FUNCTION call persists in bash, and
    # drive_log_check_manifest returns rather than exits, so both need fencing.
    ( HAVEN_DRIVE_SKIP_MANIFEST="$3" drive_log_check_manifest "$4" ) \
      >/dev/null 2>&1 || got=$?
    if [[ "${got}" -ne "$2" ]]; then
      echo "SELF-TEST FAIL ($1): --check-manifest want rc=$2, got rc=${got}" >&2
      fail=1
    fi
  }
  _dl_expect_wiring_rc() { # <label> <want-rc> <repo-root>
    local got=0
    ran=$(( ran + 1 ))
    drive_log_check_wiring "$3" >/dev/null 2>&1 || got=$?
    if [[ "${got}" -ne "$2" ]]; then
      echo "SELF-TEST FAIL ($1): --check-wiring want rc=$2, got rc=${got}" >&2
      fail=1
    fi
  }

  # (1) THE CRITICAL FIXTURE — verbatim from run 30753193231, including the
  #     driver's own contradicting "All tests passed." line. If this ever stops
  #     being detected, a setUpAll failure silently turns green again.
  printf '%s\n' \
    'I/flutter ( 3849): 00:00 +0: (setUpAll)' \
    'I/flutter ( 3849): [ScenarioHarness] bootstrapped role=ScenarioRole.solo relay=ws://10.0.2.2:7777' \
    'I/flutter ( 3849): 00:01 +0: (setUpAll) [E]' \
    'I/flutter ( 3849):   set_profile_relays_for_test already installed' \
    'All tests passed.' \
    'I/flutter ( 3849): 00:01 +1 -1: Some tests failed.' \
    > "${tmp}/setupall.log"
  _dl_expect_fail 1 "${tmp}/setupall.log"

  # (2) A clean run must NOT trip — including the driver's "All tests passed."
  #     and a passing counter with no failure component.
  printf '%s\n' \
    'I/flutter ( 3849): 00:00 +0: scenario A' \
    'I/flutter ( 3849): 00:12 +1: scenario B' \
    'I/flutter ( 3849): 00:31 +12: All tests passed!' \
    'All tests passed.' \
    > "${tmp}/clean.log"
  _dl_expect_clean 2 "${tmp}/clean.log"

  # (3) An in-body test failure (the ordinary case, where drive DOES exit
  #     non-zero) must still be detected — the predicate is a belt to the
  #     exit code's braces, not a replacement scoped to setUpAll.
  printf '%s\n' \
    'I/flutter ( 3849): 00:44 +3 -1: scenario C [E]' \
    'I/flutter ( 3849): 00:45 +3 -1: Some tests failed.' \
    > "${tmp}/inbody.log"
  _dl_expect_fail 3 "${tmp}/inbody.log"

  # (4) Counter-only failure, no summary line (a drive killed mid-run by a
  #     timeout never prints "Some tests failed.").
  printf '%s\n' \
    'I/flutter ( 3849): 02:10 +7 -2: scenario D' \
    > "${tmp}/counter.log"
  _dl_expect_fail 4 "${tmp}/counter.log"

  # (5) A missing log is NOT evidence of failure — callers diagnose that
  #     themselves, and inventing a failure here would misattribute it.
  _dl_expect_clean 5 "${tmp}/does-not-exist.log"

  # (6) A scenario NAME containing the digits pattern must not false-positive.
  #     Guards the `-[1-9]` counter rule against ordinary prose.
  printf '%s\n' \
    'I/flutter ( 3849): 00:03 +2: circle 1-2 members sync' \
    'I/flutter ( 3849): 00:04 +3: epoch 3-1 rotation' \
    > "${tmp}/prose.log"
  _dl_expect_clean 6 "${tmp}/prose.log"

  # (7) ANSI-COLOURED reporter output. The escapes split the counter and the
  #     `[E]` marker; without de-colouring, two of the four signals die
  #     silently and nothing in a colourless fixture set would notice.
  printf 'I/flutter ( 3849): 00:01 +0: (setUpAll) \033[1m\033[31m[E]\033[0m\n' \
    > "${tmp}/ansi.log"
  _dl_expect_fail 7 "${tmp}/ansi.log"
  printf 'I/flutter ( 3849): \033[32m00:44 +3\033[0m\033[31m -1\033[0m: scenario C\n' \
    > "${tmp}/ansi-counter.log"
  _dl_expect_fail 7b "${tmp}/ansi-counter.log"

  # (8) MID-LINE TRUNCATION — a drive killed by a timeout loses the trailing
  #     separator after the counter. This is fixture 4's own stated scenario,
  #     which the original terminator-required regex did not actually cover.
  printf 'I/flutter ( 3849): 02:10 +7 -2' > "${tmp}/truncated.log"
  _dl_expect_fail 8 "${tmp}/truncated.log"

  # (9) VACUOUS SUITE — nothing ran. `integrationDriver` reports an EMPTY
  #     results map as all-passed and exits 0, so this is green in every drive
  #     lane without the signal. A suite that ran nothing proved nothing.
  printf '%s\n' \
    'I/flutter ( 3849): 00:00 +0: All tests skipped.' \
    'All tests passed.' \
    > "${tmp}/skipped.log"
  _dl_expect_fail 9 "${tmp}/skipped.log"

  # (10) SKIPPED COLUMN present alongside a real failure (`+3 ~1 -2:`) — the
  #      counter rule must still fire with the `~N` column interposed.
  printf '%s\n' \
    'I/flutter ( 3849): 00:50 +3 ~1 -2: scenario E' \
    > "${tmp}/skipcol.log"
  _dl_expect_fail 10 "${tmp}/skipcol.log"

  # (11) A NON-ZERO `~N` WITH NO FAILURE COMPONENT IS ITSELF A FAILURE.
  #      This fixture used to assert the opposite ("`~N` alone is not a
  #      failure"), on the argument that over-reading it would redden honest
  #      runs. That argument is now settled the other way, and by derivation
  #      rather than by assumption: every markTestSkipped() under
  #      haven/integration_test/ was traced to the lane that drives it and none
  #      can fire (tooling/e2e/expected_drive_skips.txt), and there is no static
  #      `skip:` in the tree at all. So no honest run has a skipped column, and
  #      a run that does has lost a proof.
  printf '%s\n' \
    'I/flutter ( 3849): 00:50 +9 ~2: scenario F' \
    'I/flutter ( 3849): 00:51 +9 ~2: All tests passed!' \
    > "${tmp}/skipcolumn.log"
  _dl_expect_fail 11 "${tmp}/skipcolumn.log"

  # (12) THE DRIVE-LANE SHAPE, which the counter above cannot see. On
  #      `flutter drive` a runtime markTestSkipped leaves `+N` alone (the test
  #      is filed under `passed`), so the ONLY trace is the indented reason
  #      forwarded through logcat. Every other signal in this library is silent
  #      here — this fixture is the whole reason the manifest exists.
  printf '%s\n' \
    'I/flutter ( 3849): 00:03 +1: alpha' \
    'I/flutter ( 3849):   alpha needs an Android emulator; skipped on non-Android runtimes.' \
    'I/flutter ( 3849): 00:04 +2: All tests passed!' \
    > "${tmp}/driveskip.log"
  _dl_expect_fail 12 "${tmp}/driveskip.log"

  # (13) The declared reason carries a Dart interpolation; the runtime text has
  #      a concrete value in its place. If the wildcard substitution regressed,
  #      16 of the 23 declared hatches would stop being recognised — and the
  #      colourless, prefix-free fixtures would all still pass.
  printf '%s\n' \
    'I/flutter ( 3849): 00:03 +1: beta' \
    'I/flutter ( 3849):   Keyring unavailable on this runner (StateError); skipping BETA-1.' \
    > "${tmp}/interp.log"
  _dl_expect_fail 13 "${tmp}/interp.log"

  # (13b) The BARE `$name` interpolation, which is a SEPARATE substitution from
  #       the `${...}` one above and had no fixture: without it the `$` is
  #       escaped as a literal by the metacharacter pass and the row stops
  #       matching anything a device ever prints. Exactly one real row uses this
  #       form — the `$label` of relay_two_plane_privacy_test.dart, whose single
  #       shared helper covers BOTH testWidgets bodies in that file — so the
  #       branch guards two proofs and nothing else guards it.
  printf '%s\n' \
    'I/flutter ( 3849): 00:05 +2: two-plane' \
    'I/flutter ( 3849):   Keyring unavailable on this runner (StateError); skipping location-plane.' \
    > "${tmp}/interp-bare.log"
  _dl_expect_fail 13b "${tmp}/interp-bare.log"

  # (14) The same skip message under colour, in the reporter's exact byte
  #      layout: the escape opens between the timestamp and the `+` counter
  #      (`_timeString` is written uncoloured, `_green` starts at `+`), and the
  #      skip message is wrapped in yellow INSIDE its two-space indent. Both of
  #      this fixture's rules therefore need de-colouring — the progress-line
  #      probe that decides whether the log can be judged at all, and the reason
  #      anchor itself. A colourless fixture set would notice neither.
  printf 'I/flutter ( 3849): 00:03 \033[32m+1\033[0m: alpha\nI/flutter ( 3849):   \033[33malpha needs an Android emulator; skipped on non-Android runtimes.\033[0m\n' \
    > "${tmp}/ansiskip.log"
  _dl_expect_fail 14 "${tmp}/ansiskip.log"

  # (15) The iOS lane shape: `flutter test -d <udid>` reports from the HOST, so
  #      there is no logcat prefix and the indent starts the line. Both signals
  #      are present here and that is faithful — on this reporter a runtime skip
  #      DOES move `~N` — so the end-to-end assertion is checked first…
  printf '%s\n' \
    '00:01 +0: probe group beta' \
    '  Keyring unavailable on this runner (StateError); skipping BETA-1.' \
    '00:01 +0 ~1: probe group beta' \
    > "${tmp}/hostskip.log"
  _dl_expect_fail 15 "${tmp}/hostskip.log"

  # (15b) …and then the REASON half is pinned on its own, because fixture 15
  #       cannot see it. `~1` on that log satisfies the counter rule by itself,
  #       so 15 stays green even with the `(^|…)` start-of-line branch of the
  #       anchor deleted — the one branch it is named for. Asserting the SCAN
  #       rather than the predicate removes the counter from the circuit: this
  #       is what fails if the host-shape anchor regresses, which would
  #       otherwise leave `--scan` and every evidence dump silently reporting
  #       "no declared skip fired" on a log that skipped.
  _dl_expect_scan_rc 15b 1 "${tmp}/hostskip.log"

  # (16) FALSE-POSITIVE GUARD. A reason QUOTED in ordinary output — a debugPrint
  #      echoing it, a comment in a dumped source line — is not a skip. Only the
  #      reporter's own two-space indent counts, and a rule that dropped the
  #      anchor would redden honest lanes on their own chatter.
  printf '%s\n' \
    'I/flutter ( 3849): 00:03 +1: alpha' \
    'I/flutter ( 3849): [alpha] guard text is "alpha needs an Android emulator; skipped on non-Android runtimes."' \
    'I/flutter ( 3849): 00:04 +2: All tests passed!' \
    > "${tmp}/quoted.log"
  _dl_expect_clean 16 "${tmp}/quoted.log"

  # (17) A log with NO REPORTER LINE AT ALL must never read as "clean". The scan
  #      reports rc 2 (cannot judge) — it has seen nothing the suite said, so a
  #      silent pass would be the vacuous-guard shape this file exists to catch.
  printf '%s\n' \
    'Launching lib/main.dart on sdk gphone64 x86 64 in debug mode...' \
    'Running Gradle task assembleDebug...' \
    > "${tmp}/noreporter.log"
  _dl_expect_scan_rc 17 2 "${tmp}/noreporter.log"

  # (18) …and rc 2 must NOT be a lane failure. That shape is exactly a launch
  #      stall, which ios-flake-lib.sh classifies as retryable by asking this
  #      predicate; folding rc 2 in would make every iOS retry impossible.
  _dl_expect_clean 18 "${tmp}/noreporter.log"

  # (19) A missing manifest is "cannot judge", never "clean". The build is
  #      turned red for that by --check-manifest, which is the right place: an
  #      E2E lane must not be what discovers a deleted file in the repo.
  _dl_expect_scan_rc 19 2 "${tmp}/driveskip.log" "${tmp}/no-such-manifest.txt"

  # -------------------------------------------------------------------------
  # Static half: the source tree against the manifest.
  # -------------------------------------------------------------------------
  local src="${tmp}/repo/haven/integration_test"
  mkdir -p "${src}"

  # Multi-line adjacent literals — the shape 22 of the 23 real call sites use,
  # and the one the joiner can rot on.
  cat > "${src}/alpha_test.dart" <<'DART'
void main() {
  testWidgets('alpha', (tester) async {
    if (!Platform.isAndroid) {
      markTestSkipped(
        'alpha needs an Android emulator; skipped on '
        'non-Android runtimes.',
      );
      return;
    }
  });
}
DART

  # Single-line form, plus a `${...}` interpolation inside the reason. The
  # second call site carries a BARE `$label` (the other substitution form) and
  # gives this target two rows, which is also the only place the by-target
  # pairing in --check-manifest is exercised against more than one row.
  cat > "${src}/beta_test.dart" <<'DART'
void main() {
  testWidgets('beta', (tester) async {
    try {
      await initKeyringStore();
    } on Object catch (e) {
      markTestSkipped('Keyring unavailable on this runner (${e.runtimeType}); skipping BETA-1.');
      return;
    }
  });

  Future<void> runLeakProof(String label) async {
    try {
      await initKeyringStore();
    } on Object catch (e) {
      markTestSkipped('Keyring unavailable on this runner (${e.runtimeType}); skipping $label.');
      return;
    }
  }
}
DART

  # (20) The happy path: every call site declared, every declaration live, both
  #      call shapes parsed.
  _dl_expect_manifest_rc 20 0 "${tmp}/manifest.ok" "${tmp}/repo"

  # (21) THE CRITICAL FIXTURE for this half — a new hatch nobody declared. This
  #      is the defect: a proof acquires an escape route and the tree is silent.
  cat > "${src}/gamma_test.dart" <<'DART'
void main() {
  testWidgets('gamma', (tester) async {
    markTestSkipped('gamma is disabled for now.');
    return;
  });
}
DART
  _dl_expect_manifest_rc 21 1 "${tmp}/manifest.ok" "${tmp}/repo"
  rm -f "${src}/gamma_test.dart"

  # (22) THE OTHER CRITICAL FIXTURE — a declaration whose call site is gone. A
  #      stale allowance is indistinguishable from a deleted proof, and it also
  #      means the argument recorded beside it is now describing nothing.
  cat "${tmp}/manifest.ok" > "${tmp}/manifest.stale"
  printf '%s\n' \
    'integration_test/deleted_test.dart|deleted hatch; skipped on non-Android runtimes.' \
    >> "${tmp}/manifest.stale"
  _dl_expect_manifest_rc 22 1 "${tmp}/manifest.stale" "${tmp}/repo"

  # (23) Same call site, different reason. Silently accepting this would let a
  #      keyring gate become a "flaky, disabled" gate with no review — the
  #      reason IS the gate.
  sed 's/skipping BETA-1\./skipping BETA-1 (flaky)./' \
    "${tmp}/manifest.ok" > "${tmp}/manifest.reason"
  _dl_expect_manifest_rc 23 1 "${tmp}/manifest.reason" "${tmp}/repo"

  # (24) A duplicate row is a manifest error, not a lenient allowance: two rows
  #      for one call site means one of them can never go stale.
  cat "${tmp}/manifest.ok" "${tmp}/manifest.ok" > "${tmp}/manifest.dup"
  _dl_expect_manifest_rc 24 2 "${tmp}/manifest.dup" "${tmp}/repo"

  # (25) A row with the wrong field count — an unescaped `|` inside a reason, a
  #      hand-added count column copied from the host manifest.
  printf '%s\n' \
    'integration_test/alpha_test.dart|alpha needs an Android emulator; skipped on non-Android runtimes.|1' \
    > "${tmp}/manifest.fields"
  _dl_expect_manifest_rc 25 2 "${tmp}/manifest.fields" "${tmp}/repo"

  # (26) A missing manifest is a misconfiguration, never a silent pass — the
  #      `scan-logs-for-secrets.sh exits 0 when its log is absent` shape.
  _dl_expect_manifest_rc 26 2 "${tmp}/nope.txt" "${tmp}/repo"

  # (27) PARSER ROT, unterminated argument list. The joiner would swallow the
  #      rest of the file and emit one row too few; the count cross-check must
  #      report that as rot rather than as a policy verdict, because no manifest
  #      edit can fix it.
  printf '%s\n' \
    'void main() {' \
    "  markTestSkipped(" \
    "    'never closed'," \
    > "${src}/rot_test.dart"
  _dl_expect_manifest_rc 27 2 "${tmp}/manifest.ok" "${tmp}/repo"
  rm -f "${src}/rot_test.dart"

  # (28) PARSER ROT, unsupported literal form. The joiner splits on single
  #      quotes, so a double-quoted reason yields an EMPTY one. Reporting that
  #      as "undeclared" would send the author to the manifest; it is the
  #      extractor that must be taught the form.
  cat > "${src}/rot2_test.dart" <<'DART'
void main() {
  markTestSkipped("double quoted reason");
}
DART
  _dl_expect_manifest_rc 28 2 "${tmp}/manifest.ok" "${tmp}/repo"
  rm -f "${src}/rot2_test.dart"

  # (29) PARSER ROT, two call sites on ONE line. The joiner's `sub(/^.*markTest
  #      Skipped\(/, ...)` is greedy, so it keeps only the LAST call and the
  #      first hatch vanishes with no other alarm — the line is terminated, so
  #      the unterminated-argument check of fixture 27 stays silent. Only the
  #      occurrence-count cross-check catches it, and nothing exercised that.
  printf '%s\n' \
    'void main() {' \
    "  if (a) { markTestSkipped('one'); } markTestSkipped('two');" \
    '}' \
    > "${src}/rot3_test.dart"
  _dl_expect_manifest_rc 29 2 "${tmp}/manifest.ok" "${tmp}/repo"
  rm -f "${src}/rot3_test.dart"

  # -------------------------------------------------------------------------
  # Runtime-reachability half: the runners against the predicate.
  #
  # Two fixture trees, because the two ways to reach it fail differently. `_mk`
  # writes one runner; every tree carries the exempt wrapper, whose presence is
  # what the stale-exemption rule reads, so a tree that omits it is fixture 36's
  # own case rather than an accident.
  # -------------------------------------------------------------------------
  local wtree
  _dl_mk_runner() { # <tree> <name> <body>
    mkdir -p "${1}/tooling/e2e/ci"
    printf '#!/usr/bin/env bash\n%s\n' "$3" > "${1}/tooling/e2e/ci/${2}"
  }
  _dl_mk_tree_a() { # <tree> — one direct caller, one delegating runner
    _dl_mk_runner "$1" run-with-deadline.sh 'exec "$@"'
    _dl_mk_runner "$1" run-direct.sh '
source "${SCRIPT_DIR}/drive-log-lib.sh"
flutter drive --target="${TARGET}" > "${LOG}" 2>&1 || drc=$?
if drive_log_reports_test_failure "${LOG}"; then exit 1; fi'
    _dl_mk_runner "$1" run-delegating.sh '
readonly INNER="${script_dir}/run-direct.sh"
for dep in "${INNER}"; do [[ -x "${dep}" ]] || exit 2; done
bash "${INNER}" "${target}" || rc=$?'
  }

  wtree="${tmp}/wiring-ok"
  _dl_mk_tree_a "${wtree}"

  # (30) The happy path: one runner asks the predicate itself, one reaches it
  #      through the runner it delegates to, one is exempt.
  _dl_expect_wiring_rc 30 0 "${wtree}"

  # (31) THE CRITICAL FIXTURE for this half — the refactor the manifest's
  #      RUNTIME claim rests on and nothing used to check. run-delegating.sh
  #      stops delegating and inlines its own `flutter drive`; every hatch its
  #      targets carry loses the backstop, and --check-manifest stays green
  #      over it because it never reads a runner at all.
  wtree="${tmp}/wiring-inlined"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
readonly HAVEN_DIR="${script_dir}/../../../haven"
( cd "${HAVEN_DIR}" && flutter drive --target="${target}" ) > "${LOG}" 2>&1 || rc=$?'
  _dl_expect_wiring_rc 31 1 "${wtree}"

  # (32) A runner that only PROBES the symbol (`declare -F`, the shape several
  #      real runners use in their own --self-test) has not consulted it. Left
  #      counting, this is the vacuous pass: the wiring reads as present in a
  #      runner that never asks the predicate anything.
  wtree="${tmp}/wiring-declare"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-direct.sh '
source "${SCRIPT_DIR}/drive-log-lib.sh"
rc=0; declare -F drive_log_reports_test_failure >/dev/null || rc=1
flutter drive --target="${TARGET}" || exit $?'
  _dl_expect_wiring_rc 32 1 "${wtree}"

  # (33) The delegate named in an EXISTENCE check but never invoked. Every real
  #      delegating runner has both lines, so an edge rule satisfied by the
  #      assignment alone would keep passing a runner that only checks its
  #      delegate is still on disk.
  wtree="${tmp}/wiring-unused"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
readonly INNER="${script_dir}/run-direct.sh"
for dep in "${INNER}"; do [[ -x "${dep}" ]] || exit 2; done
flutter drive --target="${target}" || rc=$?'
  _dl_expect_wiring_rc 33 1 "${wtree}"

  # (34) A runner that only DOCUMENTS the predicate. Every runner in this tree
  #      carries a paragraph explaining why `flutter drive` cannot be trusted,
  #      and most name drive_log_reports_test_failure and their delegate in it —
  #      so read raw, the prose satisfies both halves of the reach graph and the
  #      runner that deleted the call still looks wired. The first version of
  #      this fixture commented out the delegation instead, which the invocation
  #      anchor of fixture 33 already rejects on its own: it passed for a
  #      neighbouring rule's reason and proved nothing about the stripped view.
  wtree="${tmp}/wiring-comment"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
# `flutter drive` can exit 0 on a failed suite, so this lane consults
# drive_log_reports_test_failure via run-direct.sh before believing the code.
flutter drive --target="${target}" || rc=$?'
  _dl_expect_wiring_rc 34 1 "${wtree}"

  # (35) The SOURCE hop, on its own: run-ios-sim-scenario.sh reaches the
  #      predicate only through the ios-flake-lib.sh it sources, so the two
  #      iOS-only manifest rows hang off this edge alone. Isolated in a tree
  #      whose only non-exempt runner needs it, so nothing else can carry it.
  wtree="${tmp}/wiring-source"
  _dl_mk_runner "${wtree}" run-with-deadline.sh 'exec "$@"'
  _dl_mk_runner "${wtree}" run-sourced.sh '
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/flake-lib.sh"
flutter test "${SCENARIO}" -d "${UDID}" || rc=$?'
  printf '#!/usr/bin/env bash\n%s\n' \
    'if drive_log_reports_test_failure "${log}"; then return 1; fi' \
    > "${wtree}/tooling/e2e/ci/flake-lib.sh"
  _dl_expect_wiring_rc 35 0 "${wtree}"

  # (36) A STALE EXEMPTION is a misconfiguration, not a lenient pass: the
  #      exempted runner is gone, so the entry now excuses nothing — and it is
  #      also the only thing anchoring the glob, which is why it is rc 2 and
  #      not rc 1.
  wtree="${tmp}/wiring-stale"
  _dl_mk_tree_a "${wtree}"
  rm -f "${wtree}/tooling/e2e/ci/run-with-deadline.sh"
  _dl_expect_wiring_rc 36 2 "${wtree}"

  # (37) GLOB ROT. A rename or a moved directory that leaves one runner (or
  #      none) must report that it can no longer see the tree, never "every
  #      runner is wired" over an empty set.
  wtree="${tmp}/wiring-blind"
  _dl_mk_runner "${wtree}" run-with-deadline.sh 'exec "$@"'
  _dl_expect_wiring_rc 37 2 "${wtree}"

  # (38) The predicate named inside a STRING. Fixture 34 covers the same evasion
  #      behind a `#`; deleting the `#` is all it took, and this shape is the one
  #      the failure message above actively invites — it tells authors to write
  #      prose naming the predicate and its delegate. Nothing bash would EXECUTE
  #      here consults anything.
  wtree="${tmp}/wiring-echoed"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
echo "this lane consults drive_log_reports_test_failure via run-direct.sh"
flutter drive --target="${target}" || rc=$?'
  _dl_expect_wiring_rc 38 1 "${wtree}"

  # (39) The same, in a HEREDOC body — a usage/diagnostic block, which every real
  #      runner has. Its body carries BOTH halves of the reach graph: the
  #      predicate's name, and a delegation to run-direct.sh spelled exactly the
  #      way the edge rule recognises one. So a fix that only stripped quoted
  #      words would still pass this, and one that only stripped heredocs would
  #      still pass 38.
  wtree="${tmp}/wiring-heredoc"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
cat >&2 <<EOF
  This lane asks drive_log_reports_test_failure about the drive log, via
    readonly INNER="${script_dir}/run-direct.sh"
    bash "${INNER}" "${target}"
EOF
flutter drive --target="${target}" || rc=$?'
  _dl_expect_wiring_rc 39 1 "${wtree}"

  unset -f _dl_mk_runner _dl_mk_tree_a
  unset -f _dl_expect_fail _dl_expect_clean _dl_expect_scan_rc \
           _dl_expect_manifest_rc _dl_expect_wiring_rc

  if (( ran != DRIVE_LOG_SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${ran} fixtures, expected ${DRIVE_LOG_SELF_TEST_FIXTURES}" >&2
    fail=1
  fi
  if (( fail != 0 )); then
    echo "drive-log-lib.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "drive-log-lib.sh --self-test: all ${ran} fixtures passed"
  return 0
}

# Executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  case "${1:-}" in
    --self-test)
      drive_log_lib_self_test
      exit $?
      ;;
    --check-manifest)
      # Both halves of the manifest's contract, and BOTH run even when the
      # first fails — one red step should report every violation it can see,
      # which is repo-guards.yml's own discipline. The worse code wins, so a
      # broken guard (2) is never reported as a mere violation (1).
      rc=0
      wrc=0
      drive_log_check_manifest "${2:-}" || rc=$?
      drive_log_check_wiring "${2:-}" || wrc=$?
      if (( wrc > rc )); then rc="${wrc}"; fi
      exit "${rc}"
      ;;
    --check-wiring)
      drive_log_check_wiring "${2:-}"
      exit $?
      ;;
    # Authoring aid: print the rows the manifest is made of. Kept in the same
    # file as the checker so the ids you paste are the ids it compares.
    --list)
      _drive_log_extract_call_sites \
        "$(cd "${2:-${_DRIVE_LOG_LIB_DIR}/../../..}" && pwd)"
      exit $?
      ;;
    --scan)
      [[ -n "${2:-}" ]] || { echo "usage: drive-log-lib.sh --scan <drive-log>" >&2; exit 2; }
      rc=0
      drive_log_skip_scan "$2" || rc=$?
      case "${rc}" in
        0) echo "no declared skip fired in $2" ;;
        1) drive_log_failure_evidence "$2" ;;
        *) echo "cannot judge $2 — no reporter output, or no usable manifest" >&2 ;;
      esac
      exit "${rc}"
      ;;
  esac
  echo "drive-log-lib.sh is a sourced library; pass --self-test, --check-manifest," \
       "--check-wiring, --list or --scan <log> to run it directly." >&2
  exit 2
fi
