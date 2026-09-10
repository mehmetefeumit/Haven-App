#!/usr/bin/env bash
# CI guard: the publish round-robin queue is rewound in exactly ONE place, a
# transient empty roster never re-phases it, and the tick's roster read stays a
# LOOKUP.
#
# ## The invariant, and why statement PLACEMENT is what carries it
#
# `LocationPublishSchedulerNotifier._rotation` is the round-robin queue that
# makes the multi-circle deferral service period `ceil(N / kMaxCirclesPerBurst)`
# bursts true: each tick publishes the HEAD slice and moves it to the back, so
# every circle is served in turn.
#
# Three placements decide whether that holds, and none is visible in a diff
# hunk:
#
#   1. **`_rotation.clear()` belongs to `build()`'s own body.** It used to sit
#      in `_cancelScheduling()`, so every `stopScheduling()` /
#      `startScheduling()` cycle — i.e. every background/foreground round trip —
#      REWOUND the queue to the same head. `_circles` is a `LinkedHashMap` in
#      `filterPublishEligibleCircles` order, which is `getVisibleCircles()`'s
#      `ORDER BY updated_at DESC`, so a rewind deterministically re-serves the
#      same leading slice: four one-burst runs served 11 of 13 circles, forever,
#      and the tail was never reached. A rebuild is the one event whose circles'
#      service history genuinely is not this generation's; a pause is not.
#
#      "Inside `build()`" is checked at STATEMENT level (brace depth 1 of its
#      body), not by containment, because `build()` registers closures:
#      `ref..onDispose(...)` and `ref..listen(circlesProvider, ...)` both have
#      bodies lexically inside it. A clear in the `listen` callback is textually
#      in `build()` and rewinds the queue on EVERY roster emission — strictly
#      worse than the pause rewind this guard was written for, and a
#      containment check printed OK for it while two behavioural tests failed.
#
#   2. **The survivor merge lives in `_syncCircles`' own body, BELOW the
#      `_circles.isEmpty` guard.** Hoist the `known` / `retainWhere` / append
#      block above the guard and a single emission of "nothing eligible" empties
#      the queue — and `circlesProvider` degrades EVERY `getVisibleCircles`
#      failure to `[]` by deliberate graceful degradation, so that emission is
#      as often a transient read failure as a real departure. The next healthy
#      emission then rebuilds the queue from the roster's own order: same head,
#      same first slice, tail starved again. This was the third reset path, and
#      it was undisclosed.
#
#      Both halves are required inside `_syncCircles`' brace range, at statement
#      level. Line ORDER alone said nothing about the reconciliation path:
#      deleting the merge from `_syncCircles` and parking it in a never-called
#      `_mergeSurvivors()` defined below it kept every line number in order and
#      printed OK while twenty tests failed. The `_circles.isEmpty` anchor is
#      searched inside that range for the same reason — as a first occurrence
#      in the FILE it could be any other method's empty check, and then check 2
#      compares the merge against the wrong guard.
#
#   3. **The tick reads the roster with a lookup, never `_circles[key]!`.** The
#      queue and the roster have deliberately different lifetimes (point 2: the
#      queue outlives an emptied roster), so a bang turns a designed state into
#      a crash — and not one thin burst: `JitteredScheduler._fire` swallows what
#      `onTick` throws and re-arms, so every later tick throws too, nothing
#      publishes for the rest of the foreground session, nothing is enqueued so
#      no failed-publish verdict is recorded, and the sharing-health banner
#      stays green until its silence threshold. `if (_circles[key] case final
#      circle?)` is the shape that cannot do that.
#
# The behaviour is covered by tests ("a deferred circle is not deferred again by
# every resume", "a transient empty roster emission does not re-phase whose turn
# it is", "a roster change keeps survivors' places in the queue"), so this guard
# is defence in depth. It exists because these regressions are pure REORDERS
# and one-character edits that compile, read naturally, and — before those tests
# — passed the entire suite: two separate mutations survived it. That is exactly
# the shape a grep can see and a refactor undoes.
#
# ## Why its own script
#
# `check_location_access_gate.sh` already slices this file, but its subject is
# the consent boundary (no coordinate before an access check) and this is queue
# fairness — a different invariant with a different failure mode. Same for
# `check_ios_background_publish.sh` (stream ownership) and
# `check_estimate_integrity.sh` (energy claims must not read as measurements).
# One script per invariant is the convention here, and it is what keeps each
# guard's self-test a meaningful "one fixture pair per check".
#
# ## The view: comments AND string literals stripped
#
# Every check runs over a view with full-line comments removed, trailing `//`
# comments removed, and every string literal replaced by a space. Prose
# describing the rule can then never satisfy the rule — `_onCircleTick`'s own
# comment says "A LOOKUP, not `_circles[key]!`" and must not trip check 3 — and
# a brace inside a literal cannot move a brace range. `debugPrint('}')` in
# `build()` used to collapse its range and report the CORRECT clear as outside
# it; `debugPrint('gen {')` used to widen the range past `_cancelScheduling`, so
# a clear there — the original bug verbatim — read as clean.
#
# ## What this guard cannot see
#
#   * A rewind spelled some other way (`_rotation.removeRange(0, _rotation
#     .length)`, `_rotation = []`). It pins the ONE spelling the code uses.
#   * A merge nested inside a conditional in `_syncCircles`' body: that is
#     reported as MISCONFIGURED, because the guard cannot tell a refactor from
#     an evasion and both need a human.
#   * Whether the merge is REACHED — it is placed, not traced.
#   * A bang lookup through a local alias (`final m = _circles; m[key]!`).
#
# ## Usage
#
#   check_publish_rotation_fairness.sh              # check the tree
#   check_publish_rotation_fairness.sh --self-test  # hermetic fixtures
#
# ## Exit codes
#
#   0  all three placements hold
#   1  a placement violation
#   2  misconfiguration (the file or one of its anchors is gone, or an anchor
#      moved out of the body this guard can place it in) or a failed self-test —
#      fails CLOSED, because a guard whose anchor was renamed away must say so
#      rather than certify nothing.

set -euo pipefail

readonly SCRIPT_NAME='check_publish_rotation_fairness'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly TARGET='haven/lib/src/providers/location_publish_scheduler_provider.dart'

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
bad()  { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }

# ---------------------------------------------------------------------------
# check_file <path> — 0 clean, 1 violation, 2 anchor missing / unreadable.
#
# The whole check is one awk pass: it needs brace DEPTH (to say "at statement
# level inside build()"), brace RANGES (to say "inside _syncCircles") and line
# ORDER (to say "below the guard"), none of which a grep can express.
# ---------------------------------------------------------------------------
check_file() {
  local path="$1" rc=0 scratch
  [[ -r "${path}" ]] || { bad "cannot read ${path} — the target moved, and this guard is checking nothing"; return 2; }
  # Never next to the target: a run interrupted between the write and the unlink
  # would leave a stray file inside the repository it is auditing.
  scratch="$(mktemp)"
  awk '
  function is_line_comment(s) { return s ~ /^[[:space:]]*(\/\/|\*|\/\*)/ }
  # Every quoted span becomes one space. An unterminated quote eats the rest of
  # the line, which is the right answer for a trailing comment holding an
  # apostrophe and harmless for code, where a bare quote cannot occur.
  function strip_strings(s,   out, i, c, c2, q, len) {
    out = ""; len = length(s); i = 1
    while (i <= len) {
      c = substr(s, i, 1)
      if (c == "\"" || c == "'"'"'") {
        q = c; i++
        while (i <= len) {
          c2 = substr(s, i, 1)
          if (c2 == "\\") { i += 2; continue }
          i++
          if (c2 == q) break
        }
        out = out " "
        continue
      }
      out = out c
      i++
    }
    return out
  }
  function strip(s) {
    if (is_line_comment(s)) return ""
    s = strip_strings(s)
    sub(/[[:space:]]\/\/.*$/, "", s)
    return s
  }
  # Net brace delta of s, up to (not including) column upto; upto 0 = all of it.
  function brace_delta(s, upto,   i, ch, d, lim) {
    lim = (upto > 0) ? upto - 1 : length(s)
    if (lim > length(s)) lim = length(s)
    d = 0
    for (i = 1; i <= lim; i++) {
      ch = substr(s, i, 1)
      if (ch == "{") d++
      else if (ch == "}") d--
    }
    return d
  }
  function depth_at(i, col) { return dstart[i] + brace_delta(code[i], col) }
  function depth_end(i)     { return dstart[i] + brace_delta(code[i], 0) }

  # The body `{` of a member whose parameter list opens at (line, parencol):
  # the first `{` at paren depth 0 after the list closes. Named-optional
  # parameters (`{required X x}`) live INSIDE the parens, so a "first brace"
  # scan would find one of those instead. Sets G_bline / G_bcol.
  function find_body(startline, parencol,   i, j, s, ch, pd, seen, from) {
    pd = 0; seen = 0
    for (i = startline; i <= n; i++) {
      s = code[i]
      from = (i == startline) ? parencol : 1
      for (j = from; j <= length(s); j++) {
        ch = substr(s, j, 1)
        if (ch == "(") { pd++; seen = 1; continue }
        if (ch == ")") { pd--; continue }
        if (seen && pd == 0 && ch == "{") { G_bline = i; G_bcol = j; return 1 }
        if (seen && pd == 0 && ch == ";") return 0
      }
    }
    return 0
  }
  # First line >= open whose END depth drops below the body depth.
  function body_close(open, body_depth,   i) {
    for (i = open; i <= n; i++) if (depth_end(i) < body_depth) return i
    return 0
  }

  { code[NR] = strip($0) }
  END {
    n = NR
    if (n == 0) { print "MISCONFIG\tthe file is empty"; exit 2 }

    d = 0
    for (i = 1; i <= n; i++) { dstart[i] = d; d += brace_delta(code[i], 0) }

    build_open = 0; sync_open = 0; nclears = 0; nbangs = 0
    for (i = 1; i <= n; i++) {
      # every occurrence, not just the first: two rewinds on one line are two
      # rewinds.
      pos = 1
      while (match(substr(code[i], pos), /_rotation\.clear\(\)/)) {
        nclears++; cline[nclears] = i; ccol[nclears] = pos + RSTART - 1
        pos = pos + RSTART + RLENGTH - 1
      }
      if (!build_open && match(code[i], /void[[:space:]]+build[[:space:]]*\(/)) {
        build_open = i; build_col = RSTART + RLENGTH - 1
      }
      if (!sync_open && match(code[i], /void[[:space:]]+_syncCircles[[:space:]]*\(/)) {
        sync_open = i; sync_col = RSTART + RLENGTH - 1
      }
      # `!` but not `!=`: `_circles[key] != null` is an honest null check.
      if (match(code[i], /_circles\[[^]]*\][[:space:]]*!([^=]|$)/)) { nbangs++; bline[nbangs] = i }
    }

    # --- anchors: build() ---------------------------------------------------
    if (!build_open) { print "MISCONFIG\tno `void build(` in this file — the anchor for check 1 is gone"; exit 2 }
    if (!find_body(build_open, build_col)) { print "MISCONFIG\tcould not find the body brace of build() — nothing is certified"; exit 2 }
    build_open = G_bline; build_body_depth = depth_at(G_bline, G_bcol) + 1
    build_close = body_close(build_open, build_body_depth)
    if (!build_close) { print "MISCONFIG\tcould not find the closing brace of build() — the brace scan is confused, so nothing is certified"; exit 2 }

    # --- anchors: _syncCircles ---------------------------------------------
    if (!sync_open) { print "MISCONFIG\tno `void _syncCircles(` in this file — the anchor for check 2 is gone"; exit 2 }
    if (!find_body(sync_open, sync_col)) { print "MISCONFIG\tcould not find the body brace of _syncCircles() — nothing is certified"; exit 2 }
    sync_open = G_bline; sync_body_depth = depth_at(G_bline, G_bcol) + 1
    sync_close = body_close(sync_open, sync_body_depth)
    if (!sync_close) { print "MISCONFIG\tcould not find the closing brace of _syncCircles() — the brace scan is confused, so nothing is certified"; exit 2 }

    # Statement-level anchors inside _syncCircles. A merge parked in a helper,
    # or nested in a conditional, is not found here — and that is the point.
    empty_guard = 0; retain = 0; toset = 0
    for (i = sync_open; i <= sync_close; i++) {
      if (!empty_guard && match(code[i], /if[[:space:]]*\([[:space:]]*_circles\.isEmpty/) \
        && depth_at(i, RSTART) == sync_body_depth) empty_guard = i
      if (!retain && match(code[i], /retainWhere\([[:space:]]*_circles\.containsKey/) \
        && depth_at(i, RSTART) == sync_body_depth) retain = i
      if (!toset && match(code[i], /_rotation\.toSet\(\)/) \
        && depth_at(i, RSTART) == sync_body_depth) toset = i
    }
    if (!empty_guard) { printf "MISCONFIG\tno statement-level `if (_circles.isEmpty` inside _syncCircles (lines %d-%d) — the ordering check 2 makes has no subject\n", sync_open, sync_close; exit 2 }
    if (!retain)      { printf "MISCONFIG\tno statement-level `retainWhere(_circles.containsKey` survivor merge inside _syncCircles (lines %d-%d) — a merge the reconciliation path does not run is not a merge, and check 2 has nothing to place\n", sync_open, sync_close; exit 2 }
    if (!toset)       { printf "MISCONFIG\tno statement-level `_rotation.toSet()` inside _syncCircles (lines %d-%d) — check 2 has nothing to place\n", sync_open, sync_close; exit 2 }

    # --- check 1a: exactly one rewind -------------------------------------
    if (nclears != 1) {
      printf "VIOLATION\t`_rotation.clear()` appears %d time(s); exactly ONE is allowed. Every extra site rewinds the round-robin queue to the same head, and because the roster is ordered `updated_at DESC` the same leading slice is re-served forever while the tail starves.\n", nclears
      for (k = 1; k <= nclears; k++) printf "VIOLATION\t  ... at line %d\n", cline[k]
      bad = 1
    }

    # --- check 1b: and it is a STATEMENT of build() ------------------------
    if (nclears == 1) {
      if (cline[1] < build_open || cline[1] > build_close) {
        printf "VIOLATION\t`_rotation.clear()` is at line %d, OUTSIDE build() (lines %d-%d). A rebuild is the one event whose service history is not this generation\47s; a pause, a stop or an empty roster is not, and clearing on any of those rewinds the queue.\n", cline[1], build_open, build_close
        bad = 1
      } else if (depth_at(cline[1], ccol[1]) != build_body_depth) {
        printf "VIOLATION\t`_rotation.clear()` is at line %d, nested inside build() rather than a statement of it (brace depth %d, expected %d). build() registers closures — `onDispose`, `listen(circlesProvider, ...)` — and a clear in one of them rewinds the queue on every emission it fires on, which is worse than the pause rewind this guard exists for.\n", cline[1], depth_at(cline[1], ccol[1]), build_body_depth
        bad = 1
      }
    }

    # --- check 2: the survivor merge sits BELOW the empty-roster guard -----
    if (retain < empty_guard || toset < empty_guard) {
      printf "VIOLATION\tthe survivor merge (`_rotation.toSet()` line %d, `retainWhere` line %d) is ABOVE the `_circles.isEmpty` guard at line %d in _syncCircles. `circlesProvider` degrades every roster-read failure to an empty list, so reconciling against one wipes the queue and lets the next healthy emission re-phase it from the roster order.\n", toset, retain, empty_guard
      bad = 1
    }

    # --- check 3: the tick reads the roster with a LOOKUP ------------------
    if (nbangs) {
      printf "VIOLATION\t`_circles[...]!` appears %d time(s); the roster read must stay a lookup. The queue outlives an emptied roster on purpose (check 2), so a bang makes a designed state a crash — and because `JitteredScheduler._fire` swallows what `onTick` throws and re-arms, every later tick throws too: nothing publishes for the rest of the session, no failed publish is recorded, and the banner stays green until its silence threshold. Use `if (_circles[key] case final circle?)`.\n", nbangs
      for (k = 1; k <= nbangs; k++) printf "VIOLATION\t  ... at line %d\n", bline[k]
      bad = 1
    }

    exit (bad ? 1 : 0)
  }
  ' "${path}" >"${scratch}" 2>/dev/null || rc=$?
  local out; out="$(cat "${scratch}")"; rm -f "${scratch}"
  if (( rc != 0 )); then
    while IFS=$'\t' read -r kind msg; do
      [[ -n "${msg}" ]] || continue
      bad "${msg}"
    done <<<"${out}"
  fi
  return "${rc}"
}

# ---------------------------------------------------------------------------
# --self-test: hermetic fixtures, both directions of every check.
#
# The count is pinned by EQUALITY. A printed count asserts nothing until it is
# compared, and a fixture lost to an edit or a merge would leave the suite
# reporting a pass over whatever survived.
#
# The pin is not enough on its own for the PASS direction. A fixture whose body
# was gutted still exits 0, so every want-0 fixture also asserts that the shape
# it is about is STILL IN the probe — `_case_clean` below. (The want-1 and
# want-2 fixtures are self-protecting: an empty probe is MISCONFIGURED, not
# clean.)
# ---------------------------------------------------------------------------
self_test() {
  # Bump this in the SAME commit that adds or removes an assertion.
  local -r SELF_TEST_FIXTURES=25
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _record() {
    local label="$1" want="$2" got="$3"
    checked=$(( checked + 1 ))
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  # A miniature of the real notifier: the three placements and nothing else.
  #
  # _fixture <clear-site> <merge-position> [drop-anchor] [extra]
  #   clear-site  build | listen | cancel | both | stop | empty | none
  #   merge-pos   below | above | split | helper
  #   drop-anchor build | sync | guard
  #   extra       strclose | stropen | twoempty | bang | bangneq | bangcomment
  _fixture() {
    local clear_site="$1" merge_pos="$2" drop="${3:-}" extra="${4:-}"
    local build_name='build' sync_name='_syncCircles' guard='if (_circles.isEmpty) {'
    [[ "${drop}" == 'build' ]] && build_name='rebuild'
    [[ "${drop}" == 'sync'  ]] && sync_name='_reconcile'
    [[ "${drop}" == 'guard' ]] && guard='if (false) {'
    {
      echo 'class N {'
      echo '  final List<String> _rotation = [];'
      echo '  final Map<String, Circle> _circles = {};'
      echo "  void ${build_name}() {"
      echo '    _cancelScheduling();'
      # A brace inside a literal must not move build()'"'"'s range: a `}` used to
      # close it early, a `{` used to swallow the next method.
      [[ "${extra}" == 'strclose' ]] && echo "    debugPrint('}');"
      [[ "${extra}" == 'stropen'  ]] && echo "    debugPrint('gen {');"
      [[ "${clear_site}" == 'build' ]] && echo '    _rotation.clear();'
      [[ "${clear_site}" == 'both'  ]] && echo '    _rotation.clear();'
      echo '    ref'
      echo '      ..onDispose(() {'
      echo '        _disposed = true;'
      echo '      })'
      echo '      ..listen<AsyncValue<List<Circle>>>(circlesProvider, (_, next) {'
      [[ "${clear_site}" == 'listen' ]] && echo '        _rotation.clear();'
      echo '        next.whenData((circles) => _syncCircles(circles, 1));'
      echo '      }, fireImmediately: true);'
      echo '    _active = true;'
      echo '  }'
      echo '  void _cancelScheduling() {'
      echo '    _scheduler?.cancel();'
      [[ "${clear_site}" == 'cancel' ]] && echo '    _rotation.clear();'
      [[ "${clear_site}" == 'both'   ]] && echo '    _rotation.clear();'
      echo '    // A pause must NOT call _rotation.clear() here.'
      echo '    _circles.clear();'
      echo '  }'
      # A SECOND `if (_circles.isEmpty` site, above _syncCircles: a
      # first-in-file match would compare the merge against this one.
      if [[ "${extra}" == 'twoempty' ]]; then
        echo '  void _prune() {'
        echo '    if (_circles.isEmpty) return;'
        echo '    _rotation.removeWhere(_stale);'
        echo '  }'
      fi
      echo "  void ${sync_name}(List<Circle> circles, int generation) {"
      echo '    _circles'
      echo '      ..clear()'
      echo '      ..addAll(eligible);'
      if [[ "${merge_pos}" == 'above' ]]; then
        echo '    final known = _rotation.toSet();'
        echo '    _rotation'
        echo '      ..retainWhere(_circles.containsKey)'
        echo '      ..addAll(_circles.keys.where((k) => !known.contains(k)));'
      fi
      # Half a hoist: only the snapshot moves above the guard. The queue is
      # still re-phased, because `known` is then taken from a wiped rotation.
      [[ "${merge_pos}" == 'split' ]] && echo '    final known = _rotation.toSet();'
      echo "    ${guard}"
      [[ "${clear_site}" == 'empty' ]] && echo '      _rotation.clear();'
      echo '      _scheduler = null;'
      echo '      return;'
      echo '    }'
      if [[ "${merge_pos}" == 'below' ]]; then
        echo '    final known = _rotation.toSet();'
        echo '    _rotation'
        echo '      ..retainWhere(_circles.containsKey)'
        echo '      ..addAll(_circles.keys.where((k) => !known.contains(k)));'
      fi
      echo '    _scheduler ??= JitteredScheduler();'
      if [[ "${merge_pos}" == 'split' ]]; then
        echo '    _rotation'
        echo '      ..retainWhere(_circles.containsKey)'
        echo '      ..addAll(_circles.keys.where((k) => !known.contains(k)));'
      fi
      echo '  }'
      # The merge deleted from the reconciliation path and parked in a helper
      # nothing calls, below _syncCircles so every line number stays in order.
      if [[ "${merge_pos}" == 'helper' ]]; then
        echo '  void _mergeSurvivors() {'
        echo '    final known = _rotation.toSet();'
        echo '    _rotation'
        echo '      ..retainWhere(_circles.containsKey)'
        echo '      ..addAll(_circles.keys.where((k) => !known.contains(k)));'
        echo '  }'
      fi
      echo '  void _onCircleTick(int generation) {'
      [[ "${extra}" == 'bang' ]] && echo '    final circle = _circles[key]!;'
      [[ "${extra}" == 'bangneq' ]] && echo '    if (_circles[key] != null) return;'
      if [[ "${extra}" == 'bangcomment' ]]; then
        echo '    // A LOOKUP, not `_circles[key]!`: the queue outlives the roster.'
      fi
      echo '    for (final key in _takeBurstSlice()) {'
      echo '      if (_circles[key] case final circle?) _publish(circle);'
      echo '    }'
      echo '  }'
      echo '  void stopScheduling() {'
      echo '    _active = false;'
      [[ "${clear_site}" == 'stop' ]] && echo '    _rotation.clear();'
      echo '    _cancelScheduling();'
      echo '  }'
      echo '}'
    } >"${tmp}/probe.dart"
  }

  _case() {
    local label="$1" want="$2"; shift 2
    _fixture "$@"
    local got=0
    check_file "${tmp}/probe.dart" >/dev/null 2>&1 || got=$?
    _record "${label}" "${want}" "${got}"
  }

  # A want-0 fixture, plus the assertion that keeps it non-vacuous: the shape it
  # is about must still be in the probe. An empty probe passes every check.
  _case_clean() {
    local label="$1" needle="$2"; shift 2
    _fixture "$@"
    local got=0
    check_file "${tmp}/probe.dart" >/dev/null 2>&1 || got=$?
    _record "${label}" 0 "${got}"
    got=0
    grep -qF -- "${needle}" "${tmp}/probe.dart" || got=1
    _record "${label} [the fixture still contains '${needle}']" 0 "${got}"
  }

  log 'self-test: rotation-rewind placement fixtures'

  _case_clean 'the shipped shape (clear in build, merge below the guard)' \
    '_rotation.clear();' build below
  _case_clean 'the shipped shape still carries the survivor merge' \
    'retainWhere(_circles.containsKey' build below

  _case 'clear ALSO in _cancelScheduling (the original starvation)' 1 both  below
  _case 'clear ONLY in _cancelScheduling'                          1 cancel below
  _case 'clear moved to stopScheduling'                            1 stop   below
  _case 'clear added to the _circles.isEmpty branch'               1 empty  below
  _case 'no clear anywhere (exactly-once, not at-most-once)'       1 none   below
  _case 'clear moved into the ref..listen callback inside build()'  1 listen below

  _case 'survivor merge hoisted ABOVE the empty-roster guard'      1 build  above
  _case 'only the toSet() hoisted above the guard'                 1 build  split
  _case 'merge parked in a never-called helper -> MISCONFIGURED'   2 build  helper
  _case 'a SECOND isEmpty site above _syncCircles cannot mask a hoist' \
                                                                   1 build  above '' twoempty

  _case 'a `}` in a string literal does not shrink build()' 0 build below '' strclose
  _case 'a `{` in a string literal does not widen build()'  1 cancel below '' stropen

  _case '`_circles[key]!` in the tick'                       1 build below '' bang
  _case_clean '`_circles[key] != null` is not a bang lookup' \
    '_circles[key] != null' build below '' bangneq
  _case_clean 'the comment naming the trap does not trip check 3' \
    'not `_circles[key]!`' build below '' bangcomment

  _case 'build() renamed away -> MISCONFIGURED, not clean'         2 build  below build
  _case '_syncCircles renamed away -> MISCONFIGURED, not clean'    2 build  below sync
  _case 'the isEmpty guard deleted -> MISCONFIGURED, not clean'    2 build  below guard

  local got=0
  check_file "${tmp}/does-not-exist.dart" >/dev/null 2>&1 || got=$?
  _record 'a missing target is MISCONFIGURED, not clean' 2 "${got}"

  if (( checked != SELF_TEST_FIXTURES )); then
    bad "the self-test ran ${checked} assertions; SELF_TEST_FIXTURES pins ${SELF_TEST_FIXTURES}."
    printf '  A lost fixture is a placement that has stopped being tested while the suite\n' >&2
    printf '  still reports a pass. If one was added or removed deliberately, say so in\n' >&2
    printf '  SELF_TEST_FIXTURES in the same commit.\n' >&2
    fails=1
  fi
  if (( fails )); then
    bad 'self-test failed — this guard cannot be trusted until it is fixed'
    exit 2
  fi
  log "OK: self-test passed (${checked} assertions, pinned)."
}

main() {
  if [[ "${1:-}" == '--self-test' ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || { bad "usage: ${SCRIPT_NAME}.sh [--self-test]"; exit 2; }

  local rc=0
  check_file "${REPO_ROOT}/${TARGET}" || rc=$?
  if (( rc == 0 )); then
    log 'OK: the queue is rewound only on rebuild, an empty roster leaves it standing, and the tick reads the roster with a lookup.'
  fi
  exit "${rc}"
}

main "$@"
