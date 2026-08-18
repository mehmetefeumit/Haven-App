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
# run-ios-sim-scenario.sh, which is a sixth: it drives ios_bg_mirror_test.dart
# for e2e-ios.yml directly and reaches the predicate only through the
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
#                                                           # (+ no static skip,
#                                                           #  + --check-wiring)
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
#      skip in any lane, which rests on two facts and assumes neither: every
#      markTestSkipped() is derived unreachable per call site in
#      tooling/e2e/expected_drive_skips.txt, and no test is skipped STATICALLY
#      (asserted by drive_log_check_static_skips below — it was the half argued
#      in prose and checked nowhere, and it is the half a one-word `skip:`
#      falsifies). So a moved counter is a proof that stopped running. It
#      catches every static `skip:` on both reporters and, on the iOS
#      `flutter test -d <udid>` lanes, runtime `markTestSkipped` too; the drive
#      lanes' runtime skips never reach it and are caught by the declared-reason
#      scan below instead.
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
# The premise the `~N` rule rests on — that nothing is skipped STATICALLY.
#
# Signal 5 treats any non-zero `~N` as a lane failure, which is sound only while
# two things hold: every markTestSkipped() is derived unreachable (the manifest,
# checked above) and no test carries a `skip:`. Only the first was enforced, and
# the second is the one a single word falsifies — `skip:` is the ordinary way to
# disable a Dart test, and --check-manifest is blind to it because it greps for
# markTestSkipped( alone.
#
# A static skip is already unusable here, so this changes no policy: flutter_test
# routes it through _runSkippedTest, which files the test under `skipped` (so
# `~N` moves and signal 5 reddens the lane) and logs its reason as
# `Skip: <reason>` WITHOUT the two-space indent the declared-reason scan anchors
# on. The manifest cannot describe one — its rows declare a runtime hatch and the
# argument for why that hatch cannot fire, which a `skip:` does not have — and no
# lane can tolerate one. What changes is only WHERE that is discovered: a
# one-second repo guard naming the file and line, rather than a twenty-minute
# E2E lane printing a bare counter and no diagnosis, because
# drive_log_failure_evidence has no declared reason to explain it with.
# ---------------------------------------------------------------------------

# A `skip:` NAMED ARGUMENT, and Dart's `@Skip(...)` library annotation.
# Deliberately not a bare `skip:`: this rule asserts an ABSENCE, so the "strip
# generously, a swallowed line only fails harder" argument used elsewhere in
# this file INVERTS — here over-matching reddens honest work. A bare `skip:`
# hits exactly two real prose false positives in the tree today
# (b7_ios_auth_tier_test.dart:67's `` `skip: true` `` inside a doc comment,
# b9_network_reconnect_test.dart:543's "Not a skip: …" mid-sentence), which is
# why the rule anchors on what PRECEDES the word rather than stripping comments
# — a comment stripper is fooled by a `//` inside a string literal.
#
# The anchor accepts every position an argument can start from: its own line,
# after the previous argument's comma, straight after the opening paren (a named
# argument BEFORE the positionals is legal Dart and really does skip the test),
# and after an interposed `/* … */` block comment. `dart format` preserves all
# four, and it preserves `skip : true` too — spacing before the colon is
# therefore tolerated rather than assumed away, because flutter-check.yml
# deliberately does NOT gate `dart format`, so an unformatted file can land and
# persist. Fixtures 41-42 and 41b-41e pin each branch; 40 pins the prose.
readonly DRIVE_LOG_STATIC_SKIP_RE='(^[[:space:]]*|[,(][[:space:]]*|\*/[[:space:]]*)skip[[:space:]]*:|(^[[:space:]]*|[,(][[:space:]]*)@Skip[[:space:]]*\('

drive_log_check_static_skips() {
  local root="${1:-${_DRIVE_LOG_LIB_DIR}/../../..}" dir hits f
  root="$(cd "${root}" 2>/dev/null && pwd)" || {
    echo "ERROR: repo root '${1:-}' is not a directory" >&2
    return 2
  }
  dir="${root}/haven/integration_test"
  if [[ ! -d "${dir}" ]]; then
    echo "ERROR: ${dir} does not exist — wrong repo root?" >&2
    return 2
  fi

  local files=()
  while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -name '*.dart' | sort)
  # The same anti-vacuity floor --check-wiring keeps: a scan over no files
  # reports a clean tree, which is the shape this whole library exists to catch.
  if (( ${#files[@]} == 0 )); then
    echo "ERROR: no .dart files under ${dir}; this check has gone blind rather" >&2
    echo "than found a clean tree." >&2
    return 2
  fi

  # NOT `|| true`: grep exits 2 when it could not READ a file, and folding that
  # into "no hits" turns an unread tree into a clean verdict — the anti-vacuity
  # floor above counts files, it never confirms they were opened (fixture 43b).
  local grc=0
  hits="$(grep -nE -- "${DRIVE_LOG_STATIC_SKIP_RE}" "${files[@]}")" || grc=$?
  if (( grc > 1 )); then
    echo "ERROR: grep could not read one or more .dart files under ${dir}" >&2
    echo "(exit ${grc}); this check has gone blind rather than found a clean" >&2
    echo "tree." >&2
    return 2
  fi
  if [[ -n "${hits}" ]]; then
    cat >&2 <<EOF

  STATIC \`skip:\` UNDER haven/integration_test/:
$(sed 's|^|    * |' <<<"${hits}")

  A statically skipped integration test never runs on ANY lane, and
  $(drive_log_skip_manifest_path)
  has no way to say so: a row there declares a runtime hatch and the argument for
  why that hatch cannot fire, and a \`skip:\` has neither. It is also the premise
  the \`~N\` rule rests on (see this file's header), so left unasserted a one-word
  edit would falsify that derivation while every static guard stayed green.

  Fix by deleting the skip and letting the test run, or — if it genuinely cannot
  run on some runtime — by converting it to a guarded markTestSkipped() and
  declaring it in that manifest with the argument for why the guard cannot fire
  in the lane that drives its target. A skip with no substitute proof is a
  deleted test wearing a disguise.
EOF
    return 1
  fi

  echo "drive-log-lib.sh --check-manifest: OK — no static \`skip:\` in" \
       "${#files[@]} .dart file(s) under haven/integration_test/, so a non-zero" \
       "\`~N\` in any drive log is a lost proof and not a declared one."
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
# The delimiter is NOT required to be a bash identifier, because bash does not
# require one: `<<END-OF-USAGE`, `<<2EOF` and `<<USAGE.TXT` all run, and an
# identifier-only rule left every such body in the code view — fixture 39's
# evasion one character apart, and the shape this check's own failure message
# invites. What must not open a heredoc is excluded by three properties of the
# scan instead, each with its own fixture:
#
#   * every candidate is ANCHORED at the `<<` that index() found, so a `<<<`
#     herestring leaves a single `<` where the delimiter would start and matches
#     nothing (39c). An unanchored search would find the herestring's word one
#     character in and treat `<<<"1.2.3"` as a heredoc.
#   * a delimiter is a word of `[A-Za-z0-9_.-]` after quote and backslash
#     removal, so `(a << 24)` — whose word is `24)` — is not one (39d), and
#     neither is a regex fragment written inside a quoted awk program.
#   * a purely numeric word is arithmetic, not a delimiter: `$(( bits << 2 ))`
#     is the same shift with a space before the paren (39d).
#
# The residue is `$(( a << NAMED ))`, which opens a heredoc that never
# terminates and so blanks the rest of the file — loud, and the same direction
# of error every other rule here takes. It is also what the identifier-only rule
# did, so nothing regressed.
#
# A terminator is matched at column 0 (leading TABs only for `<<-`), as bash
# does; a heredoc that never terminates therefore blanks the rest of the file,
# which again fails this check rather than passing it.
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
      s = line
      while ((p = index(s, "<<")) > 0) {
        tail = substr(s, p)
        s = substr(s, p + 2)
        if (!match(tail, /^<<-?[[:space:]]*[^[:space:];&|<>]+/)) continue
        d = substr(tail, 1, RLENGTH)
        tabs = (substr(d, 3, 1) == "-")
        sub(/^<<-?[[:space:]]*/, "", d)
        gsub(qcls, "", d)
        gsub(/\\/, "", d)
        if (d !~ /^[A-Za-z0-9_.-]+$/) continue
        if (d ~ /^[0-9]+$/) continue
        hd = d
        hdtabs = tabs
        break
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

# ---------------------------------------------------------------------------
# Self-test: one driver, one suite per guard.
#
# The suites and the `_dl_expect_*` assertions read `tmp`, `src`, `ran`, `fail`
# and the hermetic HAVEN_DRIVE_SKIP_MANIFEST out of drive_log_lib_self_test's
# scope through bash's dynamic scoping, so they are not callable on their own.
# They live at file scope (like every other `_drive_log_*`/`_dl_*` private here)
# rather than nested, so each guard's fixtures can be read — and mutation-tested
# — without paging past four other guards' fixtures.
# ---------------------------------------------------------------------------

# Number of assertions drive_log_lib_self_test must make. Pinned by EQUALITY,
# not by a floor: a floor lets a fixture be deleted and the suite stay green,
# which is the same "reports coverage it does not have" shape this whole library
# exists to catch. Change it only in the commit that adds or removes a fixture.
readonly DRIVE_LOG_SELF_TEST_FIXTURES=77

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
# <want-ere> empty means "must print NOTHING": drive_log_failure_evidence is the
# only diagnosis a lane prints when the predicate fires, and a version that
# prints nothing at all satisfies every rc-based fixture in this file.
_dl_expect_evidence() { # <label> <logfile> <want-ere|"">
  local got
  ran=$(( ran + 1 ))
  got="$(drive_log_failure_evidence "$2" 2>&1)"
  if [[ -z "$3" ]]; then
    if [[ -n "${got}" ]]; then
      echo "SELF-TEST FAIL ($1): expected no evidence, got: ${got}" >&2
      fail=1
    fi
  elif ! grep -qE -- "$3" <<<"${got}"; then
    echo "SELF-TEST FAIL ($1): evidence did not carry /$3/; got: ${got}" >&2
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
_dl_expect_static_rc() { # <label> <want-rc> <repo-root>
  local got=0
  ran=$(( ran + 1 ))
  drive_log_check_static_skips "$3" >/dev/null 2>&1 || got=$?
  if [[ "${got}" -ne "$2" ]]; then
    echo "SELF-TEST FAIL ($1): --check-static-skips want rc=$2, got rc=${got}" >&2
    fail=1
  fi
}
_dl_expect_gate_rc() { # <label> <want-rc> <manifest> <repo-root>
  local got=0
  ran=$(( ran + 1 ))
  HAVEN_DRIVE_SKIP_MANIFEST="$3" bash "${BASH_SOURCE[0]}" --check-manifest "$4" \
    >/dev/null 2>&1 || got=$?
  if [[ "${got}" -ne "$2" ]]; then
    echo "SELF-TEST FAIL ($1): --check-manifest gate want rc=$2, got rc=${got}" >&2
    fail=1
  fi
}

# ---------------------------------------------------------------------------
# Suite 1: the drive-log predicate and the declared-reason scan.
# ---------------------------------------------------------------------------
_dl_suite_predicate() {
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

  # (1b) The summary line ALONE, with no counter line to corroborate it. The
  #      header calls `Some tests failed.` an INDEPENDENT signal, and until this
  #      fixture nothing held it to that: every other failing log here also
  #      carries a `-N` counter, so deleting the summary rule outright left the
  #      whole suite green. Realistic on Android, where logcat's ring buffer
  #      drops intermediate lines under load and the summary is what survives.
  printf '%s\n' \
    'I/flutter ( 3849): 00:03 +1: scenario A' \
    'I/flutter ( 3849): Some tests failed.' \
    > "${tmp}/summary-only.log"
  _dl_expect_fail 1b "${tmp}/summary-only.log"

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

  # (3b) tearDownAll, which the header names alongside setUpAll and which no
  #      fixture held to it: fixture 1 covers setUpAll and every other failing
  #      log here carries a counter or a summary, so narrowing the rule to
  #      `(setUpAll)` alone left the suite green. The shape is real and it is
  #      the harder one — `_onError` prints the progress line BEFORE filing the
  #      failure, so that line carries no `-N`, and a timeout that then kills
  #      the drive leaves no `_onDone` and therefore no summary either. What
  #      remains on disk is the marker, and only the marker.
  printf '%s\n' \
    'I/flutter ( 3849): 00:13 +3: (tearDownAll) [E]' \
    'I/flutter ( 3849):   relay teardown threw StateError' \
    'All tests passed.' \
    > "${tmp}/teardownall.log"
  _dl_expect_fail 3b "${tmp}/teardownall.log"

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
  #     Guards the `-[1-9]` counter rule against ordinary prose. The `[1-9]`
  #     itself cannot be pinned against widening to `[0-9]`: neither reporter
  #     ever emits `-0` or `~0` (both columns are built only when non-zero), so
  #     no log distinguishes the two rules. Said here rather than left to read
  #     as a guarded branch.
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

  # (8b) The same truncation on the SKIPPED counter, which had no fixture: the
  #      `~N` rule carries its own end-of-line terminator and fixture 8 only
  #      pins the failure rule's. Deleting the `|$` from the `~N` alternative
  #      left every other fixture green — including 11, whose line ends in a
  #      colon. A timeout kills a drive at an arbitrary byte, so the counter it
  #      truncates is whichever one was being written.
  printf 'I/flutter ( 3849): 02:10 +7 ~2' > "${tmp}/truncated-skip.log"
  _dl_expect_fail 8b "${tmp}/truncated-skip.log"

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
  #      Pins that OUTCOME, but not the failure rule's `( ~[0-9]+)?` tolerance
  #      itself: the `~N` rule matches this same line, so deleting the tolerance
  #      keeps this fixture green. Nothing can pin it, because the reporter emits
  #      the column only when something skipped — a `+3 ~0 -2:` line does not
  #      exist. Kept as redundancy against a reporter change, and said so here
  #      rather than left to read as a guarded branch.
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
  #      can fire (tooling/e2e/expected_drive_skips.txt), and no static `skip:`
  #      can be added to the tree (drive_log_check_static_skips, fixtures 40-43b).
  #      So no honest run has a skipped column, and a run that does has lost a
  #      proof.
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
  #      14 of the 23 declared hatches would stop being recognised — and the
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
  #      DOES move `~N` — so the end-to-end assertion is checked first...
  printf '%s\n' \
    '00:01 +0: probe group beta' \
    '  Keyring unavailable on this runner (StateError); skipping BETA-1.' \
    '00:01 +0 ~1: probe group beta' \
    > "${tmp}/hostskip.log"
  _dl_expect_fail 15 "${tmp}/hostskip.log"

  # (15b) ...and then the REASON half is pinned on its own, because fixture 15
  #       cannot see it. `~1` on that log satisfies the counter rule by itself,
  #       so 15 stays green even with the `(^|...)` start-of-line branch of the
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

  # (18) ...and rc 2 must NOT be a lane failure. That shape is exactly a launch
  #      stall, which ios-flake-lib.sh classifies as retryable by asking this
  #      predicate; folding rc 2 in would make every iOS retry impossible.
  _dl_expect_clean 18 "${tmp}/noreporter.log"

  # (19) A missing manifest is "cannot judge", never "clean". The build is
  #      turned red for that by --check-manifest, which is the right place: an
  #      E2E lane must not be what discovers a deleted file in the repo. The
  #      neighbouring branch — a manifest that EXISTS but that awk cannot open —
  #      cannot be pinned separately: awk's own failure leaves the alternation
  #      empty, which the same `[[ -n "${re}" ]]` test already reports as rc 2.
  #      There is one outcome, so there is one fixture.
  _dl_expect_scan_rc 19 2 "${tmp}/driveskip.log" "${tmp}/no-such-manifest.txt"
}

# ---------------------------------------------------------------------------
# Suite 2: the evidence dump, which nine runners print and nothing asserted.
#
# It is the ONLY diagnosis a lane emits when the predicate fires, and it is
# invisible to every rc-based fixture above: "print nothing at all" and "drop
# the skip-reason dump, keep the failure lines" both left the whole suite green
# while leaving a red lane with a bare exit code and no cause.
# ---------------------------------------------------------------------------
_dl_suite_evidence() {
  # (19b) The matched failure line is quoted back. Without it a lane says only
  #       that the app reported a failure, never which line said so.
  _dl_expect_evidence 19b "${tmp}/setupall.log" '\(setUpAll\) \[E\]'

  # (19c) The SKIP branch, which is a separate dump behind its own rc test: the
  #       reason line, and the reconciliation instructions naming the manifest.
  #       A drive-lane skip has no counter and no summary, so this text is the
  #       entire explanation of why the lane went red.
  _dl_expect_evidence 19c "${tmp}/driveskip.log" \
    'alpha needs an Android emulator'
  _dl_expect_evidence 19c2 "${tmp}/driveskip.log" 'A TEST SKIPPED'

  # (19d) An honest log produces NO evidence. A dump that printed unconditionally
  #       would bury the real diagnosis in every passing lane's output.
  _dl_expect_evidence 19d "${tmp}/clean.log" ''
}

# ---------------------------------------------------------------------------
# Suite 3: the source tree against the manifest.
# ---------------------------------------------------------------------------
_dl_suite_manifest() {
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
  #      call shapes parsed. Also the only thing pinning the manifest parser's
  #      comment/blank-line skip — manifest.ok opens with both, and without that
  #      skip each would fail the two-field check and turn this rc 2.
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

  # (24) A duplicate ROW is a manifest error, not a lenient allowance: two rows
  #      for one call site means one of them can never go stale.
  cat "${tmp}/manifest.ok" "${tmp}/manifest.ok" > "${tmp}/manifest.dup"
  _dl_expect_manifest_rc 24 2 "${tmp}/manifest.dup" "${tmp}/repo"

  # (24b) A duplicate CALL SITE — the mirror image, and a different branch:
  #       fixture 24 trips the manifest parser, this trips the count comparison
  #       after the pairing. One declared row cannot hold two hatches to
  #       account; delete the second one's guard and the row still matches, so
  #       nothing else here notices. Deleting the DUPLICATE CALL SITE report
  #       turned this rc 0 with every other fixture green.
  cat > "${src}/dup_test.dart" <<'DART'
void main() {
  testWidgets('theta one', (tester) async {
    markTestSkipped('theta is unavailable on this runtime.');
  });
  testWidgets('theta two', (tester) async {
    markTestSkipped('theta is unavailable on this runtime.');
  });
}
DART
  cat "${tmp}/manifest.ok" > "${tmp}/manifest.dupcall"
  printf '%s\n' \
    'integration_test/dup_test.dart|theta is unavailable on this runtime.' \
    >> "${tmp}/manifest.dupcall"
  _dl_expect_manifest_rc 24b 1 "${tmp}/manifest.dupcall" "${tmp}/repo"
  rm -f "${src}/dup_test.dart"

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

  # (29b) PARSER ROT, a `|` inside a reason. `|` is the manifest's field
  #       separator, so such a row can never be written down truthfully — the
  #       reconciler would read it as a three-field line. Without the alarm the
  #       row is emitted anyway and reported as an UNDECLARED hatch (rc 1),
  #       sending the author to the manifest to add a row that cannot parse.
  cat > "${src}/pipe_test.dart" <<'DART'
void main() {
  markTestSkipped('iota is off | pending the relay fix.');
}
DART
  _dl_expect_manifest_rc 29b 2 "${tmp}/manifest.ok" "${tmp}/repo"
  rm -f "${src}/pipe_test.dart"

  # (29c) GLOB ROT in the EXTRACTOR — the same anti-vacuity floor fixtures 37
  #       and 43 keep for the other two globs, on the one glob that decides
  #       whether any hatch is seen at all. A rename or a moved directory that
  #       leaves no .dart files must report that it has gone blind; without the
  #       floor awk is handed no file operands, reads stdin, sees nothing, and
  #       every manifest row reads as a STALE DECLARATION (rc 1) rather than as
  #       a broken extractor.
  mkdir -p "${tmp}/blindrepo/haven/integration_test"
  _dl_expect_manifest_rc 29c 2 "${tmp}/manifest.ok" "${tmp}/blindrepo"

  # (29d) A COMMENTED-OUT hatch is not a hatch. Both halves of the extractor
  #       skip comments — the awk joiner and the independent `seen` count — and
  #       they must agree: drop the skip from either one and the two counts
  #       disagree, which is reported as extractor rot (rc 2). Drop it from
  #       BOTH and the commented line becomes an undeclared hatch (rc 1). Only
  #       an unmutated pair leaves this rc 0. Covers the `//` and the block-
  #       comment `*` continuation, which are separate alternatives.
  cat > "${src}/commented_test.dart" <<'DART'
void main() {
  testWidgets('iota', (tester) async {
    // markTestSkipped('iota was disabled while the relay was flaky.');
    /*
     * markTestSkipped('iota was disabled during the migration.');
     */
    expect(true, isTrue);
  });
}
DART
  _dl_expect_manifest_rc 29d 0 "${tmp}/manifest.ok" "${tmp}/repo"
  rm -f "${src}/commented_test.dart"
}

# ---------------------------------------------------------------------------
# Suite 4: the runners against the predicate.
#
# Two fixture trees, because the two ways to reach it fail differently. `_mk`
# writes one runner; every tree carries the exempt wrapper, whose presence is
# what the stale-exemption rule reads, so a tree that omits it is fixture 36's
# own case rather than an accident.
# ---------------------------------------------------------------------------
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

_dl_suite_wiring() {
  local wtree="${tmp}/wiring-ok"
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
  #      predicate only through the ios-flake-lib.sh it sources, so the three
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

  # (38) The predicate named inside a DOUBLE-QUOTED string. Fixture 34 covers
  #      the same evasion behind a `#`; deleting the `#` is all it took, and
  #      this shape is the one the failure message above actively invites — it
  #      tells authors to write prose naming the predicate and its delegate.
  #      Nothing bash would EXECUTE here consults anything.
  wtree="${tmp}/wiring-echoed"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
echo "this lane consults drive_log_reports_test_failure via run-direct.sh"
flutter drive --target="${target}" || rc=$?'
  _dl_expect_wiring_rc 38 1 "${wtree}"

  # (38b) The SINGLE-quoted branch of the same stripper, which had no fixture:
  #       the two quote characters are separate cases in the scanner and 38
  #       exercises only one. A stripper narrowed to `"` leaves this line whole
  #       and the runner reads as wired.
  wtree="${tmp}/wiring-echoed-sq"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh "
echo 'this lane consults drive_log_reports_test_failure via run-direct.sh'
flutter drive --target=\"\${target}\" || rc=\$?"
  _dl_expect_wiring_rc 38b 1 "${wtree}"

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

  # (39b) The same evasion with a delimiter that is not a bash IDENTIFIER.
  #       `<<END-OF-USAGE` runs — bash asks for a word, not an identifier — and
  #       an identifier-only rule left this body in the code view, so an
  #       unwired runner read as wired on prose the guard's own failure message
  #       tells authors to write. Fixture 39 one character apart. `<<2EOF` and
  #       `<<USAGE.TXT` are the same branch.
  wtree="${tmp}/wiring-heredoc-word"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
cat >&2 <<END-OF-USAGE
  This lane asks drive_log_reports_test_failure about the drive log, via
    readonly INNER="${script_dir}/run-direct.sh"
    bash "${INNER}" "${target}"
END-OF-USAGE
flutter drive --target="${target}" || rc=$?'
  _dl_expect_wiring_rc 39b 1 "${wtree}"

  # (39c) A `<<<` HERESTRING is a different operator and must not open a
  #       heredoc. Widening the delimiter is what makes this sharp: `<<<"1.2.3"`
  #       leaves a perfectly valid delimiter word behind the third `<`, so a
  #       scan that searched the whole line instead of anchoring each candidate
  #       at its own `<<` blanks the rest of this runner as a heredoc body and
  #       reddens an honestly wired lane.
  wtree="${tmp}/wiring-herestring"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
readonly INNER="${script_dir}/run-direct.sh"
IFS=. read -r major minor patch <<<"1.2.3"
bash "${INNER}" "${target}" || rc=$?'
  _dl_expect_wiring_rc 39c 0 "${wtree}"

  # (39d) An arithmetic `<<` must not open one either. Verbatim the shape at
  #       run-single-avd-scenario.sh:143-144 and setup-network-guard.sh:411,
  #       including the CONTINUATION line — whose own text carries no `$((`, so
  #       nothing on it says "arithmetic" except the operand itself. Two rules
  #       share the work and both are pinned here: `24)` and `8)` are rejected
  #       as words (a `)` is not part of a delimiter), while the space-separated
  #       `<< 2` is rejected only for being purely numeric.
  wtree="${tmp}/wiring-arith"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
readonly INNER="${script_dir}/run-direct.sh"
ip=$(( (a << 24) | (b << 16) \
     | (c << 8)  | d ))
shift=$(( bits << 2 ))
bash "${INNER}" "${target}" "${ip}" || rc=$?'
  _dl_expect_wiring_rc 39d 0 "${wtree}"

  # (39e) A QUOTED delimiter. Bash strips the quotes before matching the
  #       terminator, and so must this — ten of the real heredocs in this
  #       directory are written with a single-quoted delimiter, which is the
  #       same gsub. Without it the delimiter keeps its quotes, fails the word
  #       test, and the body is credited as code.
  wtree="${tmp}/wiring-heredoc-quoted"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
cat >&2 <<"EOF"
  This lane asks drive_log_reports_test_failure about the drive log, via
    readonly INNER="${script_dir}/run-direct.sh"
    bash "${INNER}" "${target}"
EOF
flutter drive --target="${target}" || rc=$?'
  _dl_expect_wiring_rc 39e 1 "${wtree}"

  # (39f) ...and the TERMINATOR must actually end the body, which every fixture
  #       above is blind to: they all expect rc 1, and a heredoc that never
  #       terminates blanks the rest of the file and yields rc 1 for the wrong
  #       reason. Here the real wiring sits AFTER the usage block, so a
  #       terminator rule that stopped matching swallows it and reddens an
  #       honest runner.
  wtree="${tmp}/wiring-heredoc-closed"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
cat >&2 <<EOF
  usage: run-delegating.sh <target>
EOF
readonly INNER="${script_dir}/run-direct.sh"
bash "${INNER}" "${target}" || rc=$?'
  _dl_expect_wiring_rc 39f 0 "${wtree}"

  # (39g) A TRAILING ` # ` comment naming the predicate. Full-line comments are
  #       fixture 34; this is the other sub, and deleting it credits a runner
  #       whose only mention of the predicate is an annotation on a line that
  #       calls something else.
  wtree="${tmp}/wiring-trailing-comment"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
flutter drive --target="${target}" || rc=$?  # asks drive_log_reports_test_failure via run-direct.sh'
  _dl_expect_wiring_rc 39g 1 "${wtree}"

  # (39h) ...and the reason that sub demands whitespace on BOTH sides of the
  #       `#`: `${var#word}` is a parameter expansion, not a comment. A general
  #       `#.*$` stripper truncates this assignment past the `.sh`, the edge
  #       stops being recognised, and a delegating runner reddens.
  wtree="${tmp}/wiring-param-expansion"
  _dl_mk_tree_a "${wtree}"
  _dl_mk_runner "${wtree}" run-delegating.sh '
readonly INNER="${script_dir#./}/run-direct.sh"
bash "${INNER}" "${target}" || rc=$?'
  _dl_expect_wiring_rc 39h 0 "${wtree}"

  # (39i) MUTUAL DELEGATION. Two runners that invoke each other and neither
  #       asks the predicate are UNREACHED, not an infinite descent. Note the
  #       mutation shape: removing the `visited` guard does not return a wrong
  #       code, it HANGS — the fixture converts a silent recursion into a
  #       timed-out job.
  wtree="${tmp}/wiring-cycle"
  _dl_mk_runner "${wtree}" run-with-deadline.sh 'exec "$@"'
  _dl_mk_runner "${wtree}" run-ping.sh '
readonly INNER="${script_dir}/run-pong.sh"
bash "${INNER}" "${target}" || rc=$?'
  _dl_mk_runner "${wtree}" run-pong.sh '
readonly INNER="${script_dir}/run-ping.sh"
bash "${INNER}" "${target}" || rc=$?'
  _dl_expect_wiring_rc 39i 1 "${wtree}"
}

# ---------------------------------------------------------------------------
# Suite 5: the static-skip half — the premise signal 5 rests on. Reuses
# ${tmp}/repo, whose two targets carry markTestSkipped() and no `skip:`, so the
# clean case is a real tree rather than an empty one.
# ---------------------------------------------------------------------------
_dl_suite_static() {
  # (40) CLEAN, and clean for the right reason. The lookalikes are the exact
  #      shapes already in the real tree — b7's `` `skip: true` `` inside a doc
  #      comment, b9's "Not a skip: ..." mid-sentence — plus a `'skip':` map key.
  #      A rule that dropped the anchor and matched a bare `skip:` would pass
  #      every other fixture here and redden two honest targets in CI, which is
  #      the inverse mistake and the worse one.
  cat > "${src}/lookalike_test.dart" <<'DART'
/// Without them a `skip: true`, a markTestSkipped or an early return would
/// leave the lane green.
void main() {
  // Not a skip: the lane's workflow sets HAVEN_LIVE_SYNC=true.
  final flags = <String, bool>{'skip': false};
  testWidgets('lookalike', (tester) async {
    expect(flags['skip'], isFalse);
  });
}
DART
  _dl_expect_static_rc 40 0 "${tmp}/repo"

  # (41) THE CRITICAL FIXTURE for this half — `skip:` opening its own line, the
  #      shape a formatter produces for a multi-line testWidgets call. This test
  #      runs nowhere, on any lane, and --check-manifest is blind to it.
  cat > "${src}/static_skip_test.dart" <<'DART'
void main() {
  testWidgets(
    'delta',
    (tester) async {},
    skip: true,
  );
}
DART
  _dl_expect_static_rc 41 1 "${tmp}/repo"
  rm -f "${src}/static_skip_test.dart"

  # (41b) A named argument BEFORE the positionals. Legal Dart, really skips the
  #       test, and `dart format` leaves it exactly where it is — so an anchor
  #       accepting only line-start and post-comma positions misses a live
  #       static skip that can land and persist.
  cat > "${src}/static_skip_first_test.dart" <<'DART'
void main() {
  testWidgets(skip: true, 'delta first', (tester) async {});
}
DART
  _dl_expect_static_rc 41b 1 "${tmp}/repo"
  rm -f "${src}/static_skip_first_test.dart"

  # (41c) A `/* ... */` block comment interposed between the comma and the
  #       argument — again format-stable, and again invisible to a post-comma
  #       anchor.
  cat > "${src}/static_skip_blockcomment_test.dart" <<'DART'
void main() {
  testWidgets('delta blocked', (tester) async {}, /* flaky */ skip: true);
}
DART
  _dl_expect_static_rc 41c 1 "${tmp}/repo"
  rm -f "${src}/static_skip_blockcomment_test.dart"

  # (41d) Whitespace before the colon. `dart format` would close it up, but
  #       flutter-check.yml deliberately does NOT gate `dart format`, so an
  #       unformatted file lands and stays — the rule cannot assume the
  #       formatter ran.
  cat > "${src}/static_skip_spaced_test.dart" <<'DART'
void main() {
  testWidgets('delta spaced', (tester) async {}, skip : true);
}
DART
  _dl_expect_static_rc 41d 1 "${tmp}/repo"
  rm -f "${src}/static_skip_spaced_test.dart"

  # (41e) `@Skip(...)`, the LIBRARY-level annotation, which skips every test in
  #       the file at once and shares no syntax with the named argument. The
  #       biggest possible loss of proof through the smallest possible edit.
  cat > "${src}/static_skip_annotation_test.dart" <<'DART'
@Skip('waiting on the relay fix')
library;

void main() {
  testWidgets('delta annotated', (tester) async {});
}
DART
  _dl_expect_static_rc 41e 1 "${tmp}/repo"
  rm -f "${src}/static_skip_annotation_test.dart"

  # (42) The INLINE form, after the previous argument's comma — a separate
  #      branch of the anchor, and the one both real static skips under
  #      haven/test/ are written in. Without its own fixture, deleting that
  #      branch would keep 41 green.
  cat > "${src}/static_skip_inline_test.dart" <<'DART'
void main() {
  group('epsilon', skip: 'flaky on CI', () {
    testWidgets('inner', (tester) async {});
  });
}
DART
  _dl_expect_static_rc 42 1 "${tmp}/repo"
  rm -f "${src}/static_skip_inline_test.dart" "${src}/lookalike_test.dart"

  # (43) GLOB ROT. An absence check over an empty file set reports a clean tree
  #      — the vacuous pass this library exists to catch, and the same floor
  #      fixture 37 keeps for the runner glob. rc 2, because no source edit
  #      fixes it.
  mkdir -p "${tmp}/blind/haven/integration_test"
  _dl_expect_static_rc 43 2 "${tmp}/blind"

  # (43b) ...and the floor counts FILES, it never confirms they were read. Here
  #       the glob is full, one entry cannot be opened, and a real static skip
  #       sits in the file next to it. `grep ... || true` folded grep's rc 2
  #       into "no hits" and reported the tree CLEAN — a guard that passes
  #       because it read nothing. The unreadable entry is a directory named
  #       `*.dart`, which stands in for any unopenable path and needs no
  #       permission bits to reproduce as any user.
  local btree="${tmp}/unreadable/haven/integration_test"
  mkdir -p "${btree}/opaque_test.dart"
  cat > "${btree}/real_skip_test.dart" <<'DART'
void main() {
  testWidgets('zeta', (tester) async {}, skip: true);
}
DART
  _dl_expect_static_rc 43b 2 "${tmp}/unreadable"
}

# ---------------------------------------------------------------------------
# Suite 6: the DISPATCHER, not the functions. repo-guards.yml runs
# `--check-manifest` and nothing else, so a half that is not composed into it is
# a dead guard — and every fixture above calls its half directly, which is
# exactly how a dropped composition stays green. Same defect class as
# --check-wiring's: the check exists, and nothing asks it anything.
#
# HAVEN_DRIVE_SKIP_MANIFEST must be passed through the ENVIRONMENT here: the
# self-test's binding is `local`, so a subprocess would otherwise reconcile
# these fixture trees against the repo's real manifest.
# ---------------------------------------------------------------------------
_dl_suite_dispatcher() {
  local gtree="${tmp}/gate"
  _dl_mk_tree_a "${gtree}"
  mkdir -p "${gtree}/haven/integration_test"
  printf '# no hatches declared\n' > "${tmp}/manifest.gate"
  cat > "${gtree}/haven/integration_test/delta_test.dart" <<'DART'
void main() {
  testWidgets('delta', (tester) async {});
}
DART

  # (44) All three halves clean. Without this the three below would also pass a
  #      gate that returned 1 unconditionally.
  _dl_expect_gate_rc 44 0 "${tmp}/manifest.gate" "${gtree}"

  # (45) The static-skip half reaches the gate.
  cat > "${gtree}/haven/integration_test/eps_test.dart" <<'DART'
void main() {
  testWidgets('eps', (tester) async {}, skip: true);
}
DART
  _dl_expect_gate_rc 45 1 "${tmp}/manifest.gate" "${gtree}"
  rm -f "${gtree}/haven/integration_test/eps_test.dart"

  # (46) ...and so does the manifest-reconciliation half.
  cat > "${gtree}/haven/integration_test/zeta_test.dart" <<'DART'
void main() {
  testWidgets('zeta', (tester) async {
    markTestSkipped('undeclared hatch.');
  });
}
DART
  _dl_expect_gate_rc 46 1 "${tmp}/manifest.gate" "${gtree}"
  rm -f "${gtree}/haven/integration_test/zeta_test.dart"

  # (47) ...and so does the wiring half.
  _dl_mk_runner "${gtree}" run-delegating.sh '
flutter drive --target="${target}" || rc=$?'
  _dl_expect_gate_rc 47 1 "${tmp}/manifest.gate" "${gtree}"

  # (47b) THE WORSE CODE WINS, when the worse one comes LAST. An undeclared
  #       hatch (rc 1) and, after it in the loop, a broken guard (rc 2 — the
  #       exempt wrapper is gone, so --check-wiring can no longer see its own
  #       glob). No fixture used to expect rc 2 at all, so `break` on the first
  #       failure, first-nonzero-wins and clamping to 0/1 were all indistinguish-
  #       able from the shipped rule — and each of them reports a BROKEN guard
  #       as a mere violation, which is the one distinction the loop exists for.
  local wtree="${tmp}/gate-worse-last"
  _dl_mk_tree_a "${wtree}"
  rm -f "${wtree}/tooling/e2e/ci/run-with-deadline.sh"
  mkdir -p "${wtree}/haven/integration_test"
  cat > "${wtree}/haven/integration_test/eta_test.dart" <<'DART'
void main() {
  testWidgets('eta', (tester) async {
    markTestSkipped('undeclared hatch.');
  });
}
DART
  _dl_expect_gate_rc 47b 2 "${tmp}/manifest.gate" "${wtree}"

  # (47c) ...and when the worse one comes FIRST: an unparsable manifest (rc 2)
  #       ahead of a static `skip:` (rc 1). Kills last-nonzero-wins, which 47b
  #       cannot see.
  local ftree="${tmp}/gate-worse-first"
  _dl_mk_tree_a "${ftree}"
  mkdir -p "${ftree}/haven/integration_test"
  cat > "${ftree}/haven/integration_test/theta_test.dart" <<'DART'
void main() {
  testWidgets('theta', (tester) async {}, skip: true);
}
DART
  printf '%s\n' 'integration_test/theta_test.dart|two|fields|too many' \
    > "${tmp}/manifest.unparsable"
  _dl_expect_gate_rc 47c 2 "${tmp}/manifest.unparsable" "${ftree}"
}

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

  # The Dart fixture tree suite 3 builds and suite 5 reuses, so the static-skip
  # clean case runs over real sources rather than an empty directory.
  local src="${tmp}/repo/haven/integration_test"

  _dl_suite_predicate
  _dl_suite_evidence
  _dl_suite_manifest
  _dl_suite_wiring
  _dl_suite_static
  _dl_suite_dispatcher

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
      # Every half of the manifest's contract, and ALL of them run even when an
      # earlier one fails — one red step should report every violation it can
      # see, which is repo-guards.yml's own discipline. The worse code wins, so
      # a broken guard (2) is never reported as a mere violation (1).
      rc=0
      for _check in drive_log_check_manifest \
                    drive_log_check_static_skips \
                    drive_log_check_wiring; do
        crc=0
        "${_check}" "${2:-}" || crc=$?
        if (( crc > rc )); then rc="${crc}"; fi
      done
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
