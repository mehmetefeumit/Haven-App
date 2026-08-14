#!/usr/bin/env bash
# CI guard: the privacy-invariant manifest must describe the repository that
# actually exists.
#
# ## Why this exists
#
# `docs/privacy/privacy_invariants.json` is the join table between what the app
# PROMISES the user (an ARB string, an iOS usage description, a consent-dialog
# sentence) and what makes that promise true (a code symbol, a test, a CI
# guard). A join table is only worth the trust placed in it while every row is
# still connected at both ends, and nothing about a JSON file resists rot: a
# test gets renamed, a guard stops being wired, a claim gets softened, a
# deviation gets accepted — and the manifest keeps asserting the world it was
# written against. The tile-cache guard sat wired into NO workflow while its
# script, its self-test and its documentation all still existed; that is the
# exact shape this file exists to fail on.
#
# The manifest also carries the one rule no reviewer reliably applies by hand:
# **you may not promise what you have accepted deviating from**, and **you may
# not silently delete a privacy warning**. Both are checked here — the first
# statically (an `accepted_deviation` invariant carrying an `assertion_arb_keys`
# entry is a contradiction on its face), the second against the merge base.
#
# CI cannot judge whether weakening a guarantee is JUSTIFIED. It can only force
# the weakening to be stated, in the diff, where review sees it: a downgrade
# fails unless the same commit names the exact item in `ratchet_override`, with
# a reason. A stale override — one naming something that is not actually
# weakened — fails too, for the same reason `check_no_undeclared_skips.sh` fails
# a stale skip declaration: an allowance that outlives its cause is a proof
# nobody noticed vanishing.
#
# ## What it enforces
#
# Rules are numbered as in the schema contract, and each has its own failure
# message and its own self-test fixture:
#
#    1. invariant ids are unique and well-shaped
#    2. every cited symbol's file exists and names that symbol as a whole token
#       in CODE — comments and string literals are stripped first, so a rename
#       cannot be alibied by `// renamed from <old>` left behind in the file
#    3. every cited test is DECLARED in its cited file
#    4. ...and is not skipped: no `#[ignore]`, no Dart `skip:` on the test or
#       an enclosing group, not listed in `scripts/ci/expected_test_skips.txt`,
#       and — for `haven/integration_test/**`, which is outside that manifest's
#       reach entirely because `integrationDriver()` records a
#       `markTestSkipped` body as `_success` — no `markTestSkipped(` in it
#    5. ...and is not tautological: it asserts something, and not only
#       `assert!(true)` / `expect(true, isTrue)` — read over the body with
#       comments and string literals stripped, because commenting the
#       assertions out is THE canonical way a test gets gutted, and the word
#       `assert` survives in the comment that replaced them
#    6. every cited guard exists AND is wired in `.github/workflows/repo-guards.yml`
#       as a step that RUNS: the invocation must sit at a command position
#       inside that step's `run:` — never in a comment, never inside an echoed
#       string ("Tip: run bash scripts/ci/x.sh yourself" is not a guard) — the
#       step must not carry `continue-on-error: true`, and its `if:` must be
#       absent or the standard `!cancelled() && steps.<id>.outcome == 'success'`
#       conditional. `if: ${{ false }}` is a guard that does not run
#   6b. ...as an ENFORCING run, not merely as its own `--self-test`. Four guards
#       appear in that file only as `<script> --self-test`, with the real run in
#       `rust-check.yml` / `coverage.yml`. A self-test proves the guard's own
#       fixtures pass and says NOTHING about the repository, so citing one as
#       proof is precisely the vacuity this workstream exists to kill. Such a
#       citation must name the enforcing workflow: `path#workflow=coverage.yml`
#       — a bare `<name>.yml` under `.github/workflows/` (no directory part, no
#       `../`), which must itself be reachable from a `push`/`pull_request`
#       trigger, directly or through `workflow_call`. A manual-only workflow,
#       or a Markdown file with a fenced `bash …` block, is exactly the "does
#       not run on this PR" citation 6b exists to reject
#    7. `enforced` ⇒ at least one test or guard
#    8. `ratcheted` ⇒ a stated residual
#    9. `accepted_deviation` ⇒ resolves to a declared deviation, carries NO
#       assertion keys, and IS disclosed somewhere
#   10. every cited ARB key exists in `haven/lib/l10n/app_en.arb`
#   11. every assertion key's invariant carries a test or a guard
#   12. coverage, both directions: every `privacy*` ARB key is classified, AND
#       so is every ARB key — under any prefix — whose English value carries
#       claim language (`never`, `only you`, `encrypted`, `no one`, …). The
#       prefix sweep alone was a third short of the register: 44 of the 133
#       registered keys are `onboarding*`, `mapLocationSharing*`,
#       `locationSettings*`, `clockSkew*`, `qrCode*` — including the onboarding
#       screens where the user is actively deciding whether to trust the app —
#       so a new `onboardingWeNeverSeeYourLocation` landed unclassified and
#       green. The value sweep is what closes that; its own bound is stated
#       under "What the value sweep cannot prove" below; every
#       `non_claim_arb_keys` key exists, states a reason, and is not also
#       claimed; every non-ARB carrier key discoverable by grep (iOS
#       `NS*UsageDescription`, every `LocationDisclosureStrings` field) maps to
#       a `non_arb_claims` entry — `kind: "none"` (with a reason) for the
#       heading and the two button labels that claim nothing, and it buys
#       nothing anywhere else;
#       and a load-bearing-by-omission string does not contain the clause its
#       `forbidden_additions` bans
#   13. every event-kind construction TOKEN in production Rust is declared —
#       `Kind::Custom(N)`, a `Kind::` variant, a `Kind::` associated function
#       (`Kind::from(31337_u16)`: `impl From<u16> for Kind` is the pinned nostr
#       crate's PRIMARY constructor, not an exotic helper), a `<n>_u16.into()`
#       conversion, and the kind-implying `EventBuilder::` constructors — and
#       `pinned_dependencies.mdk_rev` equals the rev in `haven-core/Cargo.toml`
#   14. anti-vacuity floors, so a broken extractor fails loudly instead of
#       passing on an empty set
#   15. every cited document resolves: an `accepted_deviations[].source` or an
#       `invariants[].doc_anchors[]` names a file that exists, and any
#       `#fragment` names a heading that is really in it
#
# The SAME ARB key appearing as an assertion under one invariant and a
# disclosure under another is CORRECT, not double-classification: ~24 strings
# promise and warn in one paragraph, several with an `@description` saying in as
# many words not to merge the sentences back together. The only forbidden
# overlap is a key that is both claimed and declared to make no claim.
#
# ## What the value sweep cannot prove (rule 12)
#
# The value sweep keys on a PHRASE LIST (`CLAIM_LANGUAGE` below), so it catches
# the shapes Haven's copy actually uses and nothing else. A promise worded
# around every one of those phrases — "your position stays between you and your
# circle" — is still invisible to it, and no lexical rule fixes that: deciding
# whether a sentence promises something is the judgement the register exists to
# record. What the sweep buys is that the OBVIOUS wording cannot land
# unclassified, under any key name, which is what the `^privacy` prefix rule
# alone could not say. Its own vacuity is floored (`CLAIM_LANGUAGE_PER_KEYS`): if
# the list stops matching the ARB, that is a broken sweep, not a claim-free app.
#
# ## Rule 13 is necessary, not sufficient — do not read it as a closed world
#
# Source scanning cannot enumerate what Haven puts on the wire, and the manifest
# must not be read as if it could:
#
#   * kinds 445, 1059 and the 444 rumor are built OUT OF TREE, in the rev-pinned
#     `transport-nostr-peeler`, so no repo-local grep can see them and an MDK
#     bump that adds a kind is invisible here. That is the whole reason
#     `pinned_dependencies.mdk_rev` is checked against `haven-core/Cargo.toml`:
#     bumping MDK forces the manifest to be re-derived by a human, which is the
#     only mechanism in this file that can catch a new peeler-built kind;
#   * `EventBuilder::metadata` (kind 0 — the plane that publishes the display
#     name and the avatar) and `EventBuilder::delete` (kind 5) carry no kind
#     token and no number at all;
#   * three sites compute the kind at runtime, one of which builds and signs
#     (`relay/publishers.rs`, resolved across the FFI);
#   * test fixtures deliberately construct decoy kinds (446, 1), so a numeric
#     scan reports kinds that never leave a test binary.
#
# So this keys on TOKEN IDENTITY over production paths only, and a NEW TOKEN —
# not a new number — is the trigger. The authoritative closed-world send-side
# gate remains `tooling/e2e/ci/check-wire-journal.sh` against
# `tooling/e2e/wire_allowlist.json`, which observes real traffic through the
# wire proxy. This guard is the static half; it is not a substitute.
#
# Residual false negatives, stated plainly: a kind constructed only through a
# token shape not listed in `extract_kind_tokens` (a new builder helper, or a
# conversion whose receiver is a NAMED constant rather than a `u16` literal —
# `Kind::from(x)` is caught, `let k: Kind = x.into()` is not), a kind whose
# token appears only in a `#[cfg(test)]` module today
# and in production tomorrow without changing shape, and any kind added inside
# MDK at an unchanged rev. Declared tokens are NOT checked for staleness in the
# other direction — `out_of_tree:` tokens, computed kinds and read-only kinds
# have no scan hit by construction.
#
# ## Usage
#
#   check_privacy_invariants.sh                       # check the repo
#   check_privacy_invariants.sh --baseline-ref <ref>  # ratchet base (origin/main)
#   check_privacy_invariants.sh --no-ratchet          # self-test / local use
#   check_privacy_invariants.sh --self-test
#
# Bash + jq + coreutils, plus git for the ratchet and for the two self-test
# fixtures that drive it: no cargo, no Dart SDK, no Flutter. Belongs in the
# shared repo-guards job.
#
# Exit codes:
#   0  the manifest describes this repository
#   1  a violation (including every "could not read / found nothing to scan"
#      path — a guard that scans nothing has proven nothing)
#   2  the guard itself is broken or misconfigured (absent manifest, absent
#      baseline ref, unusable jq or git, a self-test that did not run every
#      fixture it declares)

set -Eeuo pipefail

SCRIPT_NAME="check_privacy_invariants"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_REL="docs/privacy/privacy_invariants.json"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# Anti-vacuity floors (rule 14), pinned at ~90% of the measured manifest
# (81 invariants · 133 ARB keys · 15 kinds · 19 guards · 156 tests · 22 doc
# refs, measured 2026-08-13). They were four times lower than that, and a floor
# four times below reality is not a floor: 60 of the 81 invariants could be
# deleted — kinds reattached, orphaned keys dumped into `non_claim_arb_keys` —
# and every one of these still passed. The ratchet already forces an override
# for any deletion, so a TIGHT floor costs a legitimate removal one extra line
# and buys the release path (which never ratchets: tags carry no base commit) a
# real bound. Raise them with the manifest; never lower one to make a diff
# green.
FLOOR_INVARIANTS=72
FLOOR_ARB_KEYS=119
FLOOR_EVENT_KINDS=13
FLOOR_GUARDS=17
FLOOR_TESTS=140
FLOOR_DOC_REFS=19

# Rule 12's value sweep. A key whose English value contains one of these
# phrases is making a privacy claim in the user's own words, whatever its name,
# and must be classified. Lower-cased substring matching, so `Never` and
# `never` are one entry. Kept deliberately literal: every phrase here is one
# Haven's copy actually uses, and each was checked against the whole ARB — all
# 34 keys it matches today are already registered, so it fires only on
# something NEW.
CLAIM_LANGUAGE=(
  'never' 'no one' 'nobody' 'only you' 'cannot see' "can't see" "we don't"
  'not stored' 'stays on your' 'encrypted' 'end-to-end' 'anonymous'
  'plaintext' 'unencrypted' 'private to' 'no tracking' 'leaves your'
  'without your' 'not shared'
)
# ...and the sweep's own anti-vacuity floors, both scale-free so they hold for
# a 6-string fixture ARB and a 535-string one alike. Haven's copy runs about
# one claim-bearing string in sixteen; requiring one in twenty-five leaves room
# to add plain UI without re-pinning, while a sweep that stopped matching (an
# emptied list, a broken extractor) fails loudly. The second floor pins the
# list itself: shortening it narrows what the sweep can see, and that is a
# coverage decision, never a tidy-up.
CLAIM_LANGUAGE_PER_KEYS=25
CLAIM_LANGUAGE_MIN_PHRASES=15

# ---------------------------------------------------------------------------
# jq plumbing. Every check re-validates the manifest rather than trusting a
# flag set once: a check driven directly by the self-test must be as fail-closed
# as one reached through main().
# ---------------------------------------------------------------------------
require_jq() {
  command -v jq >/dev/null 2>&1 || misconfig "jq is required and was not found on PATH"
}

require_git() {
  command -v git >/dev/null 2>&1 || misconfig "git is required to read the ratchet baseline \
and was not found on PATH. The ratchet is not optional; run --no-ratchet only locally."
}

jqm() { # jqm <manifest> <filter>
  local manifest="$1" filter="$2" out
  require_jq
  [[ -f "${manifest}" ]] || misconfig "manifest not found: ${manifest}"
  out="$(jq -r "${filter}" "${manifest}" 2>&1)" || misconfig \
    "could not read ${manifest} as JSON (jq: ${out})"
  printf '%s\n' "${out}"
}

# `@tsv` rows, re-delimited with a UNIT SEPARATOR. Tab is IFS-whitespace, so a
# `read` over tab-separated fields silently COLLAPSES an empty column and every
# field after it shifts left — a manifest with no `residual` would have been
# read as one with a residual. `@tsv` escapes any literal tab or newline inside
# a value, so this substitution is unambiguous.
jqm_rows() { jqm "$1" "$2" | tr '\t' '\037'; }

# Every needle of <list> that is not a whole line of <haystack>. Five copies of
# this loop had been written out by hand; a set difference is a set difference.
missing_from() { # missing_from <newline-list> <newline-haystack>
  local needle
  while IFS= read -r needle; do
    [[ -n "${needle}" ]] || continue
    grep -qxF "${needle}" <<< "$2" || printf '%s\n' "${needle}"
  done <<< "$1"
}

# ---------------------------------------------------------------------------
# Code view: source text with comments removed, and — when asked — string
# literals too.
#
# Rules 2 and 5 both ask "does this file/body still contain X", and both were
# answered over RAW text. That is the difference between a proof and its
# epitaph: gutting a cited test by commenting its assertions out leaves the
# word `assert` in the comment, and renaming a cited symbol leaves it in
# `// renamed from <old>`. Both passed.
#
# Literals are dropped for rule 5 (an `expect(` inside a fixture string is not
# an assertion) and KEPT for rule 2, because several cited symbols ARE string
# constants — `tile.openstreetmap.org` is cited precisely as the endpoint that
# must not become the default, and it lives nowhere but in a literal.
#
# This is a scanner, not a parser, and it fails CLOSED: over-stripping can only
# make a citation look unproven (a loud red a human resolves), never make a
# gutted one look proven. Rust lifetimes are the one shape it must not mistake
# for a literal, so `'` opens a char literal only in the `'x'` / `'\n'` shape
# and is otherwise passed through untouched. XML/plist files have no `//`
# comments and their payload IS text, so only `<!-- -->` is removed there; an
# unrecognised extension is passed through unchanged rather than mangled.
# ---------------------------------------------------------------------------
lang_of() { # lang_of <path>
  case "$1" in
    *.rs) printf 'rust\n' ;;
    *.dart) printf 'dart\n' ;;
    *.kt|*.kts|*.swift|*.java|*.js|*.ts|*.gradle) printf 'cstyle\n' ;;
    *.xml|*.plist|*.html) printf 'xml\n' ;;
    *) printf 'none\n' ;;
  esac
}

code_view() { # code_view <lang> [keep-strings]   (stdin -> stdout)
  awk -v lang="$1" -v keep="${2:-0}" '
    function isident(c) { return (c ~ /[A-Za-z0-9_$]/) }
    lang == "none" { print; next }
    lang == "xml" {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (st == 1) {
          p = index(substr(line, i), "-->")
          if (p == 0) { i = n + 1 } else { st = 0; i += p + 2 }
          continue
        }
        if (substr(line, i, 4) == "<!--") { st = 1; i += 4; continue }
        out = out substr(line, i, 1); i++
      }
      print out
      next
    }
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (st == 1) {                                  # inside /* … */
          p = index(substr(line, i), "*/")
          if (p == 0) { i = n + 1 } else { st = 0; i += p + 1 }
          continue
        }
        if (st == 2) {                                  # inside a string literal
          c = substr(line, i, 1)
          if (!raw && c == "\\") { if (keep) out = out substr(line, i, 2); i += 2; continue }
          if (substr(line, i, length(q)) == q) {
            if (keep) out = out q
            st = 0; i += length(q); continue
          }
          if (keep) out = out c
          i++
          continue
        }
        c = substr(line, i, 1); d = substr(line, i, 2)
        if (d == "//") break                            # rest of the line is a comment
        if (d == "/*") { st = 1; i += 2; continue }
        # A raw-string prefix: Rust r"…" / r#"…"#, Dart r"…" / r'"'"'…'"'"'.
        if (c == "r" && (i == 1 || !isident(substr(line, i - 1, 1)))) {
          j = i + 1; h = ""
          while (substr(line, j, 1) == "#") { h = h "#"; j++ }
          qc = substr(line, j, 1)
          if (qc == "\"" || (lang == "dart" && qc == "'"'"'")) {
            raw = 1; q = qc h; st = 2
            out = out (keep ? substr(line, i, j - i + 1) : " ")
            i = j + 1
            continue
          }
        }
        if (c == "\"" || (lang == "dart" && c == "'"'"'")) {
          raw = 0
          q = (substr(line, i, 3) == c c c) ? c c c : c
          st = 2; out = out (keep ? q : " "); i += length(q)
          continue
        }
        # A CHAR literal, never a lifetime: `'"'"'x'"'"'`, `'"'"'\n'"'"'`.
        if (lang != "dart" && c == "'"'"'" && substr(line, i) ~ /^'"'"'(\\.|[^\\'"'"'])'"'"'/) {
          w = (substr(line, i + 1, 1) == "\\") ? 4 : 3
          out = out (keep ? substr(line, i, w) : " ")
          i += w
          continue
        }
        out = out c; i++
      }
      print out
    }
  '
}

# ---------------------------------------------------------------------------
# Rust source reader.
#
# `fn` bodies are delimited by the closing brace at the `fn`'s own indentation:
# `cargo fmt --check` gates every Rust file in this repo, so that column is a
# guarantee, not a guess, and it costs no string/char-literal lexer to use.
#
# Emits `DECL <is-test> <is-ignored> <start> <end>` or `NOTFOUND`. The
# `#[ignore` test is anchored at the start of the line so it cannot be satisfied
# by the five PROSE comments that mention `#[ignore]` while describing a gate.
# ---------------------------------------------------------------------------
rust_scan() { # rust_scan <file> <fn-name>
  awk -v want="$2" '
    { L[NR] = $0 }
    END {
      target = 0
      pat = "(^|[^A-Za-z0-9_])fn[[:space:]]+" want "[[:space:]]*[(<]"
      for (i = 1; i <= NR; i++) if (L[i] ~ pat) { target = i; break }
      if (!target) { print "NOTFOUND"; exit 0 }

      istest = 0; ignored = 0
      for (j = target - 1; j >= 1; j--) {
        t = L[j]
        if (t ~ /^[[:space:]]*#\[/) {
          if (t ~ /^[[:space:]]*#\[[[:space:]]*ignore([[:space:]]*[]=]|$)/) ignored = 1
          if (t ~ /^[[:space:]]*#\[[[:space:]]*[a-z_:]*test[[:space:]]*[]\(]/) istest = 1
          continue
        }
        if (t ~ /^[[:space:]]*\/\//) continue
        break
      }

      match(L[target], /^[[:space:]]*/)
      ind = substr(L[target], 1, RLENGTH)
      close_pat = "^" ind "}"
      end = 0
      for (j = target + 1; j <= NR; j++) if (L[j] ~ close_pat) { end = j; break }
      if (!end) { print "NOTFOUND"; exit 0 }
      printf "DECL %d %d %d %d\n", istest, ignored, target, end
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Dart test reader.
#
# Test names are routinely split across lines with adjacent-string
# concatenation, so the name is parsed as a literal SEQUENCE rather than read
# off the declaration line. Extents use the same formatter-guaranteed
# indentation rule as the Rust reader (`dart format` is gated in CI).
#
# A candidate whose name or extent will not parse is dropped rather than
# reported: the lint tests embed whole Dart programs in `'''` fixtures, and
# those contain `test(` calls that are data, not declarations. Dropping is safe
# because the caller's verdict for a name it cannot find is FAILURE.
#
# The name emitted is the RUNTIME name — the one `flutter test` prints and a
# manifest would cite — so escapes are decoded, `Haven’s` included (a live
# example: `background_claim_accuracy_test.dart:433`, split across two literals
# AND carrying a `\u` escape). awk preserves the escape sequences and `printf
# %b` resolves them, because `%c` on a codepoint above 255 differs between gawk
# and the mawk the runners ship.
#
# Emits `<start>\t<end>\t<skipped>\t<name>` per declaration — the name LAST, so
# a name containing a tab cannot shift the numeric fields.
# ---------------------------------------------------------------------------
dart_scan() { # dart_scan <file>
  _dart_scan_raw "$1" | while IFS=$'\t' read -r start end skip name; do
    printf '%s\t%s\t%s\t%b\n' "${start}" "${end}" "${skip}" "${name}"
  done
}

_dart_scan_raw() { # _dart_scan_raw <file>
  awk '
    function isident(c) { return (c ~ /[A-Za-z0-9_$.]/) }

    function indent_of(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }

    # The call ends at the first line closing it at the indentation of the
    # DECLARATION — formatter-guaranteed, and deliberately tolerant of trailing
    # arguments on that line (`}, skip: "…");`), which is where a Dart skip
    # argument most often lives.
    function extent_end(i, ind,   j, p) {
      if (L[i] ~ /\);[[:space:]]*$/) return i
      p = "^" ind "[})][^;]*;[[:space:]]*$"
      for (j = i + 1; j <= n; j++) if (L[j] ~ p) return j
      return 0
    }

    # A `skip:` argument of THIS call and no other: the declaration line, the
    # closing line (`}, skip: "…");`), or an argument line at exactly one
    # formatter indent step in. Scanning the whole body instead would mark a
    # group skipped because ONE test inside it is, silently disqualifying every
    # sibling proof.
    function arg_skip(i, e, ind,   j) {
      if (L[i] ~ /[,(][[:space:]]*skip:/) return 1
      if (L[e] ~ /[,(][[:space:]]*skip:/) return 1
      for (j = i + 1; j < e; j++) if (L[j] ~ ("^" ind "  skip:")) return 1
      return 0
    }

    # Column just past the opening paren of a `test(` / `testWidgets(` call, or
    # 0. The preceding character must not be identifier-ish, so `_test(`,
    # `.test(` and `groupTest(` are not declarations.
    function decl_col(s,   p) {
      p = index(s, "testWidgets(")
      if (p > 0 && (p == 1 || !isident(substr(s, p - 1, 1)))) return p + 12
      p = index(s, "test(")
      if (p > 0 && (p == 1 || !isident(substr(s, p - 1, 1)))) return p + 5
      return 0
    }

    # Concatenated adjacent string literals starting at (line pl, column pc).
    # Sets NAME; returns 1 on success. Handles r-prefixes, both quote styles,
    # triple quotes and backslash escapes.
    function parse_name(pl, pc,   c, c3, raw, q, out, piece, got) {
      NAME = ""; got = 0
      while (1) {
        while (pl <= n) {
          c = substr(L[pl], pc, 1)
          if (c == "") { pl++; pc = 1; continue }
          if (c == " " || c == "\t") { pc++; continue }
          break
        }
        if (pl > n) return got
        raw = 0
        c = substr(L[pl], pc, 1)
        if (c == "r") { raw = 1; pc++; c = substr(L[pl], pc, 1) }
        if (c != "\"" && c != "'"'"'") { return got }
        c3 = substr(L[pl], pc, 3)
        q = (c3 == c c c) ? c c c : c
        pc += length(q)
        piece = ""
        while (pl <= n) {
          c = substr(L[pl], pc, 1)
          if (c == "") { piece = piece "\n"; pl++; pc = 1; continue }
          if (!raw && c == "\\") {
            c = substr(L[pl], pc + 1, 1)
            # `\n`, `\t`, `\r`, `\uXXXX` and a literal backslash are handed on
            # as escape sequences for `printf %b` to resolve; everything else
            # (`\x27`, `\"`, `\$`) is just the character it quotes.
            piece = piece ((c ~ /[ntru\\]/) ? "\\" c : c)
            pc += 2
            continue
          }
          if (substr(L[pl], pc, length(q)) == q) { pc += length(q); break }
          piece = piece c
          pc++
        }
        NAME = NAME piece
        got = 1
      }
    }

    { L[NR] = $0 }

    END {
      n = NR
      ng = 0
      for (i = 1; i <= n; i++) {
        if (L[i] !~ /(^|[^A-Za-z0-9_$.])group\(/) continue
        ind = indent_of(L[i])
        e = extent_end(i, ind)
        if (!e) continue
        if (arg_skip(i, e, ind)) { ng++; gs[ng] = i; ge[ng] = e }
      }

      for (i = 1; i <= n; i++) {
        col = decl_col(L[i])
        if (!col) continue
        ind = indent_of(L[i])
        e = extent_end(i, ind)
        if (!e) continue
        if (!parse_name(i, col)) continue
        sk = arg_skip(i, e, ind)
        for (k = 1; k <= ng; k++) if (i > gs[k] && i < ge[k]) sk = 1
        printf "%d\t%d\t%d\t%s\n", i, e, sk, NAME
      }
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Rule 2 — cited symbols exist, IN CODE.
#
# Whole-token match: `fn build_group` must NOT be satisfied by
# `fn build_group_event`, or the manifest could cite a symbol that was renamed
# into a different function. Only the final token of the citation is matched —
# every one of the 91 cited symbols is a single word today, and the "phrase"
# branch that once re-checked `fn` + name had therefore never executed in its
# life; a dead branch is a claim about coverage that isn't there.
#
# The match runs over `code_view`, not the raw file: renaming a symbol while
# leaving `// renamed from <old>` behind used to pass, which is the one residue
# a rename reliably leaves. String literals are KEPT here, because a cited
# symbol may BE a literal — `tile.openstreetmap.org` is cited precisely as the
# endpoint that must not become the default, and lives nowhere else.
#
# A doc-comment reference (`` `X` ``, `[X]`) in the cited file is NOT proof:
# two rows cited a file that only mentioned the constant while it was declared
# in `constants/`, and a row that names the wrong file cannot be re-derived
# from the tree, which is what this rule is for.
# ---------------------------------------------------------------------------
check_symbols() { # check_symbols <manifest> <root>
  local manifest="$1" root="$2" fail=0 n=0
  local inv file symbol

  while IFS=$'\037' read -r inv file symbol; do
    [[ -n "${inv}" ]] || continue
    n=$(( n + 1 ))
    if [[ ! -f "${root}/${file}" ]]; then
      fail_msg "[rule 2] ${inv}: cited symbol file does not exist: ${file}"
      fail=1
      continue
    fi
    local token="${symbol##* }" code
    # Materialised, never piped into `grep -q`: under `pipefail` the early exit
    # of a successful `grep -q` SIGPIPEs the producer, and the pipeline's
    # non-zero status would report every symbol that IS there as missing.
    code="$(code_view "$(lang_of "${file}")" 1 < "${root}/${file}")"
    if ! grep -qE "(^|[^A-Za-z0-9_])${token//./\\.}([^A-Za-z0-9_]|$)" <<< "${code}"; then
      fail_msg "[rule 2] ${inv}: '${symbol}' is not in the CODE of ${file} (comments are \
stripped first, so a comment that still names it is not proof) — the symbol moved or was \
renamed, so this row proves nothing."
      fail=1
    fi
  done < <(jqm_rows "${manifest}" '.invariants[] | .id as $i | (.symbols // [])[] | [$i, .file, .symbol] | @tsv')

  (( fail == 0 )) || return 1
  printf '  [rule 2] %d cited symbol(s) present in code.\n' "${n}"
}

# ---------------------------------------------------------------------------
# Rules 3-5 — cited tests exist, run, and assert.
#
# The skip manifest is matched on `<basename>::…::<name>`, which is how
# `check_no_undeclared_skips.sh` keys its rows: the cargo target path and the
# module path in front of the name differ from the manifest's `file` field, but
# the file's basename and the final segment do not.
#
# Rule 5 reads the body through `code_view`. It also no longer exempts
# `#[should_panic]`: no cited test has ever carried one, so the exemption was
# an untested branch standing between a gutted body and a red build. A
# panic-only test must state its expectation to be citable.
# ---------------------------------------------------------------------------
check_tests() { # check_tests <manifest> <root> <skip-manifest>
  local manifest="$1" root="$2" skips="$3" fail=0 n=0
  local inv file name

  [[ -f "${skips}" ]] || { fail_msg "[rule 4] skip manifest not found: ${skips}"; return 1; }

  while IFS=$'\037' read -r inv file name; do
    [[ -n "${inv}" ]] || continue
    n=$(( n + 1 ))
    local path="${root}/${file}"
    if [[ ! -f "${path}" ]]; then
      fail_msg "[rule 3] ${inv}: cited test file does not exist: ${file}"
      fail=1
      continue
    fi

    local body="" skipped=0
    case "${file}" in
      *.rs)
        local scan
        scan="$(rust_scan "${path}" "${name}")"
        if [[ "${scan}" == "NOTFOUND" ]]; then
          fail_msg "[rule 3] ${inv}: no test named '${name}' is declared in ${file}."
          fail=1
          continue
        fi
        local _d istest ignored start end
        read -r _d istest ignored start end <<< "${scan}"
        if [[ "${istest}" != "1" ]]; then
          fail_msg "[rule 3] ${inv}: ${file} declares 'fn ${name}' but carries no \
#[test]/#[tokio::test] attribute — it is a helper, not a proof."
          fail=1
          continue
        fi
        [[ "${ignored}" == "1" ]] && skipped=1
        body="$(sed -n "${start},${end}p" "${path}")"
        ;;
      *.dart)
        # Compared against everything past the third tab, so a name that itself
        # contains a tab is matched whole rather than truncated to its head.
        local rec
        rec="$(dart_scan "${path}" | awk -F'\t' -v want="${name}" '
          { nm = $0; sub(/^[0-9]+\t[0-9]+\t[01]\t/, "", nm)
            if (nm == want) { printf "%s\t%s\t%s\n", $1, $2, $3; exit } }')"
        if [[ -z "${rec}" ]]; then
          fail_msg "[rule 3] ${inv}: no test named '${name}' is declared in ${file} \
(names split across adjacent literals are joined and escapes resolved before matching, so \
cite the name as the test reporter prints it)."
          fail=1
          continue
        fi
        local dstart dend dskip
        dstart="$(printf '%s' "${rec}" | cut -f1)"
        dend="$(printf '%s' "${rec}" | cut -f2)"
        dskip="$(printf '%s' "${rec}" | cut -f3)"
        [[ "${dskip}" == "1" ]] && skipped=1
        body="$(sed -n "${dstart},${dend}p" "${path}")"
        ;;
      *)
        fail_msg "[rule 3] ${inv}: cited test file '${file}' is neither Rust nor Dart."
        fail=1
        continue
        ;;
    esac

    # Everything below reads the body as CODE: comments and string literals are
    # gone, so neither an escape hatch nor an assertion can be claimed by a
    # sentence that merely mentions one.
    local code
    code="$(code_view "$(lang_of "${file}")" <<< "${body}")"

    # `haven/integration_test/**` is outside the skip manifest's reach:
    # `integrationDriver()` records a body that called `markTestSkipped` as a
    # SUCCESS, so a skipped integration test is textually indistinguishable
    # from a passing one on the driver side.
    if [[ "${file}" == haven/integration_test/* ]] && grep -q 'markTestSkipped(' <<< "${code}"; then
      fail_msg "[rule 4] ${inv}: ${file}::${name} calls markTestSkipped() — the \
integration driver reports such a run as a PASS, so this citation can go green while the \
proof never executes."
      fail=1
      continue
    fi

    if (( skipped == 1 )); then
      fail_msg "[rule 4] ${inv}: ${file}::${name} is SKIPPED (#[ignore] or a skip: \
argument on the test or its group). A skipped test proves nothing; cite one that runs."
      fail=1
      continue
    fi

    local base="${file##*/}"
    if awk -F'|' -v base="${base}" -v name="${name}" '
        /^[[:space:]]*(#|$)/ { next }
        {
          id = $2
          p = index(id, "::")
          if (p == 0) next
          path = substr(id, 1, p - 1)
          sub(/.*\//, "", path)
          if (path != base) next
          seg = id
          while ((q = index(seg, "::")) > 0) seg = substr(seg, q + 2)
          if (seg == name) { found = 1; exit }
          if (seg ~ /\*$/) {
            pre = substr(seg, 1, length(seg) - 1)
            if (substr(name, 1, length(pre)) == pre) { found = 1; exit }
          }
        }
        END { exit (found ? 0 : 1) }
      ' "${skips}"; then
      fail_msg "[rule 4] ${inv}: ${file}::${name} is declared in \
$(basename "${skips}") as an expected skip — it does not run in CI, so it cannot back a \
privacy claim."
      fail=1
      continue
    fi

    local squashed
    squashed="$(tr -s ' \t' ' ' <<< "${code}")"
    local trivial
    trivial="$(sed -E 's/(prop_)?assert(_eq|_ne)?!\([[:space:]]*true[[:space:]]*(,[[:space:]]*true[[:space:]]*)?\)//g; s/expect\([[:space:]]*true[[:space:]]*,[[:space:]]*(isTrue|true)[[:space:]]*\)//g' <<< "${squashed}")"
    if ! grep -qE '(^|[^A-Za-z0-9_])(assert|prop_assert|debug_assert|panic!|expect\(|expectLater\(|fail\()' <<< "${trivial}"; then
      fail_msg "[rule 5] ${inv}: ${file}::${name} contains no non-trivial assertion in its \
CODE — a test that asserts nothing reports coverage it does not have, and a comment saying \
it used to assert is not an assertion."
      fail=1
    fi
  done < <(jqm_rows "${manifest}" '.invariants[] | .id as $i | (.tests // [])[] | [$i, .file, .name] | @tsv')

  (( fail == 0 )) || return 1
  printf '  [rules 3-5] %d cited test(s) declared, running and asserting.\n' "${n}"
}

# ---------------------------------------------------------------------------
# Rules 6 / 6b — cited guards exist and are WIRED INTO A STEP THAT RUNS.
#
# "The script's name appears in the workflow" is not wiring, and neither is
# "an invocation string appears in the workflow". All three of these passed the
# string version of this rule while the guard was dead:
#
#   * `if: ${{ false }}` on the step;
#   * `continue-on-error: true` on it — the guard runs, fails loudly, and the
#     job stays green;
#   * the step DELETED, with the only surviving mention being
#     `echo "Tip: run bash scripts/ci/check_no_tile_cache_secrets.sh yourself"`
#     in a neighbouring step. That is the orphaned-tile-cache failure verbatim,
#     reproduced past the guard whose header names it as its reason to exist.
#
# So the workflow is parsed into STEPS, and an invocation counts only when it
# is a command inside that step's `run:` — not a comment, not text inside a
# quoted string, not a heredoc body — in a step that carries no
# `continue-on-error: true` and whose `if:` is either absent or exactly the
# standard `!cancelled() && steps.<id>.outcome == 'success'` conditional every
# guard step in repo-guards.yml uses. Any other condition is reported as a
# guard that may not run, naming the condition: a citation must not depend on
# a reviewer's reading of an expression.
#
# A wiring whose every invocation carries `--self-test` is NOT enforcement: it
# proves the guard's fixtures pass and says nothing whatsoever about the
# repository. Four guards in this repo are wired exactly that way, with their
# enforcing run in another workflow; citing one requires saying so with
# `path#workflow=<file>.yml`.
# ---------------------------------------------------------------------------

# One line per invocation of <path-regex> found in a `run:` block:
# `<enforcing|selftest>\t<ok|the reason the step will not enforce>\t<step name>`.
# The regex arrives with its backslashes DOUBLED: `awk -v` resolves escape
# sequences in the value, so a single `\.` would reach the program as a bare
# `.` — a dot that matches any character — with a warning on every run.
workflow_invocations() { # workflow_invocations <workflow-file> <path-regex>
  awk -v esc="${2//\\/\\\\}" '
    function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
    function pad(k,   s) { s = ""; while (length(s) < k) s = s " "; return s }
    function value(s,   v) {
      sub(/^[[:space:]]*[A-Za-z_-]+:[[:space:]]*/, "", s)
      v = s
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      return v
    }
    # Shell text with quoted segments and comments removed, then split at every
    # command separator, so a match can be required at a command POSITION.
    function commands(text,   i, m, out, line, q, res, ch, j, nl) {
      nl = split(text, RL, "\n")
      out = ""
      for (i = 1; i <= nl; i++) {
        line = RL[i]
        if (heredoc != "") {                       # inside a <<EOF body: data, not code
          if (line ~ ("^[[:space:]]*" heredoc "[[:space:]]*$")) heredoc = ""
          continue
        }
        res = ""; q = ""
        for (j = 1; j <= length(line); j++) {
          ch = substr(line, j, 1)
          if (q != "") { if (ch == q) q = ""; continue }
          if (ch == "\"" || ch == "'"'"'") { q = ch; res = res " "; continue }
          if (ch == "#") break
          res = res ch
        }
        if (res ~ /<<-?[A-Za-z_'"'"'"]/) {
          m = res
          sub(/.*<<-?/, "", m)
          gsub(/[^A-Za-z0-9_].*/, "", m)
          if (m != "") heredoc = m
        }
        out = out "\n" res
      }
      gsub(/[;&|()]/, "\n", out)
      gsub(/(^|[ \t])(then|else|elif|do)[ \t]/, "\n", out)
      return out
    }
    { L[NR] = $0 }
    END {
      ns = 0
      for (i = 1; i <= NR; i++) {
        if (L[i] ~ /^[[:space:]]*-[[:space:]]+(name|id|uses|run|if|shell|env|with|working-directory|continue-on-error|timeout-minutes):/) {
          ns++; ss[ns] = i
          match(L[i], /^[[:space:]]*-[[:space:]]+/); ki[ns] = RLENGTH
        }
      }
      for (k = 1; k <= ns; k++) {
        start = ss[k]; stop = (k < ns ? ss[k + 1] - 1 : NR); ind = ki[k]
        cond = ""; coe = ""; stepname = "(unnamed step)"; runtext = ""; inrun = 0
        for (j = start; j <= stop; j++) {
          line = L[j]
          if (j == start) line = pad(ind) substr(line, ind + 1)
          if (inrun) {
            if (line ~ /^[[:space:]]*$/) { runtext = runtext "\n"; continue }
            if (indent(line) > ind) { runtext = runtext "\n" line; continue }
            inrun = 0
          }
          if (indent(line) != ind || line ~ /^[[:space:]]*#/) continue
          if (line ~ /^[[:space:]]*name:/) { stepname = value(line); continue }
          if (line ~ /^[[:space:]]*if:/) { cond = value(line); continue }
          if (line ~ /^[[:space:]]*continue-on-error:/) { coe = value(line); continue }
          if (line ~ /^[[:space:]]*run:/) {
            v = value(line)
            if (v ~ /^[|>]/) inrun = 1; else runtext = runtext "\n" v
            continue
          }
        }
        why = "ok"
        if (coe ~ /^(true|yes|on)$/) why = "the step is continue-on-error: true, so its failure cannot fail the job"
        else if (cond != "" && cond !~ /^\$\{\{[[:space:]]*!cancelled\(\)[[:space:]]*&&[[:space:]]*steps\.[A-Za-z0-9_-]+\.outcome[[:space:]]*==[[:space:]]*'"'"'success'"'"'[[:space:]]*\}\}$/)
          why = "the step is conditional on `" cond "`, which is not the standard guard condition"
        heredoc = ""
        cmds = commands(runtext)
        nc = split(cmds, C, "\n")
        for (c = 1; c <= nc; c++) {
          if (C[c] !~ ("^[[:space:]]*bash[[:space:]]+([^[:space:]]*/)?" esc "([[:space:]]|$|\\\\)")) continue
          kind = (C[c] ~ ("^[[:space:]]*bash[[:space:]]+([^[:space:]]*/)?" esc "[[:space:]]+--self-test[[:space:]]*$")) ? "selftest" : "enforcing"
          printf "%s\t%s\t%s\n", kind, why, stepname
        }
      }
    }
  ' "$1"
}

guard_wiring() { # guard_wiring <workflow-file> <script-path> -> none|selftest|enforcing|disabled:<why>
  # Any number of `../` steps may precede the path: the enforcing runs in
  # rust-check.yml and coverage.yml execute under a `working-directory`, so
  # they invoke the very same script as `../scripts/ci/…`.
  local hits
  hits="$(workflow_invocations "$1" "${2//./\\.}")"
  [[ -n "${hits}" ]] || { printf 'none\n'; return 0; }
  if grep -q $'^enforcing\tok\t' <<< "${hits}"; then printf 'enforcing\n'; return 0; fi
  if grep -q $'^selftest\tok\t' <<< "${hits}"; then printf 'selftest\n'; return 0; fi
  printf 'disabled:%s\n' "$(awk -F'\t' 'NR == 1 { printf "%s (step: %s)", $2, $3 }' <<< "${hits}")"
}

# A workflow only proves anything about a change if that change makes it run.
# Reusable workflows carry `on: workflow_call:` and are reached through ci.yml,
# so reachability is transitive; a `workflow_dispatch`-only workflow is not
# reachable at all, and is exactly the citation 6b exists to reject.
workflow_has_pr_trigger() { # workflow_has_pr_trigger <file>
  awk '
    /^on:[[:space:]]*\[/ { if ($0 ~ /push|pull_request/) { found = 1 }; next }
    /^on:/ { inon = 1; next }
    inon && /^[A-Za-z_]/ { inon = 0 }
    inon && /^[[:space:]]+(push|pull_request):/ { found = 1 }
    END { exit (found ? 0 : 1) }
  ' "$1"
}

workflow_pr_reachable() { # workflow_pr_reachable <workflows-dir> <file-name>
  local dir="$1" frontier="$2" seen="" next f caller
  while [[ -n "${frontier}" ]]; do
    next=""
    while IFS= read -r f; do
      [[ -n "${f}" ]] || continue
      grep -qxF "${f}" <<< "${seen}" && continue
      seen+="${f}"$'\n'
      [[ -f "${dir}/${f}" ]] || continue
      workflow_has_pr_trigger "${dir}/${f}" && return 0
      while IFS= read -r caller; do
        [[ -n "${caller}" ]] || continue
        next+="${caller##*/}"$'\n'
      done < <(grep -rlE "uses:[[:space:]]*\./\.github/workflows/${f//./\\.}([[:space:]]|$)" "${dir}" 2>/dev/null || true)
    done <<< "${frontier}"
    frontier="${next}"
  done
  return 1
}

check_guards() { # check_guards <manifest> <root> <repo-guards-workflow>
  local manifest="$1" root="$2" wf="$3" fail=0 n=0
  local inv spec
  local wfdir="${wf%/*}"

  if [[ ! -f "${wf}" ]]; then
    fail_msg "[rule 6] the guard workflow does not exist: ${wf} — with nothing to scan, \
every citation would pass vacuously."
    return 1
  fi
  local wired_total
  wired_total="$(workflow_invocations "${wf}" 'scripts/ci/[A-Za-z0-9_]+\.sh' | grep -c $'\tok\t' || true)"
  if (( wired_total < 1 )); then
    fail_msg "[rule 6] no guard invocation found in an enabled step of ${wf##*/} — the \
workflow changed shape, so wiring cannot be proven for any citation."
    return 1
  fi
  if ! workflow_pr_reachable "${wfdir}" "${wf##*/}"; then
    fail_msg "[rule 6] ${wf##*/} is not reachable from any push/pull_request trigger — \
no change would run these guards, so every wiring citation below would be vacuous."
    return 1
  fi

  while IFS=$'\037' read -r inv spec; do
    [[ -n "${inv}" ]] || continue
    n=$(( n + 1 ))
    local path="${spec%%#*}" wf_override=""
    [[ "${spec}" == *"#workflow="* ]] && wf_override="${spec##*#workflow=}"

    if [[ ! -f "${root}/${path}" ]]; then
      fail_msg "[rule 6] ${inv}: cited guard does not exist: ${path}"
      fail=1
      continue
    fi

    local target="${wf}" label="${wf##*/}"
    if [[ -n "${wf_override}" ]]; then
      # A bare workflow file name, resolved inside `.github/workflows/`. Without
      # this, `#workflow=../../docs/WIRE_JOURNAL.md` satisfied the citation with
      # a fenced `bash …` block in a Markdown document.
      if [[ ! "${wf_override}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$ ]]; then
        fail_msg "[rule 6b] ${inv}: '${wf_override}' is not a workflow file name. Cite \
the enforcing run as '${path}#workflow=<name>.yml' — a bare name under .github/workflows/, \
never a path and never another kind of file."
        fail=1
        continue
      fi
      target="${wfdir}/${wf_override}"
      label="${wf_override}"
      if [[ ! -f "${target}" ]]; then
        fail_msg "[rule 6] ${inv}: ${path} names enforcing workflow '${wf_override}', \
which does not exist in .github/workflows/."
        fail=1
        continue
      fi
      if ! workflow_pr_reachable "${wfdir}" "${wf_override}"; then
        fail_msg "[rule 6b] ${inv}: ${path} names '${wf_override}', which no \
push/pull_request event reaches (directly or through workflow_call). A workflow that does \
not run on this change cannot be the proof that this change is safe."
        fail=1
        continue
      fi
    fi

    local verdict
    verdict="$(guard_wiring "${target}" "${path}")"
    case "${verdict}" in
      enforcing) ;;
      selftest)
        if [[ -n "${wf_override}" ]]; then
          fail_msg "[rule 6b] ${inv}: ${path} appears in ${label} only as '--self-test'. \
A self-test proves the guard's own fixtures pass; it says NOTHING about this repository."
        else
          fail_msg "[rule 6b] ${inv}: ${path} is wired in ${label} ONLY as '--self-test'. \
Its enforcing run lives in another workflow (rust-check.yml / coverage.yml need real test \
output); cite it as '${path}#workflow=<file>.yml' so the proof names where it actually runs."
        fi
        fail=1 ;;
      disabled:*)
        fail_msg "[rule 6] ${inv}: ${path} is invoked in ${label} but that step does not \
enforce: ${verdict#disabled:}. A guard that cannot fail the job is an orphaned guard with \
extra steps."
        fail=1 ;;
      *)
        fail_msg "[rule 6] ${inv}: ${path} exists but is invoked by NO enabled step of \
${label} — an orphaned guard runs nowhere and proves nothing (this is the tile-cache \
guard's failure, exactly). A mention in a comment or inside an echoed string is not a run."
        fail=1 ;;
    esac
  done < <(jqm_rows "${manifest}" '.invariants[] | .id as $i | (.guards // [])[] | [$i, .] | @tsv')

  (( fail == 0 )) || return 1
  printf '  [rules 6/6b] %d cited guard(s) exist and run enforcingly.\n' "${n}"
}

# ---------------------------------------------------------------------------
# Rules 1, 7, 8, 9, 11 — manifest-internal consistency.
#
# Rule 9 is the one that carries this workstream: an `accepted_deviation` row
# carrying an assertion key is a promise made about the very thing the project
# has written down that it does NOT hold.
# ---------------------------------------------------------------------------
check_invariant_rules() { # check_invariant_rules <manifest>
  local manifest="$1" fail=0 n=0

  local version
  version="$(jqm "${manifest}" '.schema_version // empty')"
  if [[ "${version}" != "1" ]]; then
    fail_msg "[rule 1] schema_version is '${version:-<missing>}', expected 1 — this \
checker enforces the v1 contract and cannot vouch for another."
    fail=1
  fi

  local dupes
  dupes="$(jqm "${manifest}" '[.invariants[].id] | group_by(.) | map(select(length > 1) | .[0]) | .[]')"
  if [[ -n "${dupes}" ]]; then
    fail_msg "[rule 1] duplicate invariant id(s): $(tr '\n' ' ' <<< "${dupes}")"
    fail=1
  fi

  local inv status residual dev_id n_assert n_disc n_disc_claims n_tests n_guards
  while IFS=$'\037' read -r inv status residual dev_id n_assert n_disc n_disc_claims n_tests n_guards; do
    [[ -n "${inv}" ]] || continue
    n=$(( n + 1 ))

    [[ "${inv}" =~ ^INV-[A-Z0-9-]+$ ]] || {
      fail_msg "[rule 1] invariant id '${inv}' does not match ^INV-[A-Z0-9-]+$"
      fail=1
    }

    case "${status}" in
      enforced)
        if (( n_tests + n_guards == 0 )); then
          fail_msg "[rule 7] ${inv} is 'enforced' but cites neither a test nor a guard — \
nothing enforces it."
          fail=1
        fi
        ;;
      ratcheted)
        if [[ -z "${residual}" || "${residual}" == "null" ]]; then
          fail_msg "[rule 8] ${inv} is 'ratcheted' but states no 'residual' — a partial \
guarantee that does not say what it fails to hold is indistinguishable from a full one."
          fail=1
        fi
        ;;
      accepted_deviation)
        if (( n_assert > 0 )); then
          fail_msg "[rule 9] *** ${inv} has status 'accepted_deviation' and yet carries \
${n_assert} assertion_arb_keys. YOU MAY NOT PROMISE WHAT YOU HAVE ACCEPTED DEVIATING \
FROM. Either the deviation is not accepted, or the copy is a false promise — one of the \
two has to change, and CI cannot pick which. ***"
          fail=1
        fi
        if (( n_disc + n_disc_claims == 0 )); then
          fail_msg "[rule 9] ${inv} accepts a deviation and discloses it nowhere: no \
disclosure_arb_keys and no disclosure-kind non_arb_claims. An undisclosed deviation is \
one the user cannot know about."
          fail=1
        fi
        if [[ -z "${dev_id}" || "${dev_id}" == "null" ]]; then
          fail_msg "[rule 9] ${inv} has status 'accepted_deviation' but no \
accepted_deviation_id."
          fail=1
        else
          if ! jq -e --arg d "${dev_id}" 'any(.accepted_deviations[]?; .id == $d)' "${manifest}" >/dev/null; then
            fail_msg "[rule 9] ${inv} cites accepted_deviation_id '${dev_id}', which is \
not declared in accepted_deviations[]."
            fail=1
          fi
        fi
        ;;
      *)
        fail_msg "[rule 1] ${inv} has unknown status '${status}' (expected enforced, \
ratcheted or accepted_deviation)."
        fail=1
        ;;
    esac

    if (( n_assert > 0 && n_tests + n_guards == 0 )); then
      fail_msg "[rule 11] ${inv} makes ${n_assert} user-facing promise(s) and cites no \
test and no guard — an unproven promise is exactly what this manifest exists to forbid."
      fail=1
    fi
  done < <(jqm_rows "${manifest}" '
    .invariants[] | [
      .id, .status, (.residual // ""), (.accepted_deviation_id // ""),
      ((.assertion_arb_keys // []) | length),
      ((.disclosure_arb_keys // []) | length),
      ([(.non_arb_claims // [])[] | select(.kind == "disclosure")] | length),
      ((.tests // []) | length),
      ((.guards // []) | length)
    ] | @tsv')

  local bad_carrier bad_kind reasonless_none
  bad_carrier="$(jqm "${manifest}" '[.invariants[] | .id as $i | (.non_arb_claims // [])[]
    | select((.carrier | IN("ios_infoplist","play_disclosure","dart_source")) | not)
    | "\($i): carrier=\(.carrier)"] | .[]')"
  bad_kind="$(jqm "${manifest}" '[.invariants[] | .id as $i | (.non_arb_claims // [])[]
    | select((.kind | IN("assertion","disclosure","attributed","none")) | not)
    | "\($i): \(.id) kind=\(.kind)"] | .[]')"
  # `kind: "none"` is the non-ARB twin of `non_claim_arb_keys` — the consent
  # dialog has a heading and two button labels that claim nothing, and there is
  # nowhere else honest to put them. It carries the same obligation: a
  # non-claim classification is a judgement and must be written down. It counts
  # for NOTHING elsewhere — not toward an accepted deviation being disclosed
  # (rule 9), not toward the disclosure ratchet — or it would become the
  # laundering route for exactly what those two rules exist to stop.
  reasonless_none="$(jqm "${manifest}" '[.invariants[] | .id as $i | (.non_arb_claims // [])[]
    | select(.kind == "none") | select(((.reason // "") | length) < 10)
    | "\($i): \(.id)"] | .[]')"
  if [[ -n "${bad_carrier}" ]]; then
    fail_msg "[rule 1] non_arb_claims with an unknown carrier: $(tr '\n' '; ' <<< "${bad_carrier}")"
    fail=1
  fi
  if [[ -n "${bad_kind}" ]]; then
    fail_msg "[rule 1] non_arb_claims with an unknown kind: $(tr '\n' '; ' <<< "${bad_kind}")"
    fail=1
  fi
  if [[ -n "${reasonless_none}" ]]; then
    fail_msg "[rule 1] non_arb_claims classified 'none' with no stated reason: \
$(tr '\n' '; ' <<< "${reasonless_none}"). Saying a user-facing string claims nothing is a \
judgement; it has to be written down to be reviewable."
    fail=1
  fi

  (( fail == 0 )) || return 1
  printf '  [rules 1/7/8/9/11] %d invariant(s) internally consistent.\n' "${n}"
}

# ---------------------------------------------------------------------------
# Rules 10 & 12 — the claim register is complete in BOTH directions.
#
# `attributed_arb_keys` counts as a classification here. The schema's coverage
# rule names only assertions and disclosures, but a key classed as attributed
# (a claim about a third party, falsifiable only via a Haven-side change) is
# classified; demanding it ALSO be listed as a disclosure would force the exact
# collapse `location_disclosure_dialog.dart`'s doc comment forbids.
# ---------------------------------------------------------------------------

# Every ARB key whose ENGLISH value carries claim language. Key names are a
# convention and conventions drift; the sentence the user reads does not.
claim_language_keys() { # claim_language_keys <arb>
  local joined
  printf -v joined '%s\037' "${CLAIM_LANGUAGE[@]}"
  jq -r 'to_entries[] | select(.key | startswith("@") | not)
         | [.key, (if (.value | type) == "string" then .value else (.value | tostring) end)]
         | @tsv' "$1" \
    | awk -F'\t' -v phrases="${joined}" '
        BEGIN { np = split(phrases, P, "\037") }
        { v = tolower($2)
          for (i = 1; i <= np; i++) if (P[i] != "" && index(v, P[i])) { print $1; next } }' \
    | sort -u
}

check_arb_coverage() { # check_arb_coverage <manifest> <arb> <plist> <disclosure-dart>
  local manifest="$1" arb="$2" plist="$3" ddart="$4" fail=0

  require_jq
  [[ -f "${arb}" ]] || { fail_msg "[rule 10] ARB not found: ${arb}"; return 1; }
  jq -e . "${arb}" >/dev/null 2>&1 || { fail_msg "[rule 10] ${arb} is not valid JSON"; return 1; }

  local arb_keys privacy_keys
  arb_keys="$(jq -r 'keys[] | select(startswith("@") | not)' "${arb}")"
  privacy_keys="$(grep '^privacy' <<< "${arb_keys}" || true)"
  if [[ -z "${arb_keys}" ]]; then
    fail_msg "[rule 12] ${arb##*/} yielded no keys — the extractor found nothing to scan."
    return 1
  fi
  if [[ -z "${privacy_keys}" ]]; then
    fail_msg "[rule 12] no 'privacy*' key found in ${arb##*/} — the naming convention \
this coverage rule keys on has changed, so the rule now checks nothing."
    return 1
  fi

  local claimed non_claim reasonless
  claimed="$(jqm "${manifest}" '[.invariants[] | (.assertion_arb_keys // [])[],
    (.disclosure_arb_keys // [])[], (.attributed_arb_keys // [])[]] | unique | .[]')"
  non_claim="$(jqm "${manifest}" '(.non_claim_arb_keys // {}) | keys[]')"

  # `non_claim_arb_keys` is a MAP so that the reason is mandatory by shape. An
  # empty one turns the escape hatch into an unexamined allow-list.
  reasonless="$(jqm "${manifest}" '(.non_claim_arb_keys // {}) | to_entries[]
    | select((if (.value | type) == "string" then .value else (.value.reason // "") end) | length < 10)
    | .key')"
  if [[ -n "${reasonless}" ]]; then
    fail_msg "[rule 12] non_claim_arb_keys entries with no stated reason: \
$(tr '\n' ' ' <<< "${reasonless}"). Declaring that a string makes no claim is a \
judgement; it has to be written down to be reviewable."
    fail=1
  fi

  # Rule 10: every claimed key exists.
  local k
  while IFS= read -r k; do
    [[ -n "${k}" ]] || continue
    fail_msg "[rule 10] claimed ARB key '${k}' does not exist in ${arb##*/} — the \
string was renamed or deleted and the claim now points at nothing."
    fail=1
  done <<< "$(missing_from "${claimed}" "${arb_keys}")"

  # Rule 12: non-claim keys exist...
  while IFS= read -r k; do
    [[ -n "${k}" ]] || continue
    fail_msg "[rule 12] non_claim_arb_keys names '${k}', which does not exist in \
${arb##*/}."
    fail=1
  done <<< "$(missing_from "${non_claim}" "${arb_keys}")"

  # ...and are not also claimed. (An intersection, not a difference: the one
  # forbidden overlap.)
  while IFS= read -r k; do
    [[ -n "${k}" ]] || continue
    if grep -qxF "${k}" <<< "${claimed}"; then
      fail_msg "[rule 12] '${k}' is declared to make no claim AND claimed as an \
assertion/disclosure/attribution. One of the two is wrong — unlike a key that is an \
assertion under one invariant and a disclosure under another, which is correct and \
expected."
      fail=1
    fi
  done <<< "${non_claim}"

  # Rule 12: every privacy* key AND every key whose value carries claim
  # language is classified. The prefix half of this sweep saw two thirds of the
  # register; the value half is what makes a claim under a new key name — the
  # onboarding screens are the live example — impossible to land unclassified.
  local claimish n_claimish n_arb_total floor_claimish
  claimish="$(claim_language_keys "${arb}")"
  n_claimish="$(grep -c . <<< "${claimish}" || true)"
  n_arb_total="$(grep -c . <<< "${arb_keys}" || true)"
  floor_claimish=$(( n_arb_total / CLAIM_LANGUAGE_PER_KEYS ))
  (( floor_claimish >= 1 )) || floor_claimish=1
  if (( ${#CLAIM_LANGUAGE[@]} < CLAIM_LANGUAGE_MIN_PHRASES )); then
    fail_msg "[rule 12] the claim-language phrase list is down to ${#CLAIM_LANGUAGE[@]} \
entries (at least ${CLAIM_LANGUAGE_MIN_PHRASES} are expected). Shortening the list narrows \
what the sweep can see, which is a coverage decision and must be an explicit one."
    fail=1
  fi
  if (( n_claimish < floor_claimish )); then
    fail_msg "[rule 12] the claim-language sweep matched only ${n_claimish} of the \
${n_arb_total} ARB strings (floor ${floor_claimish}). The phrase list stopped matching the \
copy it was written against — that is a broken sweep, never evidence that the app stopped \
promising things."
    fail=1
  fi

  local uncovered
  uncovered="$(missing_from "$(printf '%s\n%s\n' "${privacy_keys}" "${claimish}" | sort -u)" \
                            "$(printf '%s\n%s\n' "${claimed}" "${non_claim}")" \
              | sed 's/^/    * /')"
  if [[ -n "${uncovered}" ]]; then
    fail_msg "[rule 12] privacy string(s) classified nowhere — each of these is either a \
'privacy*' key or reads as a promise in the user's own words, so each either backs an \
invariant or is declared to make no claim, with a reason:"
    printf '%s\n' "${uncovered}" >&2
    fail=1
  fi

  # Rule 12: a load-bearing-by-omission string must not acquire the clause its
  # entry bans. These are correct only because of what they do NOT say.
  local key phrase
  while IFS=$'\037' read -r key phrase; do
    [[ -n "${key}" ]] || continue
    local value
    value="$(jq -r --arg k "${key}" '.[$k] // ""' "${arb}")"
    if grep -qiF "${phrase}" <<< "${value}"; then
      fail_msg "[rule 12] '${key}' now contains the clause its non_claim entry forbids \
(\"${phrase}\"). That string is honest only by omission; adding this makes it a claim \
nothing backs."
      fail=1
    fi
  done < <(jqm_rows "${manifest}" '(.non_claim_arb_keys // {}) | to_entries[]
    | select(.value | type == "object")
    | .key as $k | (.value.forbidden_additions // [])[] | [$k, .] | @tsv')

  # Rule 12: non-ARB carriers discoverable by grep.
  local declared_non_arb
  declared_non_arb="$(jqm "${manifest}" '[.invariants[] | (.non_arb_claims // [])[].id] | unique | .[]')"

  if [[ ! -f "${plist}" ]]; then
    fail_msg "[rule 12] iOS Info.plist not found: ${plist}"
    fail=1
  else
    local plist_keys
    plist_keys="$(grep -oE 'NS[A-Za-z]+UsageDescription' "${plist}" | sort -u || true)"
    if [[ -z "${plist_keys}" ]]; then
      fail_msg "[rule 12] no NS*UsageDescription key found in ${plist##*/} — nothing to \
scan means nothing proven."
      fail=1
    else
      while IFS= read -r k; do
        [[ -n "${k}" ]] || continue
        fail_msg "[rule 12] iOS usage description '${k}' maps to no non_arb_claims entry. \
The permission prompt is a claim the user reads before granting."
        fail=1
      done <<< "$(missing_from "${plist_keys}" "${declared_non_arb}")"
    fi
  fi

  if [[ ! -f "${ddart}" ]]; then
    fail_msg "[rule 12] consent-dialog strings file not found: ${ddart}"
    fail=1
  else
    local cls fields
    cls="$(sed -nE 's/^[[:space:]]*(abstract[[:space:]]+)?(final[[:space:]]+)?class[[:space:]]+([A-Za-z0-9_]+).*/\3/p' "${ddart}" | head -1)"
    fields="$(sed -nE 's/^[[:space:]]*static const String[[:space:]]+([A-Za-z0-9_]+).*/\1/p' "${ddart}" | sort -u)"
    if [[ -z "${cls}" || -z "${fields}" ]]; then
      fail_msg "[rule 12] could not read the consent-dialog string class from \
${ddart##*/} — it changed shape, so this coverage rule is scanning nothing."
      fail=1
    else
      while IFS= read -r k; do
        [[ -n "${k}" ]] || continue
        fail_msg "[rule 12] '${k}' maps to no non_arb_claims entry. That class is the \
artefact recording the user's consent; every sentence in it is a claim."
        fail=1
      done <<< "$(missing_from "$(sed "s|^|${cls}.|" <<< "${fields}")" "${declared_non_arb}")"
    fi
  fi

  (( fail == 0 )) || return 1
  printf '  [rules 10/12] every privacy string and non-ARB carrier is classified (%s privacy* keys, %s carrying claim language).\n' \
    "$(grep -c . <<< "${privacy_keys}" || true)" "${n_claimish}"
}

# ---------------------------------------------------------------------------
# Rule 13 — event-kind construction tokens.
#
# Production Rust only: `#[cfg(test)]` module bodies are brace-walked out (test
# fixtures build decoy kinds 446 and 1), whole-line comments are dropped (doc
# comments quote tokens while describing them), and `haven/lib/src/rust/` plus
# `frb_generated*` are excluded by path.
#
# Four token families, because the nostr crate offers four ways to name a kind
# and the scan used to see two: `Kind::Custom(N)`, a `Kind::` VARIANT, a
# `Kind::` associated function with its argument (`Kind::from(31337_u16)` —
# `impl From<u16> for Kind` is the crate's primary constructor, and requiring
# an uppercase letter after `Kind::` walked straight past it), a `u16`
# literal's `.into()`, and the kind-implying `EventBuilder::` constructors.
# ---------------------------------------------------------------------------
extract_kind_tokens() { # extract_kind_tokens <root>
  local root="$1" f
  local -a files=()
  while IFS= read -r f; do files+=("${f}"); done < <(
    find "${root}/haven-core/src" "${root}/haven/rust_builder/src" -name '*.rs' 2>/dev/null \
      | grep -v 'frb_generated' | sort
  )
  (( ${#files[@]} > 0 )) || return 0

  for f in "${files[@]}"; do
    awk -v file="${f}" '
      { L[NR] = $0 }
      END {
        depth = 0; intest = 0; pending = 0; testdepth = 0
        for (j = 1; j <= NR; j++) {
          t = L[j]
          if (!intest && t ~ /#\[[[:space:]]*cfg\(test\)/) pending = 1
          tmp = t; o = gsub(/[{]/, "", tmp)
          tmp = t; c = gsub(/[}]/, "", tmp)
          if (!intest && pending && o > 0 && t ~ /(^|[^A-Za-z0-9_])mod([^A-Za-z0-9_]|$)/) {
            intest = 1; testdepth = depth; pending = 0
          }
          skipline = intest
          depth += o - c
          if (intest && depth <= testdepth) intest = 0
          if (skipline) continue
          if (t ~ /^[[:space:]]*(\/\/|\*|\/\*)/) continue

          # `Kind::<name>` with its argument when it has one, so a new NUMBER
          # is a new token exactly as a new name is.
          s = t
          while (match(s, /(^|[^A-Za-z0-9_])Kind::[A-Za-z_][A-Za-z0-9_]*(\([A-Za-z0-9_]+\))?/)) {
            tok = substr(s, RSTART, RLENGTH)
            sub(/^[^K]*/, "", tok)
            printf "%s\t%s:%d\n", tok, file, j
            s = substr(s, RSTART + RLENGTH)
          }
          # `31337_u16.into()` — the same `From<u16>` conversion wearing method
          # syntax, and the one kind construction that never names `Kind` at all.
          s = t
          while (match(s, /(^|[^A-Za-z0-9_.])[0-9][0-9_]*(u16|_u16)?\.into\(\)/)) {
            tok = substr(s, RSTART, RLENGTH)
            sub(/^[^0-9]*/, "", tok)
            printf "%s\t%s:%d\n", tok, file, j
            s = substr(s, RSTART + RLENGTH)
          }
          s = t
          while (match(s, /(^|[^A-Za-z0-9_])EventBuilder::[a-z_][a-z0-9_]*/)) {
            tok = substr(s, RSTART, RLENGTH)
            sub(/^[^E]*/, "", tok)
            # `EventBuilder::new` takes an explicit Kind, which the two rules
            # above already enumerate; the kind-implying constructors are the
            # ones that carry no Kind argument at all.
            if (tok != "EventBuilder::new") printf "%s\t%s:%d\n", tok, file, j
            s = substr(s, RSTART + RLENGTH)
          }
        }
      }
    ' "${f}"
  done
}

check_event_kinds() { # check_event_kinds <manifest> <root> <cargo-toml>
  local manifest="$1" root="$2" cargo="$3" fail=0

  local found
  found="$(extract_kind_tokens "${root}" | sort -u || true)"
  # DISTINCT tokens. The rows are `(token, file:line)` pairs, so counting rows
  # reported "38 production kind token(s)" for the 17 tokens that exist — a
  # number nobody could reconcile with the manifest's 15 declared kinds.
  local n_tokens
  n_tokens="$(awk -F'\t' '{print $1}' <<< "${found}" | sort -u | grep -c . || true)"
  if (( n_tokens < 1 )); then
    fail_msg "[rule 13] no event-kind construction token found in production Rust — the \
token scan matched nothing, so a new kind could not be detected."
    return 1
  fi

  local declared
  declared="$(jqm "${manifest}" '[.invariants[] | (.event_kinds // [])[] | .token] | unique | .[]')"

  local tok site undeclared=""
  while IFS=$'\t' read -r tok site; do
    [[ -n "${tok}" ]] || continue
    grep -qxF "${tok}" <<< "${declared}" && continue
    undeclared+="    * ${tok}  (${site#"${root}/"})"$'\n'
  done <<< "$(awk -F'\t' '!seen[$1]++' <<< "${found}")"
  if [[ -n "${undeclared}" ]]; then
    fail_msg "[rule 13] event-kind construction token(s) built in production and declared \
in no invariant. A NEW TOKEN is the trigger, not a new number — declare each with its \
kind and a note, or remove the construction site:"
    printf '%s' "${undeclared}" >&2
    fail=1
  fi

  if [[ ! -f "${cargo}" ]]; then
    fail_msg "[rule 13] ${cargo} not found — the MDK rev cannot be pinned."
    return 1
  fi
  local revs rev pinned
  revs="$(grep -oE 'marmot-protocol/mdk", rev = "[0-9a-f]+"' "${cargo}" | sed -E 's/.*rev = "([0-9a-f]+)"/\1/' | sort -u)"
  if [[ -z "${revs}" ]]; then
    fail_msg "[rule 13] no pinned MDK rev found in ${cargo##*/} — the dependency changed \
shape, so an MDK bump would no longer force a manifest re-derivation."
    return 1
  fi
  if (( $(grep -c . <<< "${revs}") != 1 )); then
    fail_msg "[rule 13] the MDK crates are pinned to more than one rev: \
$(tr '\n' ' ' <<< "${revs}")"
    return 1
  fi
  rev="${revs}"
  pinned="$(jqm "${manifest}" '.pinned_dependencies.mdk_rev // empty')"
  if [[ -z "${pinned}" ]]; then
    fail_msg "[rule 13] pinned_dependencies.mdk_rev is missing. Kinds 445, 1059 and the \
444 rumor are built inside the rev-pinned peeler; this pin is the ONLY mechanism that can \
force the manifest to be re-derived when MDK moves."
    fail=1
  elif [[ "${pinned}" != "${rev}" ]]; then
    fail_msg "[rule 13] pinned_dependencies.mdk_rev is ${pinned} but haven-core/Cargo.toml \
pins ${rev}. MDK moved: re-derive the out-of-tree event kinds (peeler-built 445/1059/444) \
against the new rev before updating this field."
    fail=1
  fi

  (( fail == 0 )) || return 1
  printf '  [rule 13] %d production kind token(s) declared; MDK rev pinned at %s.\n' \
    "${n_tokens}" "${rev:0:12}"
}

# ---------------------------------------------------------------------------
# Rule 14 — anti-vacuity floors.
#
# A manifest that shrank to nothing, or an extractor that stopped extracting,
# must fail loudly instead of reporting a clean join over an empty set.
# ---------------------------------------------------------------------------
count_metrics() { # count_metrics <manifest> -> "inv arb kinds guards tests docs"
  local manifest="$1"
  jqm_rows "${manifest}" '
    [
      (.invariants | length),
      ([.invariants[] | (.assertion_arb_keys // [])[], (.disclosure_arb_keys // [])[],
        (.attributed_arb_keys // [])[]] + ((.non_claim_arb_keys // {}) | keys) | unique | length),
      ([.invariants[] | (.event_kinds // [])[] | .kind] | unique | length),
      ([.invariants[] | (.guards // [])[] | split("#")[0]] | unique | length),
      ([.invariants[] | (.tests // [])[] | "\(.file)::\(.name)"] | unique | length),
      ([(.accepted_deviations // [])[].source, .invariants[].doc_anchors[]?]
        | map(select(. != null)) | unique | length)
    ] | @tsv'
}

_floor() { # _floor <label> <measured> <floor>   (sets FLOOR_FAIL on breach)
  if (( $2 < $3 )); then
    fail_msg "[rule 14] only $2 $1 (floor $3) — a manifest this thin means the \
extractor broke or the manifest was gutted; either way the join proves nothing."
    FLOOR_FAIL=1
  fi
}

check_floors() { # check_floors <manifest>
  local manifest="$1"
  local n_inv n_arb n_kinds n_guards n_tests n_docs
  IFS=$'\037' read -r n_inv n_arb n_kinds n_guards n_tests n_docs < <(count_metrics "${manifest}")

  FLOOR_FAIL=0
  _floor "invariant(s)"        "${n_inv}"    "${FLOOR_INVARIANTS}"
  _floor "classified ARB key(s)" "${n_arb}"  "${FLOOR_ARB_KEYS}"
  _floor "distinct event kind(s)" "${n_kinds}" "${FLOOR_EVENT_KINDS}"
  _floor "distinct guard(s)"   "${n_guards}" "${FLOOR_GUARDS}"
  _floor "distinct test(s)"    "${n_tests}"  "${FLOOR_TESTS}"
  _floor "cited document reference(s)" "${n_docs}" "${FLOOR_DOC_REFS}"

  (( FLOOR_FAIL == 0 )) || return 1
  printf '  [rule 14] %s invariants · %s ARB keys · %s event kinds · %s guards · %s tests · %s doc refs.\n' \
    "${n_inv}" "${n_arb}" "${n_kinds}" "${n_guards}" "${n_tests}" "${n_docs}"
}

# ---------------------------------------------------------------------------
# Rule 15 — cited documentation resolves.
#
# `accepted_deviations[].source` and `invariants[].doc_anchors[]` are the only
# rows in this manifest a human is expected to FOLLOW; every other row is
# re-derived above. Nothing read them until this rule existed, and one was
# already dead: `IOS-KEYCHAIN` cited
# `SECURITY.md#ios-keychain-accessibility-owner-approved-tradeoff`, which is not
# a heading — that tradeoff is a bold run-in inside a bullet. A reviewer who
# follows a dead citation concludes the deviation is undocumented, and being
# followable is the one property this register exists to have.
#
# Fragments are matched against GitHub's slug rules: punctuation dropped (`-`
# and `_` survive), every remaining space becomes a hyphen, lowercased — so
# `### A — b (C)` is `#a--b-c`, with TWO hyphens, because the dropped em dash
# leaves its two spaces behind. Repeated slugs take GitHub's `-1`/`-2` suffix,
# which is what a reviewer copying an anchor out of the browser gets.
#
# Fenced blocks are skipped, and that is load-bearing rather than tidy:
# SECURITY.md's `# Install cargo-audit` sits inside one, and reading it as a
# heading would mint anchors nobody wrote for a dead citation to resolve
# against.
#
# Two stated bounds, both failing CLOSED (a live anchor reported dead, never
# the reverse): ATX headings only — a setext-underlined document yields none,
# which is reported as a document with no headings — and ASCII case folding.
# ---------------------------------------------------------------------------
doc_heading_slugs() { # doc_heading_slugs <markdown-file>
  # LC_ALL=C so the octal patterns below match UTF-8 BYTES: the General
  # Punctuation block (em/en dashes, curly quotes, ellipsis) is what these
  # headings actually carry, and GitHub drops every character in it.
  LC_ALL=C awk '
    function slugify(s,   t) {
      while (match(s, /\[[^]]*\]\([^)]*\)/)) {   # a link renders as its text alone
        t = substr(s, RSTART + 1, RLENGTH - 1)
        sub(/\]\(.*/, "", t)
        s = substr(s, 1, RSTART - 1) t substr(s, RSTART + RLENGTH)
      }
      gsub(/\342\200[\200-\277]/, "", s)          # U+2000-U+203F
      gsub(/\342\201[\200-\257]/, "", s)          # U+2040-U+206F
      gsub(/[!-,.\/:-@[-^`{-~]/, "", s)            # ASCII punctuation but - and _
      gsub(/[\t ]/, "-", s)
      return tolower(s)
    }
    /^[[:space:]]*(```|~~~)/ { fenced = !fenced; next }
    fenced { next }
    /^#{1,6}([[:space:]]|$)/ {
      h = $0
      sub(/^#+[[:space:]]*/, "", h)
      sub(/[[:space:]]*#+[[:space:]]*$/, "", h)     # ATX closing sequence
      sub(/[[:space:]]+$/, "", h)
      s = slugify(h)
      if (s == "") next
      n = seen[s]++
      print (n ? s "-" n : s)
    }
  ' "$1"
}

check_doc_anchors() { # check_doc_anchors <manifest> <root>
  local manifest="$1" root="$2" fail=0 n=0
  local origin ref file frag slugs

  while IFS=$'\037' read -r origin ref; do
    [[ -n "${origin}" ]] || continue
    n=$(( n + 1 ))
    file="${ref%%#*}"
    frag=""
    if [[ "${ref}" == *"#"* ]]; then frag="${ref#*#}"; fi

    if [[ -z "${file}" || ! -f "${root}/${file}" ]]; then
      fail_msg "[rule 15] ${origin}: cites '${ref}', whose document does not exist. A \
citation nobody can follow reads as a deviation nobody wrote down."
      fail=1
      continue
    fi
    [[ -n "${frag}" ]] || continue

    slugs="$(doc_heading_slugs "${root}/${file}")"
    if [[ -z "${slugs}" ]]; then
      fail_msg "[rule 15] ${origin}: ${file} yielded no heading at all, so '#${frag}' \
cannot be resolved — the document changed shape and every citation into it is now \
unverifiable."
      fail=1
      continue
    fi
    if ! grep -qxF "${frag}" <<< "${slugs}"; then
      fail_msg "[rule 15] ${origin}: ${file} has no heading whose GitHub anchor is \
'#${frag}' — the section was renamed or never existed, so this citation lands nowhere and \
the deviation reads as undocumented."
      fail=1
    fi
  done < <(jqm_rows "${manifest}" '
    ( (.accepted_deviations // [])[] | select(.source) | ["\(.id) source", .source] ),
    ( .invariants[] | .id as $i | (.doc_anchors // [])[] | ["\($i) doc_anchors", .] )
    | @tsv')

  (( fail == 0 )) || return 1
  printf '  [rule 15] %d cited document reference(s) resolve.\n' "${n}"
}

# ---------------------------------------------------------------------------
# The ratchet.
#
# Weakenings are enumerated against the baseline manifest, each with a stable
# item id. A weakening fails unless the SAME commit names its item in
# `ratchet_override.items` with a reason — CI cannot judge whether a downgrade
# is justified, only force it to be stated where review sees it. And an
# override naming something that is NOT weakened fails too: a stale allowance
# means the proof it guarded is gone and nothing noticed (the rule
# `check_no_undeclared_skips.sh` applies to stale skip declarations).
#
# A DROPPED ASSERTION KEY is a weakening in its own right, and its absence here
# was a free laundering route: moving `onboardingValueProp1Body` ("encrypted on
# your device … never Haven or anyone else") out of its invariant and into
# `non_claim_arb_keys` with a plausible reason passed every rule, moved no
# count in rule 14 (non-claim keys count toward the same total), and left the
# ratchet silent. The README closes that route for `kind: "none"`; this closes
# its ARB-side twin. A key that merely MOVES between invariants is not a
# weakening — the promise still stands and is still proved — so the drop counts
# only when the key is claimed as an assertion nowhere in the new manifest.
# ---------------------------------------------------------------------------
enumerate_weakenings() { # enumerate_weakenings <current> <baseline>
  require_jq
  jq -rn --slurpfile cur "$1" --slurpfile base "$2" '
    def rank: {"enforced": 3, "ratcheted": 2, "accepted_deviation": 1}[.] // 0;
    def index($m): ($m[0].invariants // []) | map({key: .id, value: .}) | from_entries;
    index($cur) as $c | index($base) as $b
    | ([ ($cur[0].invariants // [])[] | (.assertion_arb_keys // [])[] ] | unique) as $still
    | [ $b | to_entries[] ]
    | map(
        .key as $id | .value as $old
        | if ($c[$id] | not) then ["\($id).deleted"]
          else ($c[$id]) as $new
            | ( if ($new.status | rank) < ($old.status | rank) then ["\($id).status"] else [] end )
            + ( ( ($old.disclosure_arb_keys // []) + [($old.non_arb_claims // [])[] | select(.kind == "disclosure") | .id] )
                - ( ($new.disclosure_arb_keys // []) + [($new.non_arb_claims // [])[] | select(.kind == "disclosure") | .id] )
                | map("\($id).disclosure:\(.)") )
            + ( ( ($old.assertion_arb_keys // []) - ($new.assertion_arb_keys // []) - $still )
                | map("\($id).assertion:\(.)") )
            + ( if ((($old.tests // []) | length) + (($old.guards // []) | length)) > 0
                   and ((($new.tests // []) | length) + (($new.guards // []) | length)) == 0
                then [ ($new.assertion_arb_keys // [])[] | "\($id).unbacked:\(.)" ]
                else [] end )
          end
      )
    | flatten | unique | .[]'
}

check_ratchet() { # check_ratchet <current> <baseline-or-empty>
  local manifest="$1" baseline="$2" fail=0

  if [[ -z "${baseline}" ]]; then
    printf '%s\n' "  [ratchet] the base ref carries no privacy-invariant manifest at any \
path — nothing to ratchet against, so this is the commit that introduces it."
    return 0
  fi

  local weakenings items reason
  weakenings="$(enumerate_weakenings "${manifest}" "${baseline}")"
  items="$(jqm "${manifest}" '(.ratchet_override.items // [])[]')"
  reason="$(jqm "${manifest}" '.ratchet_override.reason // ""')"

  local unallowed stale
  unallowed="$(missing_from "${weakenings}" "${items}" | sed 's/^/    * /')"
  if [[ -n "${unallowed}" ]]; then
    fail_msg "[ratchet] this change weakens a stated guarantee relative to the base ref. \
CI cannot judge whether that is justified — it can only require you to say so in the diff. \
Add each item to ratchet_override.items with a reason, or restore what was removed:"
    printf '%s\n' "${unallowed}" >&2
    fail=1
  fi

  stale="$(missing_from "${items}" "${weakenings}" | sed 's/^/    * /')"
  if [[ -n "${stale}" ]]; then
    fail_msg "[ratchet] ratchet_override names item(s) that are NOT weakened by this \
change. A stale allowance outlives the thing it was written for; delete it (and if it \
names an invariant that no longer exists, that deletion is itself the weakening):"
    printf '%s\n' "${stale}" >&2
    fail=1
  fi

  if [[ -n "${items}" ]] && (( ${#reason} < 40 )); then
    fail_msg "[ratchet] ratchet_override.reason is ${#reason} characters; at least 40 are \
required. The reason is the only thing a reviewer reads before accepting a downgrade."
    fail=1
  fi

  (( fail == 0 )) || return 1
  local n_items
  n_items="$(grep -c . <<< "${items}" || true)"
  printf '  [ratchet] no unstated weakening against the baseline (%s declared override(s)).\n' "${n_items}"
}

# ---------------------------------------------------------------------------
# Baseline read. A ref that will not resolve is a MISCONFIGURATION (the job
# must fetch it), never a skip.
#
# "No manifest at MANIFEST_REL in the base commit" used to mean "this is the
# commit that introduces it" — which is true exactly once, and false every time
# the file MOVES. Renaming the manifest and this constant together is a
# one-line housekeeping edit, and it turned a real invariant deletion from a
# red into a green: the ratchet had nothing to compare against and said so
# cheerfully. So the baseline tree is searched for a manifest at any plausible
# path before that conclusion is drawn, and a genuine first landing stays green
# and ANNOUNCED. Two manifests in the baseline is a misconfiguration, not a
# guess: the guard must not pick which history it ratchets against.
# ---------------------------------------------------------------------------
baseline_manifest_paths() { # baseline_manifest_paths <ref>
  local ref="$1" dir="${MANIFEST_REL%/*}" f
  # Candidates: any JSON near the manifest's own directory, or named like it.
  # Each is confirmed by SHAPE, so a neighbouring config file is not mistaken
  # for a manifest.
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    git -C "${REPO_ROOT}" show "${ref}:${f}" 2>/dev/null \
      | jq -e '(.schema_version != null) and ((.invariants | type) == "array")' >/dev/null 2>&1 \
      && printf '%s\n' "${f}"
  done < <(git -C "${REPO_ROOT}" ls-tree -r --name-only "${ref}" 2>/dev/null \
             | grep -E "\.json$" \
             | grep -E "(^|/)privacy[^/]*\.json$|(^|/)[^/]*invariants?[^/]*\.json$|^${dir}/" \
             || true)
}

read_baseline() { # read_baseline <ref> <out-file>
  local ref="$1" out="$2"
  require_git
  git -C "${REPO_ROOT}" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || misconfig \
    "baseline ref '${ref}' cannot be resolved. The ratchet is not optional: under a shallow \
checkout the job must fetch it first, e.g. \
\`git fetch --no-tags --depth=1 origin +refs/heads/main:refs/remotes/origin/main\`. \
Use --baseline-ref to name a different base, or --no-ratchet locally."
  if git -C "${REPO_ROOT}" cat-file -e "${ref}:${MANIFEST_REL}" 2>/dev/null; then
    git -C "${REPO_ROOT}" show "${ref}:${MANIFEST_REL}" > "${out}"
    printf '%s\n' "${out}"
    return 0
  fi

  local moved n_moved
  moved="$(baseline_manifest_paths "${ref}")"
  n_moved="$(grep -c . <<< "${moved}" || true)"
  if (( n_moved > 1 )); then
    misconfig "the base ref carries ${n_moved} privacy-invariant manifests \
($(tr '\n' ' ' <<< "${moved}")) and this commit reads ${MANIFEST_REL}. Which one the \
ratchet compares against is not a guess a guard may make: leave exactly one."
  fi
  if (( n_moved == 1 )); then
    # stderr, never stdout: this function's stdout IS the baseline path its
    # caller reads.
    log "the manifest moved: the base ref carries it at ${moved}, this commit reads \
${MANIFEST_REL}. Ratcheting against the old path — a rename is not a fresh start." >&2
    git -C "${REPO_ROOT}" show "${ref}:${moved}" > "${out}"
    printf '%s\n' "${out}"
  fi
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures under a mktemp'd miniature repo, no repo state.
#
# The base tree is deliberately tiny: each fixture copies it and breaks exactly
# one link, so an `rc=1` is attributable. The five CRITICAL fixtures are the
# ones this workstream exists for — an assertion on an accepted deviation, a
# deleted disclosure, an unwired guard, a self-test-only wiring, an ignored
# test — and each has its false-positive twin, because a guard that cannot
# stay green on correct input gets deleted rather than fixed.
#
# Every failing fixture DECLARES THE RULE it is testing, and the expected
# `[rule N]` tag must appear on stderr. An exit code alone proved too little:
# two of the five CRITICAL fixtures were passing for the wrong reason — the
# `#[ignore]` one on rule 5's tautology check (its body was `assert!(true)`,
# so deleting every `#[ignore]` detection left the self-test 67/67 green) and
# the accepted-deviation one on rule 11 (its invariant cited no test and no
# guard, so disabling rule 9's assertion branch changed nothing). Both fixtures
# now carry the shape they claim to test, and the tag assertion is what keeps
# the next one honest.
#
# EXPECTED_FIXTURES is an equality pin, not a floor: deleting five fixtures —
# two of them CRITICAL — printed `OK: self-test passed (62 fixtures)` and
# nothing noticed. `check-wire-journal.sh`'s MIN_CASES sat ten below its real
# count for the same reason. Update it in the same commit that adds a fixture.
# ---------------------------------------------------------------------------
FIXTURES=0
SELFTEST_FAILS=0
EXPECTED_FIXTURES=98

_expect() { # _expect <label> <want-rc> <want-tag-or-'-'> <command...>
  local label="$1" want="$2" tag="$3" got=0 err
  shift 3
  FIXTURES=$(( FIXTURES + 1 ))
  err="$(mktemp)"
  ( "$@" ) >/dev/null 2>"${err}" || got=$?
  if [[ "${got}" -ne "${want}" ]]; then
    printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
    SELFTEST_FAILS=1
  elif [[ "${tag}" != "-" ]] && ! grep -qF "${tag}" "${err}"; then
    printf '  \033[1;31mFAIL\033[0m %s (rc=%d as expected, but no %s in the message — it \
failed for a DIFFERENT reason, so it does not test what it says)\n' "${label}" "${got}" "${tag}" >&2
    sed 's/^/        /' "${err}" >&2
    SELFTEST_FAILS=1
  else
    printf '  \033[1;32mPASS\033[0m %s (rc=%d%s)\n' "${label}" "${got}" \
      "$([[ "${tag}" == "-" ]] || printf ', %s' "${tag}")"
  fi
  rm -f "${err}"
}

_mkrepo() { # _mkrepo <dir>
  local d="$1"
  mkdir -p "${d}/.github/workflows" "${d}/scripts/ci" "${d}/docs/privacy" \
    "${d}/haven-core/src" "${d}/haven-core/tests" "${d}/haven/lib/l10n" \
    "${d}/haven/ios/Runner" "${d}/haven/lib/src/widgets/location" \
    "${d}/haven/test/lints" "${d}/haven/integration_test" "${d}/haven/rust_builder/src"

  cat > "${d}/.github/workflows/repo-guards.yml" <<'YAML'
# Header comment. Every guard is named here as well as invoked below, which is
# why wiring detection may not key on the filename alone:
#   Orphan guard   scripts/ci/check_orphan.sh
#   Wired guard    scripts/ci/check_wired.sh
#   Skip manifest  scripts/ci/check_selftest_only.sh
name: Repo Guards
on:
  workflow_call:
jobs:
  guards:
    steps:
      - name: Checkout
        id: checkout
        uses: actions/checkout@v6
      - name: Wired guard
        if: ${{ !cancelled() && steps.checkout.outcome == 'success' }}
        run: bash scripts/ci/check_wired.sh
      - name: Self-test-only guard
        if: ${{ !cancelled() && steps.checkout.outcome == 'success' }}
        run: bash scripts/ci/check_selftest_only.sh --self-test
      - name: A neighbour that only TALKS about a guard
        if: ${{ !cancelled() && steps.checkout.outcome == 'success' }}
        run: echo "Tip: run bash scripts/ci/check_orphan.sh yourself before pushing"
YAML

  # The reusable workflows above and below run only because ci.yml calls them,
  # which is why reachability is transitive rather than a trigger grep.
  cat > "${d}/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  guards:
    uses: ./.github/workflows/repo-guards.yml
  cov:
    uses: ./.github/workflows/coverage.yml
YAML

  cat > "${d}/.github/workflows/coverage.yml" <<'YAML'
name: Coverage
on:
  workflow_call:
jobs:
  cov:
    steps:
      - name: Enforce
        run: bash scripts/ci/check_selftest_only.sh flutter lcov.info
YAML

  # Runs only when a human presses the button, so it proves nothing about a PR.
  cat > "${d}/.github/workflows/manual-only.yml" <<'YAML'
name: Manual
on:
  workflow_dispatch:
jobs:
  manual:
    steps:
      - name: Enforce
        run: bash scripts/ci/check_selftest_only.sh flutter lcov.info
YAML

  # A document whose fenced block invokes a guard — text, not a workflow.
  cat > "${d}/docs/HANDBOOK.md" <<'MD'
# Handbook

Run the guard yourself:

```bash
bash scripts/ci/check_selftest_only.sh flutter lcov.info
```
MD

  printf '#!/usr/bin/env bash\n' > "${d}/scripts/ci/check_wired.sh"
  printf '#!/usr/bin/env bash\n' > "${d}/scripts/ci/check_orphan.sh"
  printf '#!/usr/bin/env bash\n' > "${d}/scripts/ci/check_selftest_only.sh"

  cat > "${d}/scripts/ci/expected_test_skips.txt" <<'EOF'
# comment
selftest|tests/fixture_tests.rs::skipped_by_manifest|needs a keyring|1
EOF

  cat > "${d}/haven/lib/l10n/app_en.arb" <<'JSON'
{
  "@@locale": "en",
  "privacyPromise": "Haven never sends your location unencrypted.",
  "@privacyPromise": { "description": "assertion" },
  "privacyWarning": "Relays learn your IP address.",
  "privacyHeading": "Privacy",
  "privacyOmission": "Key packages are published to your relay list.",
  "privacyThirdParty": "A VPN hides your IP from the relay.",
  "unrelatedKey": "Save"
}
JSON

  cat > "${d}/haven/ios/Runner/Info.plist" <<'PLIST'
<plist><dict>
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>Haven encrypts every position before it leaves your phone.</string>
</dict></plist>
PLIST

  cat > "${d}/haven/lib/src/widgets/location/location_disclosure_dialog.dart" <<'DART'
abstract final class LocationDisclosureStrings {
  static const String why = 'Haven asks for precise location.';
  static const String how = 'Encrypted for your circle only.';
}
DART

  cat > "${d}/haven-core/src/probe.rs" <<'RS'
use nostr::{EventBuilder, Kind};

// A cited symbol that IS a string literal: the endpoint whose absence from the
// default tile source is the invariant.
pub const TILE_HOST: &str = "tile.openstreetmap.org";

pub fn build_group_event() -> Event {
    EventBuilder::new(Kind::Custom(445), "x").build()
}

pub fn build_profile_event() -> Event {
    EventBuilder::metadata(&metadata)
}

/// Doc comment naming Kind::Custom(10063) while describing it.
pub fn documented() {}

#[cfg(test)]
mod tests {
    #[test]
    fn decoy() {
        let _ = EventBuilder::new(Kind::Custom(446), "x");
    }
}
RS

  cat > "${d}/haven-core/Cargo.toml" <<'TOML'
[dependencies]
cgka-session = { git = "https://github.com/marmot-protocol/mdk", rev = "e391adc133a9b60e420da7a0446f014a180ac8d2" }
cgka-engine = { git = "https://github.com/marmot-protocol/mdk", rev = "e391adc133a9b60e420da7a0446f014a180ac8d2" }
TOML

  # Headings chosen for the slug cases that actually occur: a colon and an em
  # dash inside one heading, a parenthesised suffix, a code span, a `#` comment
  # inside a fenced block (SECURITY.md really has one), and a repeat.
  cat > "${d}/haven-core/SECURITY.md" <<'MD'
# Security Policy

## Network threat model

Prose.

### IP-level linkage is out of scope (P6)

Prose.

### Outer kind:445 metadata — group-governed NIP-40 `expiration`

```bash
# Not a heading: a shell comment inside a fenced block.
```

## Repeated heading

## Repeated heading
MD

  cat > "${d}/haven-core/tests/fixture_tests.rs" <<'RS'
/// A prose comment mentioning `#[ignore]` while explaining a gate — this must
/// never be read as an attribute on the test below it.
#[test]
fn good_proof() {
    assert_eq!(1 + 1, 2);
}

// The body is a REAL assertion on purpose: with `assert!(true)` here, rule 5's
// tautology check produced this fixture's rc=1 and rule 4's `#[ignore]`
// detection could be deleted whole with the self-test still green.
#[test]
#[ignore = "requires system keyring"]
fn ignored_proof() {
    assert_eq!(3, 3);
}

#[test]
fn tautological_proof() {
    assert!(true);
}

#[test]
fn skipped_by_manifest() {
    assert_eq!(2, 2);
}

fn helper_not_a_test() {
    assert!(false);
}
RS

  cat > "${d}/haven/test/lints/fixture_test.dart" <<'DART'
void main() {
  group('outer', () {
    test(
      'a name split across two lines with adjacent-string '
      'concatenation, asserted as Haven\u2019s own fact',
      () {
        expect(1, 1);
      },
    );

    testWidgets('skipped by argument', (tester) async {
      expect(1, 1);
    }, skip: 'not on this runner');
  });

  group('gated', skip: 'arb absent', () {
    test('inside a skipped group', () {
      expect(1, 1);
    });
  });
}
DART

  cat > "${d}/haven/integration_test/fixture_it_test.dart" <<'DART'
void main() {
  testWidgets('runs for real', (tester) async {
    expect(1, 1);
  });

  testWidgets('escapes on a keyring miss', (tester) async {
    if (!hasKeyring) {
      markTestSkipped('no keyring');
      return;
    }
    expect(1, 1);
  });
}
DART

  cat > "${d}/docs/privacy/privacy_invariants.json" <<'JSON'
{
  "schema_version": 1,
  "pinned_dependencies": { "mdk_rev": "e391adc133a9b60e420da7a0446f014a180ac8d2" },
  "accepted_deviations": [
    { "id": "P6", "source": "haven-core/SECURITY.md#ip-level-linkage-is-out-of-scope-p6",
      "summary": "No Tor or proxy support.",
      "forbidden_claim": "no network-level anonymity claim" }
  ],
  "non_claim_arb_keys": {
    "privacyHeading": "Section heading; states no fact.",
    "privacyOmission": {
      "reason": "Correct only by omission.",
      "forbidden_additions": ["your public profile is published here"]
    }
  },
  "invariants": [
    {
      "id": "INV-LOCATION-ENCRYPTED",
      "title": "Location leaves encrypted",
      "statement": "No code path publishes a coordinate outside MLS.",
      "status": "enforced",
      "assertion_arb_keys": ["privacyPromise"],
      "disclosure_arb_keys": ["privacyWarning"],
      "non_arb_claims": [
        { "carrier": "ios_infoplist", "id": "NSLocationWhenInUseUsageDescription", "kind": "assertion" },
        { "carrier": "dart_source", "id": "LocationDisclosureStrings.how", "kind": "assertion" }
      ],
      "event_kinds": [
        { "kind": 445, "token": "Kind::Custom(445)", "note": "group message" },
        { "kind": 0, "token": "EventBuilder::metadata", "note": "profile" }
      ],
      "doc_anchors": ["haven-core/SECURITY.md#network-threat-model"],
      "symbols": [ { "file": "haven-core/src/probe.rs", "symbol": "fn build_group_event" } ],
      "tests": [ { "file": "haven-core/tests/fixture_tests.rs", "name": "good_proof" } ],
      "guards": ["scripts/ci/check_wired.sh"]
    },
    {
      "id": "INV-NO-ANONYMITY",
      "title": "No network anonymity",
      "statement": "Relays observe the device IP on every publish.",
      "status": "accepted_deviation",
      "accepted_deviation_id": "P6",
      "disclosure_arb_keys": ["privacyWarning"],
      "attributed_arb_keys": ["privacyThirdParty"],
      "non_arb_claims": [
        { "carrier": "dart_source", "id": "LocationDisclosureStrings.why", "kind": "disclosure" }
      ],
      "guards": ["scripts/ci/check_wired.sh"]
    }
  ]
}
JSON
}

_manifest_edit() { # _manifest_edit <repo> <jq-filter>
  local repo="$1" filter="$2" tmp
  tmp="$(mktemp)"
  jq "${filter}" "${repo}/docs/privacy/privacy_invariants.json" > "${tmp}"
  mv "${tmp}" "${repo}/docs/privacy/privacy_invariants.json"
}

# All checks except the floors and the ratchet, which have their own fixtures.
_check_tree() { # _check_tree <repo>
  local r="$1" m="$1/docs/privacy/privacy_invariants.json" rc=0
  check_invariant_rules "${m}" || rc=1
  check_symbols "${m}" "${r}" || rc=1
  check_tests "${m}" "${r}" "${r}/scripts/ci/expected_test_skips.txt" || rc=1
  check_guards "${m}" "${r}" "${r}/.github/workflows/repo-guards.yml" || rc=1
  check_arb_coverage "${m}" "${r}/haven/lib/l10n/app_en.arb" \
    "${r}/haven/ios/Runner/Info.plist" \
    "${r}/haven/lib/src/widgets/location/location_disclosure_dialog.dart" || rc=1
  check_event_kinds "${m}" "${r}" "${r}/haven-core/Cargo.toml" || rc=1
  check_doc_anchors "${m}" "${r}" || rc=1
  return "${rc}"
}

_fixture() { # _fixture <label> <want-rc> <want-tag> <jq-filter-or-empty> [shell-mutation]
  local label="$1" want="$2" tag="$3" filter="$4" mutation="${5:-}"
  local repo="${SELFTEST_TMP}/case-${FIXTURES}"
  cp -r "${SELFTEST_TMP}/base" "${repo}"
  [[ -z "${filter}" ]] || _manifest_edit "${repo}" "${filter}"
  [[ -z "${mutation}" ]] || ( cd "${repo}" && eval "${mutation}" )
  _expect "${label}" "${want}" "${tag}" _check_tree "${repo}"
}

# A manifest of exactly the given shape, built from NUMBERS rather than from
# the floor constants. The floors fixtures used to be written as
# `jq -n --argjson n "${FLOOR_INVARIANTS}"`, which can only ever prove
# `FLOOR >= 2`: setting every floor to 2 kept the self-test green while a
# manifest gutted to a fifth of its size sailed through.
_floors_manifest() { # _floors_manifest <out> <inv> <arb> <kinds> <guards> <tests> <docs>
  jq -n --argjson n "$2" --argjson k "$3" --argjson e "$4" --argjson g "$5" \
        --argjson t "$6" --argjson d "$7" '
    { schema_version: 1,
      non_claim_arb_keys: ( [range($k) | {key: "k\(.)", value: "reason"}] | from_entries ),
      invariants: [ range($n) | {
        id: "INV-\(.)", status: "enforced",
        event_kinds: (if . < $e then [{kind: ., token: "t\(.)"}] else [] end),
        guards: (if . < $g then ["scripts/ci/g\(.).sh"] else [] end),
        tests: (if . < $t then [{file: "f\(.).rs", name: "n\(.)"}] else [] end),
        doc_anchors: (if . < $d then ["docs/d\(.).md#h"] else [] end)
      } ] }' > "$1"
}

# A two-commit git repository: the manifest lands at <baseline-rel> in the
# first commit and at <head-rel> in the second, edited by <jq-filter>. Used to
# drive `read_baseline`, which is where "the manifest moved" was being read as
# "the manifest is new".
_mkgitrepo() { # _mkgitrepo <dir> <baseline-rel> <head-rel> <jq-filter>
  local d="$1" base_rel="$2" head_rel="$3" filter="$4"
  require_git
  local -a git=(git -C "${d}" -c user.email=selftest@example.invalid -c user.name=selftest
                -c commit.gpgsign=false -c core.hooksPath=/dev/null)
  mkdir -p "${d}"
  git init -q -b main "${d}" 2>/dev/null || git init -q "${d}"
  if [[ -n "${base_rel}" ]]; then
    mkdir -p "${d}/${base_rel%/*}"
    cp "${SELFTEST_TMP}/base/docs/privacy/privacy_invariants.json" "${d}/${base_rel}"
  else
    printf 'placeholder\n' > "${d}/README.md"
  fi
  "${git[@]}" add -A
  "${git[@]}" commit -q -m "baseline" --no-verify
  [[ -z "${base_rel}" ]] || rm -f "${d}/${base_rel}"
  mkdir -p "${d}/${head_rel%/*}"
  jq "${filter}" "${SELFTEST_TMP}/base/docs/privacy/privacy_invariants.json" > "${d}/${head_rel}"
  "${git[@]}" add -A
  "${git[@]}" commit -q -m "head" --no-verify
}

# Runs the ratchet the way main() does — through read_baseline — inside a
# subshell, so the REPO_ROOT/MANIFEST_REL overrides never escape.
_ratchet_through_baseline() { # _ratchet_through_baseline <repo> <head-rel>
  REPO_ROOT="$1"
  MANIFEST_REL="$2"
  local bp
  bp="$(read_baseline "HEAD~1" "$1/baseline-read.json")"
  check_ratchet "$1/$2" "${bp}"
}

# The claim-language sweep with its phrase list gutted: the assignment lives
# inside the function because `_expect` runs it in a subshell.
_claim_list_gutted() { # _claim_list_gutted <repo>
  CLAIM_LANGUAGE=('never')
  check_arb_coverage "$1/docs/privacy/privacy_invariants.json" "$1/haven/lib/l10n/app_en.arb" \
    "$1/haven/ios/Runner/Info.plist" \
    "$1/haven/lib/src/widgets/location/location_disclosure_dialog.dart"
}

self_test() {
  require_jq
  SELFTEST_TMP="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${SELFTEST_TMP}'" RETURN
  _mkrepo "${SELFTEST_TMP}/base"

  log "self-test: the manifest describes its tree"
  _fixture "a fully-connected manifest passes" 0 - ""

  log "self-test: rule 1 — ids"
  _fixture "duplicate invariant id fails" 1 '[rule 1]' \
    '.invariants += [.invariants[0]]'
  _fixture "malformed invariant id fails" 1 '[rule 1]' \
    '.invariants[0].id = "inv_lowercase"'
  _fixture "unknown status fails" 1 '[rule 1]' \
    '.invariants[0].status = "mostly"'

  log "self-test: rule 2 — symbols"
  _fixture "missing symbol file fails" 1 '[rule 2]' \
    '.invariants[0].symbols[0].file = "haven-core/src/gone.rs"'
  _fixture "renamed symbol fails" 1 '[rule 2]' \
    '.invariants[0].symbols[0].symbol = "fn build_group_message"'
  _fixture "a symbol matched only as a SUBSTRING fails" 1 '[rule 2]' \
    '.invariants[0].symbols[0].symbol = "fn build_group"'
  # The residue a rename really leaves. Scanned as raw text, the comment IS the
  # symbol and this passed.
  _fixture "*** a rename alibied by a comment naming the old symbol fails ***" 1 '[rule 2]' "" \
    "sed 's|fn build_group_event|fn emit_group_event|' haven-core/src/probe.rs > p.rs && mv p.rs haven-core/src/probe.rs && printf '// Renamed from build_group_event; call sites updated.\n' >> haven-core/src/probe.rs"
  # ...but a symbol that IS a string literal is still a symbol: the OSM
  # endpoint is cited precisely as the host that must not become the default.
  _fixture "a cited symbol living in a string literal passes" 0 - \
    '.invariants[0].symbols[0] = {"file": "haven-core/src/probe.rs", "symbol": "tile.openstreetmap.org"}'

  log "self-test: rules 3-5 — tests"
  _fixture "missing test file fails" 1 '[rule 3]' \
    '.invariants[0].tests[0].file = "haven-core/tests/gone.rs"'
  _fixture "undeclared test name fails" 1 '[rule 3]' \
    '.invariants[0].tests[0].name = "no_such_proof"'
  _fixture "a plain fn cited as a test fails" 1 '[rule 3]' \
    '.invariants[0].tests[0].name = "helper_not_a_test"'
  # CRITICAL: the cited proof does not run. Its file also carries a PROSE
  # comment mentioning `#[ignore]`, which a naive grep reads as an attribute.
  # Its body asserts for real, so ONLY rule 4 can produce this verdict.
  _fixture "*** an #[ignore]d test fails ***" 1 '[rule 4]' \
    '.invariants[0].tests[0].name = "ignored_proof"'
  _fixture "a prose #[ignore] above a running test does NOT fail" 0 - \
    '.invariants[0].tests[0].name = "good_proof"'
  _fixture "a tautological test fails" 1 '[rule 5]' \
    '.invariants[0].tests[0].name = "tautological_proof"'
  _fixture "a test in expected_test_skips.txt fails" 1 '[rule 4]' \
    '.invariants[0].tests[0].name = "skipped_by_manifest"'
  # CRITICAL: the canonical gutting. The assertions are commented out and the
  # comment still contains the word `assert`, which the raw-text scan accepted
  # while the proof it stood for was gone.
  _fixture "*** a test gutted by commenting its assertions out fails ***" 1 '[rule 5]' "" \
    "sed 's|    assert_eq!(1 + 1, 2);|    let _g = 1; // We used to assert here that the content is ciphertext.|' haven-core/tests/fixture_tests.rs > t.rs && mv t.rs haven-core/tests/fixture_tests.rs"
  _fixture "an assertion surviving only inside a string literal fails" 1 '[rule 5]' "" \
    "sed 's|    assert_eq!(1 + 1, 2);|    let _s = \"assert_eq!(1 + 1, 2)\";|' haven-core/tests/fixture_tests.rs > t.rs && mv t.rs haven-core/tests/fixture_tests.rs"
  # Dart splits long test names across adjacent literals and escapes their
  # punctuation, so the joined, DECODED name is what the reporter prints and
  # what a manifest cites. A naive `test('<name>'` grep reports every one of
  # them as missing — `background_claim_accuracy_test.dart:433` is exactly this
  # shape, escape included.
  _fixture "a split-literal Dart name with an escape resolves and passes" 0 - \
    '.invariants[0].tests[0] = {"file": "haven/test/lints/fixture_test.dart", "name": "a name split across two lines with adjacent-string concatenation, asserted as Haven’s own fact"}'
  _fixture "...and a Dart name that genuinely does not exist still fails" 1 '[rule 3]' \
    '.invariants[0].tests[0] = {"file": "haven/test/lints/fixture_test.dart", "name": "a name split across two lines with adjacent-string concatenation"}'
  _fixture "a Dart skip: argument fails" 1 '[rule 4]' \
    '.invariants[0].tests[0] = {"file": "haven/test/lints/fixture_test.dart", "name": "skipped by argument"}'
  _fixture "a skipped enclosing group fails" 1 '[rule 4]' \
    '.invariants[0].tests[0] = {"file": "haven/test/lints/fixture_test.dart", "name": "inside a skipped group"}'
  _fixture "an integration test calling markTestSkipped fails" 1 '[rule 4]' \
    '.invariants[0].tests[0] = {"file": "haven/integration_test/fixture_it_test.dart", "name": "escapes on a keyring miss"}'
  _fixture "an integration test with no escape hatch passes" 0 - \
    '.invariants[0].tests[0] = {"file": "haven/integration_test/fixture_it_test.dart", "name": "runs for real"}'

  log "self-test: rules 6/6b — guard wiring"
  _fixture "a cited guard that does not exist fails" 1 '[rule 6]' \
    '.invariants[0].guards = ["scripts/ci/check_absent.sh"]'
  # CRITICAL: the orphaned-tile-cache shape. The script exists, is NAMED in the
  # workflow header, and is echoed as a tip inside a neighbouring step — three
  # textual hits for a guard that runs nowhere.
  _fixture "*** an existing but UNWIRED guard fails ***" 1 '[rule 6]' \
    '.invariants[0].guards = ["scripts/ci/check_orphan.sh"]'
  # The same failure with the step DELETED rather than never written: the only
  # surviving mention is `echo "Tip: run bash …"` in the next step along.
  _fixture "*** a guard whose only mention is an echoed tip fails ***" 1 '[rule 6]' "" \
    "grep -v 'run: bash scripts/ci/check_wired.sh' .github/workflows/repo-guards.yml | sed 's|check_orphan.sh yourself|check_wired.sh yourself|' > w.yml && mv w.yml .github/workflows/repo-guards.yml"
  _fixture "*** a guard step disabled by if: false fails ***" 1 '[rule 6]' "" \
    "awk '/- name: Wired guard/ { w = 1 } w && /^ *if:/ { print \"        if: \${{ false }}\"; w = 0; next } { print }' .github/workflows/repo-guards.yml > w.yml && mv w.yml .github/workflows/repo-guards.yml"
  _fixture "*** a guard step marked continue-on-error fails ***" 1 '[rule 6]' "" \
    "awk '/run: bash scripts\/ci\/check_wired.sh/ { print \"        continue-on-error: true\" } { print }' .github/workflows/repo-guards.yml > w.yml && mv w.yml .github/workflows/repo-guards.yml"
  # CRITICAL: wired, but only as its own --self-test.
  _fixture "*** a self-test-only wiring fails ***" 1 '[rule 6b]' \
    '.invariants[0].guards = ["scripts/ci/check_selftest_only.sh"]'
  _fixture "...and passes once it names the enforcing workflow" 0 - \
    '.invariants[0].guards = ["scripts/ci/check_selftest_only.sh#workflow=coverage.yml"]'
  _fixture "a #workflow= naming a file that does not run it fails" 1 '[rule 6]' \
    '.invariants[0].guards = ["scripts/ci/check_wired.sh#workflow=coverage.yml"]'
  # `#workflow=` took ANY path: a Markdown handbook with a fenced `bash …`
  # block satisfied a citation, and so did `../../` out of the workflows
  # directory entirely.
  _fixture "a #workflow= naming a Markdown document fails" 1 '[rule 6b]' \
    '.invariants[0].guards = ["scripts/ci/check_selftest_only.sh#workflow=../../docs/HANDBOOK.md"]'
  _fixture "a #workflow= carrying a directory part fails" 1 '[rule 6b]' \
    '.invariants[0].guards = ["scripts/ci/check_selftest_only.sh#workflow=sub/coverage.yml"]'
  # A manual-only workflow runs on no PR, which is precisely the "proves
  # nothing about this change" case 6b exists for.
  _fixture "*** a #workflow= naming a workflow_dispatch-only workflow fails ***" 1 '[rule 6b]' \
    '.invariants[0].guards = ["scripts/ci/check_selftest_only.sh#workflow=manual-only.yml"]'
  _fixture "a guard workflow no push/pull_request reaches fails" 1 '[rule 6]' "" \
    "rm .github/workflows/ci.yml"
  _fixture "a workflow with no guard steps at all fails" 1 '[rule 6]' "" \
    "printf 'name: Repo Guards\n' > .github/workflows/repo-guards.yml"

  log "self-test: rules 7/8/9/11 — status obligations"
  _fixture "'enforced' with no test and no guard fails" 1 '[rule 7]' \
    '.invariants[0].tests = [] | .invariants[0].guards = []'
  _fixture "'ratcheted' without a residual fails" 1 '[rule 8]' \
    '.invariants[0].status = "ratcheted"'
  _fixture "'ratcheted' with a residual passes" 0 - \
    '.invariants[0].status = "ratcheted" | .invariants[0].residual = "Padding is absent, so sizes remain fingerprintable."'
  # An assertion with no proof at all, under a status that satisfies rule 7's
  # obligation — so only rule 11 can produce this verdict.
  _fixture "an assertion backed by no test and no guard fails" 1 '[rule 11]' \
    '.invariants[0].status = "ratcheted"
     | .invariants[0].residual = "The Android service is a plain timer and cannot see movement."
     | .invariants[0].tests = [] | .invariants[0].guards = []'
  # CRITICAL — E3's core rule. The invariant cites a guard, so rule 11 is
  # satisfied and rule 9 is the only rule that can red this.
  _fixture "*** an accepted deviation carrying an assertion key fails ***" 1 '[rule 9]' \
    '.invariants[1].assertion_arb_keys = ["privacyPromise"]'
  _fixture "an accepted deviation disclosing nothing fails" 1 '[rule 9]' \
    '.invariants[1].disclosure_arb_keys = [] | .invariants[1].non_arb_claims = []'
  _fixture "an accepted deviation citing an unknown deviation id fails" 1 '[rule 9]' \
    '.invariants[1].accepted_deviation_id = "P99"'
  _fixture "an unknown non_arb_claims carrier fails" 1 '[rule 1]' \
    '.invariants[0].non_arb_claims[0].carrier = "billboard"'
  _fixture "an unknown non_arb_claims kind fails" 1 '[rule 1]' \
    '.invariants[0].non_arb_claims[0].kind = "vibes"'
  # A non-ARB string that claims nothing (a heading, a button label) is
  # classified `none` WITH A REASON — and that classification buys nothing
  # anywhere else.
  _fixture "a 'none' non_arb_claim with a reason passes" 0 - \
    '.invariants[0].non_arb_claims += [{"carrier": "dart_source", "id": "LocationDisclosureStrings.agree", "kind": "none", "reason": "Button label; states no fact."}]'
  _fixture "a 'none' non_arb_claim without a reason fails" 1 '[rule 1]' \
    '.invariants[0].non_arb_claims += [{"carrier": "dart_source", "id": "LocationDisclosureStrings.agree", "kind": "none"}]'
  _fixture "*** 'none' cannot satisfy an accepted deviation's disclosure duty ***" 1 '[rule 9]' \
    '.invariants[1].disclosure_arb_keys = []
     | .invariants[1].non_arb_claims[0].kind = "none"
     | .invariants[1].non_arb_claims[0].reason = "Reclassified to dodge the disclosure requirement."'

  log "self-test: rules 10/12 — claim coverage"
  _fixture "an assertion key absent from the ARB fails" 1 '[rule 10]' \
    '.invariants[0].assertion_arb_keys = ["privacyGhost"]'
  _fixture "an unclassified privacy* key fails" 1 '[rule 12]' \
    'del(.non_claim_arb_keys.privacyHeading)'
  _fixture "a key both claimed and declared non-claim fails" 1 '[rule 12]' \
    '.non_claim_arb_keys.privacyPromise = "contradiction"'
  # The false-positive direction that matters most: ~24 strings promise and
  # warn in one paragraph, so one key is an assertion under one invariant and a
  # disclosure under another BY DESIGN.
  _fixture "the same key as assertion here and disclosure there passes" 0 - \
    '.invariants[1].disclosure_arb_keys += ["privacyPromise"]'
  _fixture "a non_claim key absent from the ARB fails" 1 '[rule 12]' \
    '.non_claim_arb_keys.privacyPhantom = "gone"'
  _fixture "a non_claim entry with no reason fails" 1 '[rule 12]' \
    '.non_claim_arb_keys.privacyHeading = ""'
  _fixture "an undeclared iOS usage description fails" 1 '[rule 12]' \
    '.invariants[0].non_arb_claims[0].id = "NSSomethingElseUsageDescription"'
  _fixture "an undeclared consent-dialog field fails" 1 '[rule 12]' \
    '.invariants[1].non_arb_claims[0].id = "LocationDisclosureStrings.gone"'
  # Load-bearing BY OMISSION: honest only because of what it does not say.
  _fixture "a forbidden clause added to an omission string fails" 1 '[rule 12]' "" \
    "jq '.privacyOmission = \"Key packages are published here, and your public profile is published here too.\"' haven/lib/l10n/app_en.arb > a && mv a haven/lib/l10n/app_en.arb"
  _fixture "an ARB with no privacy* key at all fails" 1 '[rule 12]' "" \
    "jq 'with_entries(select(.key | startswith(\"privacy\") | not))' haven/lib/l10n/app_en.arb > a && mv a haven/lib/l10n/app_en.arb"
  # CRITICAL: the prefix sweep saw two thirds of the register. A promise under
  # an `onboarding*` key — the screens where the user is deciding whether to
  # trust the app at all — landed unclassified and green.
  _fixture "*** a claim under a non-privacy* key must be classified ***" 1 '[rule 12]' "" \
    "jq '.onboardingWeNeverSeeYourLocation = \"We never see your location. Ever.\"' haven/lib/l10n/app_en.arb > a && mv a haven/lib/l10n/app_en.arb"
  _fixture "...while a plain UI string under a new key needs no classification" 0 - "" \
    "jq '.settingsSaveLabel = \"Save changes\"' haven/lib/l10n/app_en.arb > a && mv a haven/lib/l10n/app_en.arb"
  _expect "a gutted claim-language phrase list fails" 1 '[rule 12]' \
    _claim_list_gutted "${SELFTEST_TMP}/base"

  log "self-test: rule 13 — event kinds"
  _fixture "an undeclared construction token fails" 1 '[rule 13]' \
    '.invariants[0].event_kinds = [{"kind": 445, "token": "Kind::Custom(445)", "note": "x"}]'
  _fixture "a NEW production token fails even at a known kind number" 1 '[rule 13]' "" \
    "printf 'let e = EventBuilder::delete(request);\n' >> haven-core/src/probe.rs"
  # `impl From<u16> for Kind` is the pinned nostr crate's primary constructor.
  # Requiring an uppercase letter after `Kind::` walked past both of its
  # spellings, so a whole new kind could be built with neither declared.
  _fixture "*** Kind::from(31337_u16) is a construction token ***" 1 '[rule 13]' "" \
    "printf 'pub fn from_ctor() { let _k = Kind::from(31337_u16); }\n' >> haven-core/src/probe.rs"
  _fixture "*** 31337_u16.into() is a construction token ***" 1 '[rule 13]' "" \
    "printf 'pub fn into_ctor() { let _k: Kind = 31337_u16.into(); }\n' >> haven-core/src/probe.rs"
  _fixture "a decoy kind inside #[cfg(test)] does NOT fail" 0 - "" \
    "printf '#[cfg(test)]\nmod more {\n    fn d() { EventBuilder::new(Kind::Custom(9999), \"x\"); }\n}\n' >> haven-core/src/probe.rs"
  _fixture "an MDK rev bump without a manifest re-derivation fails" 1 '[rule 13]' "" \
    "sed -i 's/e391adc133a9b60e420da7a0446f014a180ac8d2/0000000000000000000000000000000000000000/g' haven-core/Cargo.toml"
  _fixture "a missing mdk_rev pin fails" 1 '[rule 13]' 'del(.pinned_dependencies)'
  _fixture "a tree with no production Rust at all fails" 1 '[rule 13]' "" \
    "rm -rf haven-core/src && mkdir -p haven-core/src"

  log "self-test: rule 15 — cited documentation resolves"
  _fixture "a heading carrying a colon, an em dash and a code span resolves" 0 - \
    '.invariants[0].doc_anchors = ["haven-core/SECURITY.md#outer-kind445-metadata--group-governed-nip-40-expiration"]'
  # CRITICAL — the IOS-KEYCHAIN shape: a plausible anchor for a passage that
  # really exists but is not a HEADING, so the citation lands nowhere and the
  # deviation reads as undocumented.
  _fixture "*** a dangling #fragment fails ***" 1 '[rule 15]' \
    '.accepted_deviations[0].source = "haven-core/SECURITY.md#ip-level-linkage-owner-approved-tradeoff"'
  _fixture "a doc_anchor naming a file that does not exist fails" 1 '[rule 15]' \
    '.invariants[0].doc_anchors = ["haven-core/GONE.md#network-threat-model"]'
  _fixture "a source with no #fragment still validates the file" 0 - \
    '.accepted_deviations[0].source = "haven-core/SECURITY.md"'
  _fixture "...and a file-only source naming no such file fails" 1 '[rule 15]' \
    '.accepted_deviations[0].source = "haven-core/GONE.md"'
  # A `#` comment inside a fenced block is not a heading — SECURITY.md's
  # dependency-audit block has three, and reading them as headings would mint
  # anchors nobody wrote for a dead citation to resolve against.
  _fixture "a shell comment inside a fenced block is not a heading" 1 '[rule 15]' \
    '.invariants[0].doc_anchors = ["haven-core/SECURITY.md#not-a-heading-a-shell-comment-inside-a-fenced-block"]'
  # GitHub disambiguates repeated slugs with -1/-2, which is what a reviewer
  # copying the anchor out of the browser pastes into the manifest.
  _fixture "a repeated heading resolves at its -1 suffix" 0 - \
    '.invariants[0].doc_anchors = ["haven-core/SECURITY.md#repeated-heading-1"]'
  _fixture "...and a suffix past the number of repeats fails" 1 '[rule 15]' \
    '.invariants[0].doc_anchors = ["haven-core/SECURITY.md#repeated-heading-2"]'
  # Anti-vacuity: an extractor reading nothing must be a distinct failure, not
  # a citation quietly reported as dead against an empty heading set.
  _fixture "a document that yields no heading at all fails its citations" 1 '[rule 15]' "" \
    "printf 'Prose only, with no heading anywhere in it.\n' > haven-core/SECURITY.md"

  log "self-test: rule 14 — anti-vacuity floors"
  local floors_fat="${SELFTEST_TMP}/floors-fat.json"
  local floors_thin="${SELFTEST_TMP}/floors-thin.json"
  local floors_gutted="${SELFTEST_TMP}/floors-gutted.json"
  _floors_manifest "${floors_fat}"    500 500 50 50 500 50
  _floors_manifest "${floors_thin}"     1   1  1  1   1  1
  # The demonstrated gutting: 60 of the 81 invariants deleted, their kinds
  # reattached and their orphaned ARB keys dumped into `non_claim_arb_keys`, so
  # only the invariant count moves. Every floor was low enough to miss it.
  _floors_manifest "${floors_gutted}"  21 133 14  6  45 22
  _expect "a manifest far above every floor passes" 0 - check_floors "${floors_fat}"
  _expect "a manifest with one of everything fails the floors" 1 '[rule 14]' \
    check_floors "${floors_thin}"
  _expect "*** a manifest gutted to a quarter of its invariants fails ***" 1 '[rule 14]' \
    check_floors "${floors_gutted}"

  log "self-test: the ratchet"
  local base="${SELFTEST_TMP}/base/docs/privacy/privacy_invariants.json"
  local cur="${SELFTEST_TMP}/ratchet-cur.json"
  _ratchet_case() { # _ratchet_case <label> <want> <tag> <jq-filter>
    jq "$4" "${base}" > "${cur}"
    _expect "$1" "$2" "$3" check_ratchet "${cur}" "${base}"
  }
  _ratchet_case "an unchanged manifest passes" 0 - '.'
  _ratchet_case "a deleted invariant fails" 1 '[ratchet]' '.invariants |= .[0:1]'
  _ratchet_case "a status downgrade fails" 1 '[ratchet]' \
    '.invariants[0].status = "ratcheted" | .invariants[0].residual = "partial"'
  # CRITICAL — E3: you cannot silently delete a privacy warning.
  _ratchet_case "*** a deleted disclosure key fails ***" 1 '[ratchet]' \
    '.invariants[0].disclosure_arb_keys = []'
  _ratchet_case "a deleted disclosure-kind non_arb_claim fails" 1 '[ratchet]' \
    '.invariants[1].non_arb_claims = []'
  # Reclassifying a warning as "claims nothing" removes it from the disclosure
  # set, which is the same deletion wearing a different hat.
  _ratchet_case "*** a disclosure downgraded to kind 'none' fails ***" 1 '[ratchet]' \
    '.invariants[1].non_arb_claims[0].kind = "none"
     | .invariants[1].non_arb_claims[0].reason = "Reclassified rather than removed."'
  # CRITICAL — the ARB-side laundering route: the promise is moved out of its
  # invariant and into `non_claim_arb_keys` with a plausible reason. Every rule
  # passed, rule 14's ARB total did not move (non-claim keys count toward it),
  # and the ratchet said nothing.
  _ratchet_case "*** an assertion laundered into non_claim_arb_keys fails ***" 1 '[ratchet]' \
    '.invariants[0].assertion_arb_keys = []
     | .non_claim_arb_keys.privacyPromise = "Reclassified as making no claim."'
  # ...but a promise that merely moves to another invariant is still promised
  # and still proved, so it is not a weakening.
  _ratchet_case "an assertion key moved to another invariant passes" 0 - \
    '.invariants[0].assertion_arb_keys = [] | .invariants[1].assertion_arb_keys = ["privacyPromise"]'
  _ratchet_case "an assertion losing its last backing fails" 1 '[ratchet]' \
    '.invariants[0].tests = [] | .invariants[0].guards = []'
  _ratchet_case "an ADDED disclosure key passes" 0 - \
    '.invariants[0].disclosure_arb_keys += ["privacyHeading"]'
  _ratchet_case "a declared override allows the weakening" 0 - \
    '.invariants[0].disclosure_arb_keys = []
     | .ratchet_override = {reason: "The relay-IP warning moved into the consent dialog verbatim; see PR discussion.", items: ["INV-LOCATION-ENCRYPTED.disclosure:privacyWarning"]}'
  _ratchet_case "an override with too short a reason fails" 1 '[ratchet]' \
    '.invariants[0].disclosure_arb_keys = []
     | .ratchet_override = {reason: "moved", items: ["INV-LOCATION-ENCRYPTED.disclosure:privacyWarning"]}'
  # CRITICAL — a stale allowance means the proof it guarded is already gone.
  _ratchet_case "*** a STALE override item fails ***" 1 '[ratchet]' \
    '.ratchet_override = {reason: "This allowance outlived the change it was written for entirely.", items: ["INV-LOCATION-ENCRYPTED.disclosure:privacyWarning"]}'
  _expect "an absent baseline manifest ratchets vacuously" 0 - check_ratchet "${base}" ""

  log "self-test: the ratchet's baseline — new versus MOVED"
  # CRITICAL: renaming the manifest (a one-line edit here and a `git mv` there)
  # turned a real deletion from rc=1 into rc=0, because a baseline with no file
  # at MANIFEST_REL was read as "this commit introduces the manifest".
  local moved="${SELFTEST_TMP}/git-moved"
  _mkgitrepo "${moved}" "docs/privacy/privacy_invariants.json" "docs/privacy/invariants.json" \
    '.invariants |= .[0:1]'
  _expect "*** a deletion hidden behind a RENAMED manifest still fails ***" 1 '[ratchet]' \
    _ratchet_through_baseline "${moved}" "docs/privacy/invariants.json"
  # ...and the genuine first landing stays green, announced rather than silent.
  local landing="${SELFTEST_TMP}/git-landing"
  _mkgitrepo "${landing}" "" "docs/privacy/privacy_invariants.json" '.'
  _expect "the commit that introduces the manifest ratchets vacuously" 0 - \
    _ratchet_through_baseline "${landing}" "docs/privacy/privacy_invariants.json"

  if (( FIXTURES != EXPECTED_FIXTURES )); then
    fail_msg "self-test ran ${FIXTURES} fixtures, expected ${EXPECTED_FIXTURES}. An exact \
pin, not a floor: five fixtures — two of them CRITICAL — were once deleted with the count \
still printing green. Update EXPECTED_FIXTURES in the commit that adds or removes one."
    SELFTEST_FAILS=1
  fi
  if (( SELFTEST_FAILS )); then
    fail_msg "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (${FIXTURES} fixtures)."
}

# ---------------------------------------------------------------------------
main() {
  local baseline_ref="origin/main" ratchet=1
  while (( $# > 0 )); do
    case "$1" in
      --self-test) self_test; exit 0 ;;
      --baseline-ref) shift; [[ $# -gt 0 ]] || misconfig "--baseline-ref needs a ref"; baseline_ref="$1" ;;
      --no-ratchet) ratchet=0 ;;
      -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) misconfig "usage: ${SCRIPT_NAME}.sh [--baseline-ref <ref>] [--no-ratchet] | --self-test" ;;
    esac
    shift
  done

  require_jq
  local manifest="${REPO_ROOT}/${MANIFEST_REL}"
  [[ -f "${manifest}" ]] || misconfig "${MANIFEST_REL} not found — this guard is the \
enforcement half of that manifest and has nothing to check without it."

  local arb="${REPO_ROOT}/haven/lib/l10n/app_en.arb"
  local plist="${REPO_ROOT}/haven/ios/Runner/Info.plist"
  local ddart="${REPO_ROOT}/haven/lib/src/widgets/location/location_disclosure_dialog.dart"
  local wf="${REPO_ROOT}/.github/workflows/repo-guards.yml"
  local skips="${REPO_ROOT}/scripts/ci/expected_test_skips.txt"
  local cargo="${REPO_ROOT}/haven-core/Cargo.toml"

  local rc=0
  check_invariant_rules "${manifest}" || rc=1
  check_symbols "${manifest}" "${REPO_ROOT}" || rc=1
  check_tests "${manifest}" "${REPO_ROOT}" "${skips}" || rc=1
  check_guards "${manifest}" "${REPO_ROOT}" "${wf}" || rc=1
  check_arb_coverage "${manifest}" "${arb}" "${plist}" "${ddart}" || rc=1
  check_event_kinds "${manifest}" "${REPO_ROOT}" "${cargo}" || rc=1
  check_doc_anchors "${manifest}" "${REPO_ROOT}" || rc=1
  check_floors "${manifest}" || rc=1

  if (( ratchet )); then
    local baseline_file baseline_path
    baseline_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${baseline_file}'" EXIT
    baseline_path="$(read_baseline "${baseline_ref}" "${baseline_file}")"
    check_ratchet "${manifest}" "${baseline_path}" || rc=1
  else
    printf '  [ratchet] SKIPPED (--no-ratchet) — local use only; CI always ratchets.\n'
  fi

  if (( rc == 0 )); then
    log "OK: the privacy-invariant manifest describes this repository."
    exit 0
  fi
  fail_msg "the privacy-invariant manifest no longer describes this repository (see above)."
  exit 1
}

main "$@"
