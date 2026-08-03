#!/usr/bin/env bash
# CI guard: a test that SKIPS must be declared in the checked-in manifest.
#
# ## Why this exists
#
# A skipped test contributes nothing and the run still goes green. `cargo test`
# prints `21 ignored` and exits 0; `flutter test` prints `~22` and exits 0.
# Neither number is asserted anywhere, and neither reporter names the tests, so
# a proof can stop running and the only trace is a digit nobody reads. That is
# the same failure shape the backlog calls out six times over (code that looks
# complete, passes review, and executes nowhere) — only here the code IS
# reached, right up until the gate that decides whether to run it flips.
#
# Concretely, the skips are load-bearing proofs: the real-OS-keyring twins of
# the in-memory storage tests, the live-Blossom round trips, and the pseudo-
# locale overflow sweep. Every one of them is gated on an ENVIRONMENT fact (a
# D-Bus Secret Service, a Blossom server, a generated ARB, `Platform.isAndroid`)
# rather than on anything in the diff — so the set can change from underneath a
# PR that never touched a test.
#
# The goal is NOT to make skipping impossible. Every skip in the manifest today
# is legitimate: it genuinely cannot run on a hosted runner. The goal is that
# skipping becomes a DECLARED act — you can only skip a test by writing down
# which test and why, and deleting a proof shows up as a stale manifest entry
# rather than as silence.
#
# ## What it enforces
#
#   1. Every observed skip matches a manifest entry for that surface, and the
#      entry's REASON matches verbatim. The reason is the discriminator: two
#      tests skipped from the same file for different causes are different
#      declarations, and a gate that silently changes cause (keyring -> "flaky")
#      is exactly what must not pass.
#   2. Every manifest entry is matched the number of times it declares. A stale
#      allowance is as bad as an undeclared skip — it means the proof it was
#      written for is gone and nothing noticed.
#   3. The parser self-diagnoses. For cargo, the number of `... ignored` lines
#      parsed must equal the sum of the `N ignored` fields in the `test result:`
#      summaries. A parser that silently matches nothing would otherwise turn
#      this whole guard into a vacuous pass — the eighth instance of that shape
#      in this repo (see CI_HARDENING_BACKLOG.md, "the recurring failure mode").
#
# ## What it deliberately does NOT cover
#
# `flutter drive` lanes. `integrationDriver()` reads
# `IntegrationTestWidgetsFlutterBinding.results`, and a `testWidgets` body that
# calls `markTestSkipped()` still completes normally, so the binding records
# `_success` for it — a skipped integration test is INDISTINGUISHABLE from a
# passing one on the driver side. The only signal is the `~N` column of the
# device-side reporter forwarded into the drive log (which
# `tooling/e2e/ci/drive-log-lib.sh` already tolerates but does not assert on).
# 16 of the 37 `testWidgets` under `haven/integration_test/` carry a
# `markTestSkipped` escape hatch, nearly all keyring-gated. Wiring an assertion
# there needs a run on real emulator/simulator hardware to establish which of
# them actually skip in CI, so it is left as follow-up rather than guessed at —
# guessing would turn honestly-green lanes red, which is the precise inverse
# mistake recorded in the A3b post-mortem.
#
# ## Usage
#
#   check_no_undeclared_skips.sh cargo <surface> <cargo-test-log>
#   check_no_undeclared_skips.sh dart  <surface> <dart-json-report>
#   check_no_undeclared_skips.sh --self-test
#
# `<surface>` selects the manifest rows to reconcile against: `haven-core`,
# `rust_builder` or `flutter`. Surfaces are reconciled independently so a
# haven-core entry is not reported stale while checking rust_builder.
#
# Produce the inputs with:
#   set -o pipefail; cargo test 2>&1 | tee cargo-test.log
#   flutter test --file-reporter=json:test-report.json
#
# Note that a FILTERED run (`cargo test some_name`) reports its unselected tests
# as `filtered out`, not `ignored`, so the manifest's entries go unmatched and
# the guard fails. That is intended: a partial run cannot prove the full skip
# set, so only whole-suite runs may be handed to this script.
#
# Exit codes:
#   0  every skip is declared and every declaration is live
#   1  an undeclared skip, a stale declaration, or a changed skip reason
#   2  misconfiguration (missing input, unparsable manifest, parser rot)

set -euo pipefail

SCRIPT_NAME="check_no_undeclared_skips"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_MANIFEST="${REPO_ROOT}/scripts/ci/expected_test_skips.txt"

# Resolved per invocation, NOT once at load: --self-test sets
# HAVEN_SKIP_MANIFEST around each fixture, and binding it at load time would
# silently reconcile every fixture against the REAL manifest — the self-test
# would still go red here, but the same shape in a guard is how a fixture ends
# up proving nothing.
manifest_path() {
  printf '%s\n' "${HAVEN_SKIP_MANIFEST:-${DEFAULT_MANIFEST}}"
}

log() {
  printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"
}

fail() {
  printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2
  exit 1
}

misconfig() {
  printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Extraction: cargo test
#
# libtest prints one line per test to a non-TTY, `test <name> ... ignored` with
# an optional `, <reason>` tail carrying the `#[ignore = "..."]` string. Names
# are only unique WITHIN a test binary, so each is qualified with the target
# cargo announced last:
#
#   `     Running unittests src/lib.rs (target/…)`  -> `src/lib.rs::<name>`
#   `     Running tests/foo.rs (target/…)`          -> `tests/foo.rs::<name>`
#   `   Doc-tests <crate>`                          -> `doc::<name>`
#
# Doctest names embed the source line (`… ::sign (line 472)`), which churns on
# every edit above them, so the line suffix is stripped: the item path is the
# stable identity. Doctests carry no reason — ```ignore has no message — so
# their manifest reason field is empty, and the WHY lives in the manifest's
# comments.
# ---------------------------------------------------------------------------
extract_cargo_skips() {
  local logfile="$1"
  awk '
    # Order matters: the "unittests" form is a prefix of the generic one.
    /^[[:space:]]+Running unittests / {
      ctx = $0
      sub(/^[[:space:]]+Running unittests /, "", ctx)
      sub(/ \(.*$/, "", ctx)
      next
    }
    /^[[:space:]]+Running / {
      ctx = $0
      sub(/^[[:space:]]+Running /, "", ctx)
      sub(/ \(.*$/, "", ctx)
      next
    }
    /^[[:space:]]+Doc-tests / { ctx = "doc"; next }

    # Anchored on the literal " ... ignored" verdict, so a test whose NAME ends
    # in "_ignored" (there are two in haven-core) can never be miscounted.
    /^test .+ \.\.\. ignored(,.*)?$/ {
      line = $0
      sub(/^test /, "", line)
      i = index(line, " ... ignored")
      name = substr(line, 1, i - 1)
      rest = substr(line, i + length(" ... ignored"))
      reason = (substr(rest, 1, 2) == ", ") ? substr(rest, 3) : ""
      if (ctx == "doc") sub(/ \(line [0-9]+\)$/, "", name)
      printf "%s::%s\t%s\n", ctx, name, reason
      parsed++
      next
    }

    # Self-diagnosis: the summaries are an independent count of the same fact.
    /^test result:/ {
      summaries++
      if (match($0, /[0-9]+ ignored/)) declared += substr($0, RSTART, RLENGTH) + 0
    }

    END {
      if (summaries == 0) {
        print "PARSE-ERROR no `test result:` summary in the log — truncated, empty, or not a cargo test log" > "/dev/stderr"
        exit 3
      }
      if (parsed != declared) {
        printf "PARSE-ERROR parsed %d `... ignored` lines but the summaries declare %d — the extractor has rotted\n", parsed, declared > "/dev/stderr"
        exit 3
      }
    }
  ' "${logfile}"
}

# ---------------------------------------------------------------------------
# Extraction: `flutter test --file-reporter=json:<file>`
#
# The NDJSON stream carries the skip in two places: `testStart.test.metadata`
# holds `skip`/`skipReason`, and `testDone.skipped` is the authoritative verdict
# (it also covers a runtime `markTestSkipped`, which has no static metadata).
# Join on the ids, and key the suite by a path relative to the package root so
# the manifest is not pinned to a runner's checkout directory.
# ---------------------------------------------------------------------------
extract_dart_skips() {
  local reportfile="$1"
  command -v jq >/dev/null 2>&1 || misconfig "jq is required to parse the Dart JSON report"

  local out
  out="$(jq -rs '
    ( [ .[] | select(.type == "suite")     | {(.suite.id|tostring): .suite.path} ] | add // {} ) as $suites
    | ( [ .[] | select(.type == "testStart") | {(.test.id|tostring): .test} ]      | add // {} ) as $tests
    | ( [ .[] | select(.type == "done") ] | length ) as $done
    | "#done\t\($done)",
      ( [ .[] | select(.type == "testDone" and .skipped == true) ][]
        | $tests[(.testID|tostring)] as $t
        | ( $suites[($t.suiteID|tostring)] // "<unknown-suite>" ) as $abs
        # Package-relative: everything from the LAST "/test/" onwards.
        | ( ($abs | split("/test/")) as $p
            | if ($p | length) > 1 then "test/" + $p[-1] else $abs end ) as $rel
        | "\($rel)::\($t.name)\t\(($t.metadata.skipReason) // "")"
      )
  ' "${reportfile}")" || misconfig "could not parse ${reportfile} as a Dart JSON test report"

  # Self-diagnosis: a run killed mid-flight emits no terminal `done` event, and
  # its truncated skip list would look like a clean set of stale entries.
  local done_count
  done_count="$(printf '%s\n' "${out}" | awk -F'\t' '$1 == "#done" { print $2; exit }')"
  if [[ "${done_count:-0}" -lt 1 ]]; then
    misconfig "no terminal 'done' event in ${reportfile} — the test run did not finish, so its skip set is not trustworthy"
  fi
  printf '%s\n' "${out}" | grep -v '^#done	' || true
}

# ---------------------------------------------------------------------------
# Reconciliation
#
# Manifest lines are `surface|test-id|reason|count`; `#` comments and blanks are
# ignored. A test-id ending in `*` is a prefix glob and MUST state its count —
# a glob without one could quietly absorb 18 vanished tests while matching the
# 19th, i.e. reintroduce the very hole this guard closes.
#
# Exact ids win over globs so a specific declaration can carve an exception out
# of a group-wide one.
# ---------------------------------------------------------------------------
reconcile() {
  local surface="$1" manifest="$2" observed="$3"
  # Files are discriminated by FILENAME, not the usual `NR == FNR` idiom: an
  # EMPTY manifest would make that idiom mis-read the observed skips as manifest
  # rows and pass vacuously.
  awk -v surface="${surface}" -v manifest_file="${manifest}" -F'\t' '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

    # ---- pass 1: the manifest (pipe-separated, read first) ----
    FILENAME == manifest_file {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*(#|$)/) next
      nf = split(line, f, "|")
      if (nf < 3) {
        printf "MANIFEST-ERROR line %d: expected `surface|test-id|reason|count`, got: %s\n", FNR, line > "/dev/stderr"
        bad = 1
        next
      }
      if (trim(f[1]) != surface) next

      n++
      eid[n]     = f[2]
      ereason[n] = f[3]
      eglob[n]   = (eid[n] ~ /\*$/)
      if (eglob[n]) {
        eprefix[n] = substr(eid[n], 1, length(eid[n]) - 1)
        if (nf < 4 || trim(f[4]) == "") {
          printf "MANIFEST-ERROR line %d: glob entry `%s` must state an explicit count\n", FNR, eid[n] > "/dev/stderr"
          bad = 1
        }
      }
      ecount[n] = (nf >= 4 && trim(f[4]) != "") ? trim(f[4]) + 0 : 1
      if (!eglob[n]) {
        if (eid[n] in seen) {
          printf "MANIFEST-ERROR line %d: duplicate entry for `%s`\n", FNR, eid[n] > "/dev/stderr"
          bad = 1
        }
        seen[eid[n]] = n
      }
      next
    }

    # ---- pass 2: the observed skips (tab-separated) ----
    {
      if ($0 ~ /^[[:space:]]*$/) next
      id = $1; reason = $2
      obs++

      hit = 0
      if (id in seen) {
        hit = seen[id]
      } else {
        # Longest matching prefix, so nested globs stay unambiguous.
        best = 0
        for (j = 1; j <= n; j++) {
          if (!eglob[j]) continue
          if (substr(id, 1, length(eprefix[j])) != eprefix[j]) continue
          if (best == 0 || length(eprefix[j]) > length(eprefix[best])) best = j
        }
        hit = best
      }

      if (hit == 0) {
        undeclared[++u] = id "\t" reason
        next
      }
      if (ereason[hit] != reason) {
        mismatch[++m] = id "\n      declared: " ereason[hit] "\n      observed: " reason
        next
      }
      matched[hit]++
    }

    END {
      if (bad) exit 2

      fails = 0
      if (u > 0) {
        printf "\n  UNDECLARED SKIP (%d) — these tests did not run and nothing said so:\n", u > "/dev/stderr"
        for (i = 1; i <= u; i++) {
          split(undeclared[i], p, "\t")
          printf "    * %s\n      reason: %s\n", p[1], (p[2] == "" ? "(none)" : p[2]) > "/dev/stderr"
        }
        fails = 1
      }
      if (m > 0) {
        printf "\n  SKIP REASON CHANGED (%d) — the gate moved; re-confirm it is still legitimate:\n", m > "/dev/stderr"
        for (i = 1; i <= m; i++) printf "    * %s\n", mismatch[i] > "/dev/stderr"
        fails = 1
      }
      stale = 0
      for (j = 1; j <= n; j++) {
        got = (j in matched) ? matched[j] : 0
        if (got == ecount[j]) continue
        if (!stale) {
          printf "\n  STALE / DRIFTED DECLARATION — the manifest promises a skip that no longer matches:\n" > "/dev/stderr"
          stale = 1
        }
        printf "    * %s\n      declared %d, observed %d%s\n", eid[j], ecount[j], got,
               (got == 0 ? "  (does this test still exist? did it start running again?)" : "") > "/dev/stderr"
        fails = 1
      }
      printf "OBSERVED=%d\n", obs
      exit (fails ? 1 : 0)
    }
  ' "${manifest}" "${observed}"
}

run_check() {
  local kind="$1" surface="$2" input="$3"
  local manifest
  manifest="$(manifest_path)"

  [[ -f "${manifest}" ]] || misconfig "manifest not found: ${manifest}"
  [[ -f "${input}" ]] || misconfig "test output not found: ${input}"
  [[ -s "${input}" ]] || misconfig "test output is empty: ${input}"

  local observed rc=0
  observed="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${observed}'" RETURN

  case "${kind}" in
    cargo) extract_cargo_skips "${input}" > "${observed}" || rc=$? ;;
    dart)  extract_dart_skips  "${input}" > "${observed}" || rc=$? ;;
    *)     misconfig "unknown input kind '${kind}' (expected 'cargo' or 'dart')" ;;
  esac
  # awk's exit 3 is the extractor's own rot alarm — a misconfiguration, not a
  # policy violation, so it must not be reported as "a test was skipped".
  if [[ "${rc}" -ne 0 ]]; then
    misconfig "could not extract the skip list from ${input} (see above)"
  fi

  local out
  rc=0
  out="$(reconcile "${surface}" "${manifest}" "${observed}")" || rc=$?
  case "${rc}" in
    0) ;;
    2) misconfig "manifest ${manifest} is unparsable (see above)" ;;
    *) fail "undeclared or stale test skips on surface '${surface}' — see above. Declare a legitimate skip in ${manifest}; remove the entry when the test starts running again." ;;
  esac

  local observed_n
  observed_n="$(printf '%s\n' "${out}" | sed -n 's/^OBSERVED=//p')"
  log "OK: ${surface} — ${observed_n:-0} skipped test(s), all declared in $(basename "${manifest}"), no stale declarations."
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no toolchain, no repo state.
#
# Each fixture isolates ONE way the guard could be wrong. The two that matter
# most are (2) an undeclared skip appearing and (3) a declaration outliving its
# test: those are the two directions in which a proof silently evaporates.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # A cargo log covering all three target shapes: lib unittests, an integration
  # binary, and doctests (no reason, churning line numbers).
  cat > "${tmp}/cargo.ok.log" <<'EOF'
   Compiling haven-core v0.1.0
     Running unittests src/lib.rs (target/debug/deps/haven_core-89aa4c3db7f5a07d)

running 3 tests
test location::types::tests::unknown_legacy_fields_are_ignored ... ok
test profile::blossom::tests::live_round_trip_against_local_blossom ... ignored, needs a running Blossom server
test relay::manager::tests::relay_tag_malformed_single_element_ignored ... ok

test result: ok. 2 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 1.00s

     Running tests/mls_integration_tests.rs (target/debug/deps/mls_integration_tests-93bdff999faf3424)

running 1 test
test production_storage_tests::storage_encrypted_opens_successfully ... ignored, requires system keyring - run with --ignored flag

test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.01s

   Doc-tests haven_core

running 1 test
test src/nostr/mod.rs - nostr (line 25) ... ignored

test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.10s
EOF

  cat > "${tmp}/manifest.ok" <<'EOF'
# comment lines and blanks are ignored

selftest|src/lib.rs::profile::blossom::tests::live_round_trip_against_local_blossom|needs a running Blossom server
selftest|tests/mls_integration_tests.rs::production_storage_tests::storage_encrypted_opens_successfully|requires system keyring - run with --ignored flag
selftest|doc::src/nostr/mod.rs - nostr|
other-surface|src/lib.rs::not::mine|some other reason
EOF

  _case() { # _case <label> <expect-rc> <manifest> <kind> <input>
    local label="$1" want="$2" man="$3" kind="$4" input="$5" got=0
    # SUBSHELL, not a bare call: run_check exits on failure, which would abort
    # the self-test after its first negative fixture and leave the rest silently
    # unrun — a self-test that only ever proves the happy path.
    ( HAVEN_SKIP_MANIFEST="${man}" run_check "${kind}" selftest "${input}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  log "self-test: cargo surface"

  # (1) The happy path: every skip declared, every declaration live.
  _case "matching cargo log passes" 0 "${tmp}/manifest.ok" cargo "${tmp}/cargo.ok.log"

  # (2) THE CRITICAL FIXTURE — a new skip nobody declared. This is the defect:
  #     a proof stopped running and the run stayed green.
  sed 's/^test result: ok\. 2 passed; 0 failed; 1 ignored/test result: ok. 1 passed; 0 failed; 2 ignored/' \
    "${tmp}/cargo.ok.log" > "${tmp}/cargo.extra.log"
  sed -i 's#^test relay::manager::tests::relay_tag_malformed_single_element_ignored \.\.\. ok$#test relay::manager::tests::relay_tag_malformed_single_element_ignored ... ignored, newly disabled#' \
    "${tmp}/cargo.extra.log"
  _case "undeclared skip fails" 1 "${tmp}/manifest.ok" cargo "${tmp}/cargo.extra.log"

  # (3) THE OTHER CRITICAL FIXTURE — a declaration whose test is gone. A stale
  #     allowance is indistinguishable from a deleted proof.
  printf 'selftest|src/lib.rs::deleted::proof|requires system keyring - run with --ignored flag\n' \
    >> "${tmp}/manifest.ok.stale"
  cat "${tmp}/manifest.ok" "${tmp}/manifest.ok.stale" > "${tmp}/manifest.stale"
  _case "stale manifest entry fails" 1 "${tmp}/manifest.stale" cargo "${tmp}/cargo.ok.log"

  # (4) Same test, different gate. Silently accepting this would let a keyring
  #     skip become a "flaky, disabled" skip with no review.
  sed 's/needs a running Blossom server/needs a running Blossom server, honest/' \
    "${tmp}/manifest.ok" > "${tmp}/manifest.reason"
  _case "changed skip reason fails" 1 "${tmp}/manifest.reason" cargo "${tmp}/cargo.ok.log"

  # (5) Parser rot: summaries say 1 ignored, the body shows none. If the
  #     extractor ever stops matching, this guard must scream rather than pass.
  grep -v '^test src/nostr/mod.rs - nostr (line 25) \.\.\. ignored$' \
    "${tmp}/cargo.ok.log" > "${tmp}/cargo.rot.log"
  _case "extractor/summary disagreement is a misconfiguration" 2 "${tmp}/manifest.ok" cargo "${tmp}/cargo.rot.log"

  # (6) A test name ending in `_ignored` that PASSED must never be counted as a
  #     skip — fixture (1) already contains two, and (5) proves the count is
  #     cross-checked, so this asserts the specific miscount directly.
  local miscounted
  miscounted="$(extract_cargo_skips "${tmp}/cargo.ok.log" | grep -c 'relay_tag_malformed_single_element_ignored' || true)"
  if [[ "${miscounted}" -eq 0 ]]; then
    printf '  \033[1;32mPASS\033[0m a passing test named *_ignored is not read as a skip\n'
  else
    printf '  \033[1;31mFAIL\033[0m a passing test named *_ignored was read as a skip\n' >&2
    fails=1
  fi

  # (7) Empty / absent input is a misconfiguration, never a silent pass. This is
  #     the `scan-logs-for-secrets.sh exits 0 when its log is absent` shape
  #     (backlog A4) — a guard whose input vanished has proven nothing.
  : > "${tmp}/cargo.empty.log"
  _case "empty log is a misconfiguration" 2 "${tmp}/manifest.ok" cargo "${tmp}/cargo.empty.log"
  _case "missing log is a misconfiguration" 2 "${tmp}/manifest.ok" cargo "${tmp}/nope.log"

  log "self-test: dart surface"

  # A minimal but structurally faithful NDJSON report: two suites, one skipped
  # test with a per-test reason and two sharing a group-level reason.
  cat > "${tmp}/dart.ok.json" <<'EOF'
{"protocolVersion":"0.1.1","type":"start","time":0}
{"type":"suite","suite":{"id":1,"platform":"vm","path":"/home/runner/work/x/x/haven/test/providers/bg_test.dart"},"time":1}
{"type":"suite","suite":{"id":2,"platform":"vm","path":"/home/runner/work/x/x/haven/test/l10n/sweep_test.dart"},"time":2}
{"type":"testStart","test":{"id":10,"name":"Android: enable + Granted","suiteID":1,"groupIDs":[],"metadata":{"skip":true,"skipReason":"Platform.isAndroid == false on runner"},"line":1,"column":1},"time":3}
{"type":"testDone","testID":10,"result":"success","skipped":true,"hidden":false,"time":4}
{"type":"testStart","test":{"id":11,"name":"disable works everywhere","suiteID":1,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":2,"column":1},"time":5}
{"type":"testDone","testID":11,"result":"success","skipped":false,"hidden":false,"time":6}
{"type":"testStart","test":{"id":20,"name":"sweep PageA does not overflow","suiteID":2,"groupIDs":[],"metadata":{"skip":true,"skipReason":"arb absent"},"line":3,"column":1},"time":7}
{"type":"testDone","testID":20,"result":"success","skipped":true,"hidden":false,"time":8}
{"type":"testStart","test":{"id":21,"name":"sweep PageB does not overflow","suiteID":2,"groupIDs":[],"metadata":{"skip":true,"skipReason":"arb absent"},"line":4,"column":1},"time":9}
{"type":"testDone","testID":21,"result":"success","skipped":true,"hidden":false,"time":10}
{"type":"done","success":true,"time":11}
EOF

  cat > "${tmp}/manifest.dart" <<'EOF'
selftest|test/providers/bg_test.dart::Android: enable + Granted|Platform.isAndroid == false on runner
selftest|test/l10n/sweep_test.dart::sweep *|arb absent|2
EOF

  # (8) Exact entry + counted glob reconcile a real report shape.
  _case "matching dart report passes" 0 "${tmp}/manifest.dart" dart "${tmp}/dart.ok.json"

  # (9) THE GLOB'S REASON FOR EXISTING — an entry covering N generated names
  #     must pin N. Dropping one test from the group is a vanished proof, and an
  #     uncounted glob would have absorbed it.
  grep -v '"id":21' "${tmp}/dart.ok.json" | grep -v '"testID":21' > "${tmp}/dart.short.json"
  _case "glob count drift fails" 1 "${tmp}/manifest.dart" dart "${tmp}/dart.short.json"

  # (10) A new skip inside a globbed group but gated on a DIFFERENT cause is not
  #      covered by that group's declaration.
  sed 's/"id":21,"name":"sweep PageB does not overflow","suiteID":2,"groupIDs":\[\],"metadata":{"skip":true,"skipReason":"arb absent"}/"id":21,"name":"sweep PageB does not overflow","suiteID":2,"groupIDs":[],"metadata":{"skip":true,"skipReason":"flaky, disabled"}/' \
    "${tmp}/dart.ok.json" > "${tmp}/dart.newreason.json"
  _case "new gate inside a globbed group fails" 1 "${tmp}/manifest.dart" dart "${tmp}/dart.newreason.json"

  # (11) A truncated report (killed run) must not read as "these are all stale".
  grep -v '"type":"done"' "${tmp}/dart.ok.json" > "${tmp}/dart.truncated.json"
  _case "truncated dart report is a misconfiguration" 2 "${tmp}/manifest.dart" dart "${tmp}/dart.truncated.json"

  # (12) A glob without an explicit count is a manifest error, not a lenient
  #      allowance — see the reconciliation header for why.
  printf 'selftest|test/l10n/sweep_test.dart::sweep *|arb absent\n' > "${tmp}/manifest.uncounted"
  _case "uncounted glob is a manifest error" 2 "${tmp}/manifest.uncounted" dart "${tmp}/dart.ok.json"

  if [[ "${fails}" -ne 0 ]]; then
    fail "self-test failed — this guard cannot be trusted until it is fixed"
  fi
  log "OK: self-test passed (12 fixtures)."
}

main() {
  case "${1:---help}" in
    --self-test)
      self_test
      ;;
    cargo | dart)
      [[ $# -eq 3 ]] || misconfig "usage: ${SCRIPT_NAME}.sh {cargo|dart} <surface> <test-output-file>"
      run_check "$1" "$2" "$3"
      ;;
    # Authoring aid: print `<test-id>\t<reason>` for every observed skip, which
    # is what a manifest row is made of. Keeping this in the same script as the
    # gate means the ids you paste are the ids the gate compares — a separate
    # helper would be free to drift from the checker.
    --list)
      [[ $# -eq 3 ]] || misconfig "usage: ${SCRIPT_NAME}.sh --list {cargo|dart} <test-output-file>"
      case "$2" in
        cargo) extract_cargo_skips "$3" ;;
        dart) extract_dart_skips "$3" ;;
        *) misconfig "usage: ${SCRIPT_NAME}.sh --list {cargo|dart} <test-output-file>" ;;
      esac
      ;;
    -h | --help)
      sed -n '2,90p' "${BASH_SOURCE[0]}"
      ;;
    *)
      misconfig "usage: ${SCRIPT_NAME}.sh {cargo|dart} <surface> <test-output-file> | --self-test"
      ;;
  esac
}

main "$@"
