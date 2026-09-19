#!/usr/bin/env bash
# CI guard: no energy claim in Haven's code or CI may read as a measurement.
#
# ## Why this exists
#
# The power-efficiency programme has no hardware (`docs/POWER_EFFICIENCY_PLAN.md`
# §2.5: no iPhone, no macOS machine, no Android handset for the duration), so
# EVERY battery figure in this tree is an output of **estimation model E**
# (§6.5a) — arithmetic over published third-party inputs (E-I1…E-I11) and
# declared parameters (E-P1…E-P3). The rule, set 2026-08-30 (L-31/L-34), is that
# no estimate anywhere may read as a measurement.
#
# That rule was enforced by a manual sweep TWICE, and an adversarial review
# found three whole classes both sweeps had missed. The reason is structural:
# before this file, `grep -rn ESTIMATED scripts/ .github/` returned nothing.
# Every comparable invariant here has a guard — `check_no_exporter_label_override.sh`,
# `check_profile_privacy_boundaries.sh`, `check_android_location_power.sh` — and
# an invariant with no guard regresses. This one had already regressed twice.
#
# The failure mode is **estimate creep** (§5.0 names it): a figure produced by
# §6.5a's arithmetic, restated three documents later in a code comment, a test
# `reason:` or a lane header, with its `ESTIMATED` tag lost in transit. At the
# far site nobody expects a battery figure, no model is in view, and the reader
# has no way to tell a prediction from a result.
#
# ## What is checked
#
#   1. ENERGY-CLAIM ATTRIBUTION. Every energy claim carries, within REACH (see
#      below), either an ESTIMATE marker anchored to model E, a NAMED
#      INSTRUMENT for a genuine measurement, or a NAMED PLATFORM SOURCE for a
#      duty that is what the platform's own code does. Both the numeric shapes
#      (%/h, mA, joules, watts, wakes/h, a percent next to a time unit, a
#      battery delta, a before/after pair) and the two prose shapes the manual
#      sweeps missed:
#        * ZERO-COST VERDICTS — "no new battery cost", "negligible battery",
#          "adding no extra battery cost". An energy claim wearing a negation is
#          still an energy claim, and it is the one shape a `%/h` grep can never
#          see.
#        * DIRECTIONAL CLAIMS — "the dominant iOS drain", "the dominant cost of
#          a background cycle". A superlative over energy terms is a claim about
#          their relative magnitude, i.e. an arithmetic result, and model E's
#          own finding 2 contradicts the ones that were in the tree ("the radio
#          term is the widest uncertainty on both platforms — wider than the
#          location term").
#
#   2. INSTRUMENT-CITATION LIVENESS. A paragraph that calls something a
#      measurement and cites a test file as its source must cite a file that
#      EXISTS and is not a tombstone. `config.rs` cited
#      `tests/settle_window_real_relay_test.rs` as "the authoritative real-relay
#      MEASUREMENT … p50 ~= 104 ms" for weeks after that file became a 23-line
#      `DELETED-WITH-SUBJECT` header — a measurement with no instrument behind
#      it, which check 1 alone cannot see because the citation LOOKS like
#      attribution. A tombstoned citation is permitted only when the CITING
#      SENTENCE says so (HISTORICAL / DELETED / "no longer" / …).
#
# ## The text model: three units, and which check uses which
#
# These claims are written as 80-column wrapped comments, so a per-LINE grep
# splits them mid-sentence: "the difference between ~1 % and ~29 %" sits on one
# line and "of the time at Best" on the next, and every line-oriented pattern
# misses it. That is why the scanner works on joined text, in three units:
#
#   * LINE — comment leaders (`///`, `//!`, `//`, `#`, `*`) stripped.
#   * BLOCK — a maximal run of non-blank lines of ONE KIND (all comment, or all
#     code). A bare `///` or `#` ends a block, which is exactly how these doc
#     comments already separate paragraphs. This is the ATTRIBUTION unit.
#   * SENTENCE — a run inside a block ending at `.`/`!`/`?` + whitespace. This
#     is the DETECTION unit: a claim wrapped over six lines is ONE string no
#     matter where it wraps, so no scan window can be "too narrow" for this
#     tree's prose style, and two figures only form a before/after pair when
#     they are in one sentence.
#
# DETECTION crosses a paragraph break in one case only: consecutive COMMENT
# blocks are joined while the earlier one leaves a sentence unterminated,
# because a break in the middle of a sentence is not a paragraph break — the
# split `/// … as much as 59 %` / `///` / `/// of the time …` hid a claim from
# both the paragraph unit and every line window. It never crosses a
# comment↔code transition, so a claim in a doc comment and the code under it
# are never one string.
#
# ## ATTRIBUTION REACH, stated exactly
#
# A claim is attributed when the marker appears in the claim's own sentence, or
# in the sentence immediately before or after it, clipped to the claim's BLOCK
# and to 10 lines either side. Consequences, all deliberate:
#
#   * A tag in the same sentence passes — the ordinary case, an em-dash aside:
#     "up to ~59 % of the time at Best — arithmetic on those two constants, so
#     ESTIMATED and never measured (§6.5a, E-I10)".
#   * A tag in the NEXT sentence passes, and must: `ios_location_source.dart`
#     and `ios_location_source_test.dart` both write "… ~29 % of the time at
#     Best. Both duties are ESTIMATED from the cycle arithmetic". Rejecting
#     that would be a false positive over correct prose.
#   * A tag TWO sentences away does NOT reach. One anchored tag used to exempt
#     every other claim in its paragraph — a tagged claim plus four untagged
#     shapes exited 0 — and in code, where paragraphs break only on a blank
#     line, the old ±10-line window crossed seven `const` declarations to
#     attribute an unrelated `65 wakes/h`.
#   * A tag in another paragraph, or in a comment block on the far side of
#     code, does NOT reach. A reader stopping at the claim never sees it.
#
# The reach is a REACH, not a proof of relevance: one sentence's tag does cover
# its immediate neighbour, so two claims in adjacent sentences are attributed
# by one marker. That is the price of not reddening the prose above.
#
# ## Why no parser
#
# Comment leaders are stripped textually. A real parser would buy the ability
# to skip string literals, and would cost a toolchain in a job that is pure
# grep by design. A test `reason:` string is prose the user can be shown, so
# scanning it is a feature, not a false positive.
#
# ## Scope: check 1 and check 2 have DIFFERENT roots
#
# Check 1's roots are Haven's CODE and CI: Dart, Rust, Kotlin, Swift, shell and
# workflow YAML. `docs/` stays out of check 1, for the reasons it always did:
#
#   * That is where the creep LANDS, not where it starts. All three classes the
#     adversarial review found were outside `docs/`, in comments and test
#     reasons — prose nobody re-reads when the plan is revised.
#   * In `docs/POWER_EFFICIENCY_PLAN.md` the model IS the subject: §6.5a's
#     per-phase table is thirty energy figures in six table rows, where the
#     paragraph unit this guard uses does not correspond to anything. Gating
#     that needs a different unit (a table-cell scanner), not a wider root
#     list. Measured, not assumed: check 1 over `docs/` reports 54 findings,
#     37 of them inside that one section, and the ones outside it are mentions
#     of a unit rather than claims in it — a `%/h` column heading, the
#     `device SoC %/h = (start SoC − end SoC) / hours` formula, a
#     start-of-charge band, "the single largest maintenance cost" (not an energy
#     cost at all). `docs/` is covered by the plan's own P6-B′ sweep item
#     instead — a known, stated gap, not a claim of completeness.
#
# Check 2 DOES cover `docs/` (added 2026-09-09), because it is table-agnostic —
# it reads citations, not figures — and because the exclusion was hiding a real
# finding: `docs/M11_ROLLOUT.md` cited the same tombstoned real-relay suite as
# `config.rs` did, twice, in a paragraph asserting "P-15 real-strfry
# measurement DONE". Inside `docs/` only the TOMBSTONE leg runs; the
# missing-file leg does not, because a plan legitimately names an instrument it
# intends to create (`tests/mesh_sim.rs` in the mesh roadmap,
# `publish_pool_idle_e2e.rs` in P1's test list) and both such citations in this
# tree are prescriptions, not dead references. A code comment has no such
# excuse: it describes what already exists.
#
# ## The allowlist
#
# `estimate_integrity_allowlist.txt` exempts a claim by `path` + a literal
# substring of the claim's SENTENCE — not of a multi-line window, so an entry
# cannot silently cover a neighbouring claim. It is currently EMPTY, and that is
# the intended state: its two entries (a saturated GNSS duty asserted as the
# definitional consequence of `LocationProviderManager.MIN_REQUEST_DELAY_MS`)
# were deleted in favour of PLATFORM-SOURCE attribution, which says the same
# thing in the prose where a reader can check it.
#
# ## What this guard still cannot see
#
#   * A claim with no number and no listed prose shape ("this is easier on the
#     battery" is caught; "this is kinder to the phone" is not).
#   * A wrong figure. It checks attribution, never arithmetic.
#   * A tag that lies: "ESTIMATED (model E)" over a number model E never
#     produced passes here and is caught only by review.
#   * Table cells in `docs/` (check 1 is not run there at all).
#   * A bare integer plus `W` ("543 W Watchdog" in a logcat fixture, "§4 W3" in
#     a plan reference), which is why watts need a decimal, an SI prefix or the
#     word itself.
#   * A duty whose percentage is more than 240 characters from its time noun,
#     or more than 60 in a sentence with no energy context at all.
#   * The difference between a claim and a MENTION of the unit it would be
#     written in. "a %/h figure cannot tell a win from a regression" is the
#     percent-per-time shape with nothing measured or estimated in it; the fix
#     is to name the quantity in words, which is what
#     `summarize-created-at-gaps.sh` now does.
#
# ## Usage
#
#   check_estimate_integrity.sh              # check the tree
#   check_estimate_integrity.sh --self-test  # hermetic fixtures, no repo read
#
# ## Exit codes
#
#   0  every energy claim in scope is attributed
#   1  an unattributed energy claim, a dead instrument citation, or a stale
#      allowlist entry
#   2  misconfiguration (a missing root, an empty slice, an unreadable file, a
#      bad argument) or a failed self-test — this guard fails CLOSED, because a
#      guard that passes when its target was renamed away is worse than none.

set -euo pipefail

readonly SCRIPT_NAME='check_estimate_integrity'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

# Code and CI. See "Scope" above for why `docs/` is not here.
readonly SCAN_ROOTS=(
  'haven/lib'
  'haven/test'
  'haven/integration_test'
  'haven/android'
  'haven/ios'
  'haven/rust_builder/src'
  'haven-core/src'
  'haven-core/tests'
  'scripts'
  'tooling'
  '.github/workflows'
)

# CHECK 2 ONLY, and only its tombstone leg. See "Scope" above.
readonly CITE_EXTRA_ROOTS=('docs')

# Prose-bearing sources only. Generated bindings carry no prose and would only
# add scan time.
readonly SCAN_EXTS=('dart' 'rs' 'kt' 'swift' 'sh' 'yml' 'yaml')
readonly CITE_EXTS=('md')

# This file and its allowlist quote every forbidden shape as a fixture, so they
# are the two files that cannot be scanned. Generated Dart/Rust is excluded for
# the reason above.
readonly EXCLUDE_RE='(^|/)(check_estimate_integrity\.sh|estimate_integrity_allowlist\.txt)$|frb_generated|\.g\.dart$|(^|/)(build|target|\.dart_tool)/'

ALLOWLIST="${REPO_ROOT}/scripts/ci/estimate_integrity_allowlist.txt"

# Set to 1 ONLY by the self-test's non-vacuity inversion: it turns attribution
# off, so a PASS fixture must then FAIL. A fixture whose body was gutted passes
# both ways, which is what makes the inversion an assertion.
SCAN_NO_ATTR=0

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
bad()  { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() {
  printf '\033[1;31m[%s] MISCONFIGURED:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# The scanner. Units and reach are documented in the header; the code below is
# the mechanism only.
# ---------------------------------------------------------------------------
readonly SCANNER_AWK='
function strip_leader(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/^(\/\/\/|\/\/!|\/\/|#+|\*\/|\/\*|\*)[[:space:]]?/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}
function is_comment(s) { return s ~ /^[[:space:]]*(\/\/|#|\*|\/\*)/ }

# Text of lines a..b, blanks skipped, with each line s start offset in off[].
function join_lines(a, b, off,   i, out) {
  out = ""
  for (i = a; i <= b; i++) {
    if (brk[i]) continue
    if (out != "") out = out " "
    off[i] = length(out) + 1
    out = out txt[i]
  }
  return out
}

# Sentence bounds of t into sb[]/se[]; returns the count. A stop is `.`/`!`/`?`
# plus any closers, followed by whitespace. A one-letter token before the stop
# is an abbreviation (`i.e.`, `e.g.`), never the end of a sentence — getting
# that wrong only shrinks the reach, never widens it.
function split_sentences(t, sb, se,   k, start, pos, rest, p, endp, e, len) {
  k = 0; start = 1; pos = 1; len = length(t)
  while (pos <= len) {
    rest = substr(t, pos)
    if (!match(rest, /[.!?][])"`]*[[:space:]]+/)) break
    p = pos + RSTART - 1
    endp = p + RLENGTH - 1
    pos = endp + 1
    if (p >= 3 && substr(t, p - 2, 1) == "." && substr(t, p - 1, 1) ~ /[A-Za-z]/) continue
    e = endp
    while (e > p && substr(t, e, 1) ~ /[[:space:]]/) e--
    k++; sb[k] = start; se[k] = e
    start = pos
  }
  if (start <= len) { k++; sb[k] = start; se[k] = len }
  return k
}

# --- energy nouns, in the two grades the shapes need ----------------------
# STRONG: the word alone is about energy. `drain` is deliberately NOT here —
# in this repo it overwhelmingly means draining a queue ("no drain of the
# convergence buffer"), and treating it as an energy noun produced 25 false
# positives on the first pass.
function has_strong_energy(t) {
  return (t ~ /(batter(y|ies)|milliamp|milliwatt|[Jj]oule|discharge)/) \
      || (t ~ /[^A-Za-z](mA|mAh|mW)[^A-Za-z]/) \
      || (t ~ /%[[:space:]]*\/[[:space:]]*(h|hr|hour|d|day)/)
}
# WEAK: the sentence is ABOUT energy, so a figure in it may be read as one.
# `draw` and `drain` are excluded for the same reason as above — "at the
# boundary draw (I = 62 s)" is a CSPRNG draw, and it turned a jitter bound in
# `run-b1-fgs-publish.sh` into a duty claim on the first attempt.
function energy_context(t) {
  return has_strong_energy(t) \
      || (t ~ /(GNSS|GPS|receiver|radio|wake|duty|Best|HIGH_ACCURACY|batter|power|energy)/)
}

# --- shape 1: percent per unit time --------------------------------------
function shape_pct_per_time(t) {
  return t ~ /%[[:space:]]*\/[[:space:]]*(h|hr|hour|d|day)([^A-Za-z]|$)/
}
# --- shape 2: current -----------------------------------------------------
function shape_current(t) {
  return (t ~ /[0-9][0-9.,]*[[:space:]]*(mA|mAh)([^A-Za-z]|$)/) || (t ~ /milliamp/)
}
# --- shape 3: energy in joules -------------------------------------------
function shape_joule(t) {
  return (t ~ /[0-9][0-9.,]*[[:space:]]*J([^A-Za-z]|$)/) || (t ~ /[Jj]oule/)
}
# --- shape 4: power in watts ---------------------------------------------
# A bare integer plus `W` is NOT a watt figure here: logcat priority columns
# ("543 W Watchdog") and plan work-item ids ("§4 W3") both produce it. So watts
# need an SI prefix, a decimal point, or the word.
function shape_watt(t) {
  return (t ~ /[0-9][0-9.,]*[[:space:]]*(mW|uW|kW)([^A-Za-z]|$)/) \
      || (t ~ /[0-9]+\.[0-9]+[[:space:]]*W([^A-Za-z0-9]|$)/) \
      || (t ~ /[0-9][0-9.,]*[[:space:]]*[Ww]atts?([^A-Za-z]|$)/) \
      || (t ~ /milliwatt/)
}
# --- shape 5: wake rate ---------------------------------------------------
function shape_wake_rate(t) {
  return t ~ /wake(s|ups)?[[:space:]]*(\/|per[[:space:]]+)[[:space:]]*(h|hr|hour)([^A-Za-z]|$)/
}
# --- shape 6: a percentage next to a unit of time ------------------------
# "~59 % of the window", "4 % duty", "~1 % of the time at Best". A duty cycle
# is an energy figure in model E (E-A1/E-A3 multiply it straight into %/h).
# Three tiers, because proximity and vocabulary trade against each other:
#   (a) an unmistakable time noun within 60 characters — no context needed;
#   (b) the same noun up to 240 characters away — this tree wraps a six-line
#       sentence around an em-dash aside and puts the halves five lines apart,
#       which is how one such duty hid from a four-line window;
#   (c) the wider nouns (session, cycle, interval, dwell, run, burst), which
#       are timing words far more often than duty words here ("±25 % of the
#       nominal interval" is jitter) — so (b) and (c) both require the sentence
#       to be about energy at all.
# The time word is boundaried: "most of its motion in the first 60% of the
# TIMELINE" is an animation curve, and an unbounded `time` matched it.
function shape_pct_of_time(t) {
  if ((t ~ /[0-9][0-9.,]*[[:space:]]*%[^.]{0,60}(of the (time|window|day|hour)([^a-z]|$)|duty|per hour|per day)/) \
   || (t ~ /(of the (time|window|day|hour)([^a-z]|$)|duty|per hour|per day)[^.]{0,60}[0-9][0-9.,]*[[:space:]]*%/)) return 1
  if (!energy_context(t)) return 0
  if ((t ~ /[0-9][0-9.,]*[[:space:]]*%[^.]{0,240}(of the (time|window|day|hour)([^a-z]|$)|duty|per hour|per day)/) \
   || (t ~ /(of the (time|window|day|hour)([^a-z]|$)|duty|per hour|per day)[^.]{0,240}[0-9][0-9.,]*[[:space:]]*%/)) return 1
  return (t ~ /[0-9][0-9.,]*[[:space:]]*%[^.]{0,240}of (the|each|a|an|any|every|its)([[:space:]]+[A-Za-z0-9-]+){0,2}[[:space:]]+(session|cycle|interval|dwell|run|burst)([^a-z]|$)/) \
      || (t ~ /of (the|each|a|an|any|every|its)([[:space:]]+[A-Za-z0-9-]+){0,2}[[:space:]]+(session|cycle|interval|dwell|run|burst)([^a-z]|$)[^.]{0,240}[0-9][0-9.,]*[[:space:]]*%/)
}
# --- shape 7: a battery delta -------------------------------------------
# "drops the battery by 7 percentage points" is a result with no time noun and
# no second figure, so shapes 6 and 8 both miss it. The energy noun has to be
# within 40 characters of the figure: a coverage floor moving "5 percentage
# points" is the same shape over a different subject.
function shape_energy_delta(t) {
  return (t ~ /(batter(y|ies)|power|energy|charge|drain)[^.]{0,40}[0-9][0-9.,]*[[:space:]]*(%|percentage[[:space:]]+points?)([^A-Za-z]|$)/) \
      || (t ~ /[0-9][0-9.,]*[[:space:]]*(%|percentage[[:space:]]+points?)([^A-Za-z]|$)[^.]{0,40}(batter(y|ies)|power|energy|charge|drain)/)
}
# --- shape 8: a before/after pair of energy figures ----------------------
# Two energy figures joined by an arrow or "vs" is a saving, i.e. a result.
function shape_before_after(t,   c, s) {
  if (t !~ /(->|=>|[^A-Za-z]vs\.?[^A-Za-z])/) return 0
  s = t; c = gsub(/[0-9][0-9.,]*[[:space:]]*%[[:space:]]*\/[[:space:]]*(h|hr|hour|d|day)/, "", s)
  if (c >= 2) return 1
  s = t; c = gsub(/[0-9][0-9.,]*[[:space:]]*(mA|mAh)([^A-Za-z]|$)/, "", s)
  if (c >= 2) return 1
  # A pair of BARE percentages is a before/after energy figure only in a sentence
  # that is about energy. Unqualified it is a coverage table ("90.74% -> 2290
  # lines of slack"), which is how this shape first went off.
  if (!has_strong_energy(t) && t !~ /(GNSS|duty|wake)/) return 0
  s = t; c = gsub(/[0-9][0-9.,]*[[:space:]]*%/, "", s)
  return c >= 2
}
# --- shape 9: a zero-cost verdict ---------------------------------------
# The negation must attach to an energy COST, not merely share a line with an
# energy word: "no GPS fix is requested, so the cost of the cadence is
# negligible" argues a MECHANISM (nothing was asked for) and is not a figure,
# while "no new battery cost" is model E arithmetic with the tag dropped.
function shape_zero_cost(t) {
  return (t ~ /(no|zero|without|nothing|never|free of)([[:space:]]+[A-Za-z0-9'"'"'-]+){0,3}[[:space:]]+(batter(y|ies)|power|energy|wake|wakeups?|radio|GNSS|GPS)[[:space:]-]*(cost|drain|draw|impact|penalty|price|overhead|hit)([^A-Za-z]|$)/) \
      || (t ~ /negligible([[:space:]]+[A-Za-z0-9'"'"'-]+){0,2}[[:space:]]+(batter(y|ies)|power|energy|wakeups?|drain|draw)([^A-Za-z]|$)/) \
      || (t ~ /(batter(y|ies)|power|energy|wakeups?)([[:space:]-]*(cost|drain|draw|impact|penalty))?([[:space:]]+[A-Za-z0-9'"'"'-]+){0,3}[[:space:]]+(is|are)([[:space:]]+[A-Za-z0-9'"'"'-]+){0,2}[[:space:]]+(negligible|nil|zero|nothing|free)([^A-Za-z]|$)/) \
      || (t ~ /(costs?|adds?|adding|at)[[:space:]]+(no|zero)([[:space:]]+[A-Za-z0-9'"'"'-]+){0,2}[[:space:]]+(batter(y|ies)|energy|power[[:space:]-]*(cost|draw|drain|budget))([^A-Za-z]|$)/)
}
# --- shape 10: a directional claim --------------------------------------
# A superlative predicated OF an energy term. The collocation is required
# (superlative, then at most two words, then the energy noun) rather than mere
# co-occurrence: "the emulator is the dominant memory consumer", "the DOMINANT
# generator of MLS forks" and "the dominant interaction (open, glance)" are all
# in this tree and none is an energy claim. `cost` is matched in the SINGULAR
# only — "the worst it costs us" is a verb, not a cost noun.
function shape_directional(t) {
  return (t ~ /(dominant|dominates|dominate|biggest|largest|chief|primary|principal|worst|lion.s share of)([[:space:]]+[A-Za-z0-9'"'"'-]+){0,2}[[:space:]]+(drain|draw|batter(y|ies)|power|energy|cost)([^A-Za-z]|$)/) \
      || (t ~ /(most|the bulk|the majority)[[:space:]]+of[[:space:]]+the([[:space:]]+[A-Za-z0-9'"'"'-]+){0,2}[[:space:]]+(drain|draw|batter(y|ies)|power|energy|receiver time|GNSS|radio|wakes|wakeups?)([^A-Za-z]|$)/) \
      || (t ~ /(drain|batter(y|ies)|power|energy)([[:space:]]+[A-Za-z0-9'"'"'-]+){0,2}[[:space:]]+is[[:space:]]+dominated[[:space:]]+by/)
}
# --- shape 11: a measurement verdict over an energy term -----------------
# "would leave the power claim unmeasured behind a green lane" implies a green
# lane measures it. None does — no lane in this repo observes energy at all
# (§6.5a (iii)), so "measured" and "unmeasured" are both claims about an
# instrument and need one named.
function shape_measured(t) {
  return (t ~ /(un)?measured([[:space:]]+[A-Za-z0-9'"'"'-]+){0,3}[[:space:]]+(batter(y|ies)|power|energy|drain|draw|wakeups?|milliamp|joule)([^A-Za-z]|$)/) \
      || (t ~ /(batter(y|ies)|power|energy|drain|draw|wakeups?|milliamp|joule)([[:space:]]+[A-Za-z0-9'"'"'-]+){0,3}[[:space:]]+((is|are|was|were)[[:space:]]+)?(un)?measured([^A-Za-z]|$)/) \
      || (t ~ /(power|batter(y|ies)|energy)[[:space:]]+claim[[:space:]]+((is|was)[[:space:]]+)?(un)?measured/)
}
# --- shape 12: a causal energy assertion --------------------------------
# "burning wakeups, and therefore battery, for a surface nobody can see" is a
# claim about how much a mechanism costs. `cost` itself is left out of the verb
# list: "costs nothing" appears fifteen times in this tree as a CODE cost, and
# shapes 9 and 10 already cover the energy senses of the noun.
function shape_causal(t) {
  return t ~ /(burning|burns|burn|wastes|waste|wasting|consumes|consume|consuming|eats|eating|spends|spend|spending)([[:space:]]+[A-Za-z0-9'"'"'-]+){0,3}[[:space:]]+(batter(y|ies)|wakeups?|energy|milliamp|joules?)([^A-Za-z]|$)/
}
function shape_of(t) {
  if (shape_pct_per_time(t))  return "percent-per-time"
  if (shape_current(t))       return "current(mA)"
  if (shape_joule(t))         return "energy(J)"
  if (shape_watt(t))          return "power(W)"
  if (shape_wake_rate(t))     return "wake-rate"
  if (shape_pct_of_time(t))   return "percent-of-time"
  if (shape_energy_delta(t))  return "battery-delta"
  if (shape_before_after(t))  return "before/after-pair"
  if (shape_zero_cost(t))     return "zero-cost-verdict"
  if (shape_directional(t))   return "directional-claim"
  if (shape_measured(t))      return "measurement-verdict"
  if (shape_causal(t))        return "causal-energy-claim"
  return ""
}

# --- attribution ---------------------------------------------------------
# An ESTIMATE marker is only attribution when it is ANCHORED to model E. "this
# is an estimate" on its own tells a reader nothing they can check; §6.5a is
# where the inputs, the parameters and the arithmetic are. The marker is a STEM
# so "estimation model E" counts — that is how repo-guards.yml describes this
# very guard.
function attributed_estimate(t) {
  return (t ~ /([Ee]stimat|ESTIMAT|[Pp]redict|PREDICT|[Pp]rojected|extrapolat)/) \
      && (t ~ /([Mm]odel E|MODEL E|6\.5a|E-[IAP][0-9]|POWER_EFFICIENCY_PLAN)/)
}
# A genuine measurement needs a NAMED instrument that measures ENERGY. The list
# is deliberately closed — an open one ("benchmark", "profiled") would let any
# prose pass — and every member was checked against this tree on 2026-09-09:
# `dumpsys` alone (17 files, never once as `batterystats`), `simctl`,
# `criterion` and `POWER_MEASUREMENT` (a DOCUMENT name, not an instrument) each
# exempted a bare energy claim while measuring no energy at all, and
# `third-party` appears in 22 files as an adjective. They are gone; the phrase
# `published third[-party]` stays, because it introduces a cited figure
# (E-I1/E-I2) rather than an observation of Haven.
function attributed_instrument(t) {
  return t ~ /(batterystats|Battery Historian|battery historian|Xcode Energy|Energy gauge|energy gauge|Energy Log|energy log|powermetrics|Evgenii|Karki|OwnTracks|LTE-2012|published third|host benchmark)/
}
# A NAMED PLATFORM SOURCE. Some duties are not arithmetic and not observations:
# they are what the platform code does by construction, and the honest citation
# is that code. `LocationProviderManager.MIN_REQUEST_DELAY_MS` (`:181`) makes a
# sub-threshold request CONTINUOUS, so "the 100 % GNSS duty cycle" below it is
# definitional. A bare class name is not enough — it names no line a reader can
# open, so a LOCUS is required.
function attributed_platform_source(t) {
  return (t ~ /(LocationProviderManager|LocationManagerService|GnssLocationProvider|GnssManagerService|CLLocationManager|frameworks\/base|AOSP)/) \
      && (t ~ /(:|\.java:|\.mm:|\.swift:)[0-9]+/)
}
function attributed(t) {
  return attributed_estimate(t) || attributed_instrument(t) || attributed_platform_source(t)
}

function line_at(a, b, off, pos,   i, best) {
  best = a
  for (i = a; i <= b; i++) {
    if (brk[i]) continue
    if (off[i] <= pos) best = i; else break
  }
  return best
}
# The reach: the claim s sentence plus one either side, clipped to its BLOCK and
# to 10 lines. See ATTRIBUTION REACH in the header.
function attribution_of(L, C,   a, b, bt, off2, ns2, cb, ce, kk, ofs, lo, hi, i2) {
  a = bs[L]; b = be[L]
  if (a < L - 10) a = L - 10
  if (b > L + 10) b = L + 10
  bt = join_lines(a, b, off2)
  ofs = off2[L] + C - 1
  ns2 = split_sentences(bt, cb, ce)
  kk = 1
  for (i2 = 1; i2 <= ns2; i2++) if (cb[i2] <= ofs) kk = i2
  lo = (kk > 1) ? cb[kk - 1] : cb[kk]
  hi = (kk < ns2) ? ce[kk + 1] : ce[kk]
  return substr(bt, lo, hi - lo + 1)
}

# One buffer per FILE. An awk END rule sees every input file concatenated and
# reports FILENAME as the LAST one, so a single END would mis-attribute every
# finding and let a paragraph span a file boundary. Flush on the first line of
# each new file, and once more at the end for the last one.
function flush(fname,   i, j, k, m, gs, ge, gt, goff, ns, sb, se, sent, sh, L, C) {
  if (n == 0) return
  for (i = 1; i <= n; i++) {
    txt[i] = strip_leader(raw[i])
    # Tabs out of the joined text: it is printed as a TSV field below, and only
    # its position as the LAST field keeps an embedded tab harmless today.
    # Replaced 1:1, so every offset computed below still points where it did.
    gsub(/\t/, " ", txt[i])
    brk[i] = (txt[i] == "") ? 1 : 0
    cmt[i] = is_comment(raw[i]) ? 1 : 0
  }
  # blocks: the attribution unit
  i = 1
  while (i <= n) {
    if (brk[i]) { bs[i] = 0; be[i] = 0; i++; continue }
    j = i
    while (j + 1 <= n && !brk[j + 1] && cmt[j + 1] == cmt[i]) j++
    for (k = i; k <= j; k++) { bs[k] = i; be[k] = j }
    i = j + 1
  }
  # detection groups: a block, plus the comment blocks that finish its sentence
  i = 1
  while (i <= n) {
    if (brk[i]) { i++; continue }
    gs = bs[i]; ge = be[i]
    if (cmt[i]) {
      while (1) {
        gt = join_lines(gs, ge, goff)
        if (gt ~ /[.!?][])"`]*$/) break
        m = ge + 1
        while (m <= n && brk[m]) m++
        if (m > n || !cmt[m]) break
        ge = be[m]
      }
    }
    gt = join_lines(gs, ge, goff)
    ns = split_sentences(gt, sb, se)
    for (k = 1; k <= ns; k++) {
      sent = substr(gt, sb[k], se[k] - sb[k] + 1)
      sh = shape_of(sent)
      if (sh == "") continue
      L = line_at(gs, ge, goff, sb[k])
      C = sb[k] - goff[L] + 1
      if (!no_attr && attributed(attribution_of(L, C))) continue
      printf "%s\t%d\t%s\t%s\n", fname, L, sh, sent
    }
    i = ge + 1
  }
}

FNR == 1 && NR > 1 { flush(prevfile); n = 0 }
{ raw[FNR] = $0; n = FNR; prevfile = FILENAME }
END { flush(prevfile) }
'

# ---------------------------------------------------------------------------
# Check 2 emitter: paragraphs that call something a measurement AND cite a test
# file. awk cannot resolve a path without a toolchain, so it emits candidates
# and the shell resolves them.
#
# The measurement word may be anywhere in the paragraph — a citation two
# sentences below "the authoritative MEASUREMENT" is still the source of it.
# The HISTORICAL exemption may not: `removed`, `deleted` and `no longer` are
# among the commonest words in this tree, so a paragraph-wide match let
# "The legacy poll path was removed in M11." excuse a live measurement claim
# over a tombstone. It is read off the CITING SENTENCE only.
#
# `strict=0` drops the missing-file leg (see "Scope" in the header): a plan may
# name an instrument it intends to create.
# ---------------------------------------------------------------------------
readonly CITATION_AWK='
function strip_leader(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/^(\/\/\/|\/\/!|\/\/|#+|\*\/|\/\*|\*)[[:space:]]?/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}
function is_comment(s) { return s ~ /^[[:space:]]*(\/\/|#|\*|\/\*)/ }
function join_lines(a, b, off,   i, out) {
  out = ""
  for (i = a; i <= b; i++) {
    if (brk[i]) continue
    if (out != "") out = out " "
    off[i] = length(out) + 1
    out = out txt[i]
  }
  return out
}
function split_sentences(t, sb, se,   k, start, pos, rest, p, endp, e, len) {
  k = 0; start = 1; pos = 1; len = length(t)
  while (pos <= len) {
    rest = substr(t, pos)
    if (!match(rest, /[.!?][])"`]*[[:space:]]+/)) break
    p = pos + RSTART - 1
    endp = p + RLENGTH - 1
    pos = endp + 1
    if (p >= 3 && substr(t, p - 2, 1) == "." && substr(t, p - 1, 1) ~ /[A-Za-z]/) continue
    e = endp
    while (e > p && substr(t, e, 1) ~ /[[:space:]]/) e--
    k++; sb[k] = start; se[k] = e
    start = pos
  }
  if (start <= len) { k++; sb[k] = start; se[k] = len }
  return k
}
function line_at(a, b, off, pos,   i, best) {
  best = a
  for (i = a; i <= b; i++) {
    if (brk[i]) continue
    if (off[i] <= pos) best = i; else break
  }
  return best
}
function flush(fname,   i, j, k, para, off, ns, sb, se, pos, cite, abs, kk, sent, hist, L) {
  if (n == 0) return
  for (i = 1; i <= n; i++) {
    txt[i] = strip_leader(raw[i])
    # Tabs out of the joined text: it is printed as a TSV field below, and only
    # its position as the LAST field keeps an embedded tab harmless today.
    # Replaced 1:1, so every offset computed below still points where it did.
    gsub(/\t/, " ", txt[i])
    brk[i] = (txt[i] == "") ? 1 : 0
    cmt[i] = is_comment(raw[i]) ? 1 : 0
  }
  i = 1
  while (i <= n) {
    if (brk[i]) { i++; continue }
    j = i
    while (j + 1 <= n && !brk[j + 1] && cmt[j + 1] == cmt[i]) j++
    para = join_lines(i, j, off)
    # Only paragraphs that assert a measurement. p50/p99 count: a percentile is
    # a sample statistic and cannot come from reasoning.
    if (para ~ /(MEASUREMENT|[Mm]easured|[Mm]easurement|[Ss]ampl(es|ed|ing)|p50|p99|instrument)/) {
      ns = split_sentences(para, sb, se)
      pos = 1
      while (match(substr(para, pos), /(haven-core\/|haven\/)?(tests|benches)\/[A-Za-z0-9_.\/-]+\.(rs|dart)/)) {
        abs = pos + RSTART - 1
        cite = substr(para, abs, RLENGTH)
        pos = abs + RLENGTH
        kk = 1
        for (k = 1; k <= ns; k++) if (sb[k] <= abs) kk = k
        sent = substr(para, sb[kk], se[kk] - sb[kk] + 1)
        hist = (sent ~ /(HISTORICAL|DELETED|deleted|tombstone|no longer|removed|struck)/) ? 1 : 0
        L = line_at(i, j, off, abs)
        printf "%s\t%d\t%s\t%d\t%d\n", fname, L, cite, hist, strict
      }
    }
    i = j + 1
  }
}

FNR == 1 && NR > 1 { flush(prevfile); n = 0 }
{ raw[FNR] = $0; n = FNR; prevfile = FILENAME }
END { flush(prevfile) }
'

# ---------------------------------------------------------------------------
# collect_files <base-dir> <ext> [ext ...] — every matching file under <base>.
# Fails CLOSED on an empty result: a root that resolves to nothing means the
# tree moved under this guard, and this repo has been bitten repeatedly by
# guards that pass because their target was renamed away.
# ---------------------------------------------------------------------------
collect_files() {
  local base="$1"; shift
  local find_args=() ext first=1
  [[ -d "${base}" ]] || { bad "scan root does not exist: ${base}"; return 2; }
  for ext in "$@"; do
    if (( first )); then first=0; else find_args+=('-o'); fi
    find_args+=('-name' "*.${ext}")
  done
  local out
  out="$(find "${base}" -type f \( "${find_args[@]}" \) -print 2>/dev/null \
        | grep -Ev "${EXCLUDE_RE}" | LC_ALL=C sort || true)"
  if [[ -z "${out}" ]]; then
    bad "scan root '${base}' matched NO source file (extensions: $*)."
    return 2
  fi
  printf '%s\n' "${out}"
}

# ---------------------------------------------------------------------------
# scan_tree <base-dir> <allowlist-file|''> [root-relative-dir ...]
#
# The whole check, run once over the union of the given roots. `base` anchors
# both the reported paths and check 2's citation resolution; with no roots it
# scans `base` itself, which is what the self-test's fixture trees need.
# CITE_EXTRA_ROOTS are added to check 2 only, and only when they exist under
# `base` — a fixture tree has no `docs/`, while the real repo's is required by
# main() below.
# Returns 0 clean, 1 violation(s), 2 misconfiguration.
# ---------------------------------------------------------------------------
scan_tree() {
  local base="$1" allow="$2"; shift 2
  local files='' cite_files='' raw findings=0 f root chunk xr

  if (( $# == 0 )); then
    files="$(collect_files "${base}" "${SCAN_EXTS[@]}")" || return 2
  else
    for root in "$@"; do
      chunk="$(collect_files "${base}/${root}" "${SCAN_EXTS[@]}")" || return 2
      files+="${chunk}"$'\n'
    done
    files="${files%$'\n'}"
  fi
  while IFS= read -r f; do
    [[ -r "${f}" ]] || { bad "unreadable file (cannot certify it): ${f}"; return 2; }
  done <<<"${files}"

  for xr in "${CITE_EXTRA_ROOTS[@]}"; do
    [[ -d "${base}/${xr}" ]] || continue
    chunk="$(collect_files "${base}/${xr}" "${CITE_EXTS[@]}")" || return 2
    cite_files+="${chunk}"$'\n'
  done
  cite_files="${cite_files%$'\n'}"

  # --- check 1 -------------------------------------------------------------
  raw="$(printf '%s\n' "${files}" | xargs -r awk -v no_attr="${SCAN_NO_ATTR}" "${SCANNER_AWK}" || true)"

  # --- allowlist -----------------------------------------------------------
  # `path<TAB>literal substring<TAB>reason`. A substring rather than a line
  # number so an entry survives the file being edited above it; it is matched
  # against the claim's own SENTENCE, so an entry cannot reach a neighbouring
  # claim. An entry that stops matching is a FAILURE — a rotted exemption is how
  # an allowlist turns into a permanent hole.
  local -a allow_path=() allow_sub=() allow_hit=()
  if [[ -n "${allow}" && -f "${allow}" ]]; then
    local ln
    while IFS= read -r ln || [[ -n "${ln}" ]]; do
      [[ -z "${ln}" || "${ln}" == \#* ]] && continue
      local p s r
      IFS=$'\t' read -r p s r <<<"${ln}"
      [[ -n "${p}" && -n "${s}" && -n "${r}" ]] \
        || { bad "allowlist line is not 'path<TAB>substring<TAB>reason': ${ln}"; return 2; }
      allow_path+=("${p}"); allow_sub+=("${s}"); allow_hit+=(0)
    done <"${allow}"
  fi

  local kept='' rel shape line_no frag i
  while IFS=$'\t' read -r f line_no shape frag; do
    [[ -n "${f}" ]] || continue
    rel="${f#"${base}"/}"
    local exempt=0
    for i in "${!allow_path[@]}"; do
      if [[ "${rel}" == "${allow_path[i]}" && "${frag}" == *"${allow_sub[i]}"* ]]; then
        allow_hit[i]=1; exempt=1; break
      fi
    done
    (( exempt )) && continue
    kept+="${rel}:${line_no}  [${shape}]  ${frag:0:150}"$'\n'
    findings=$(( findings + 1 ))
  done <<<"${raw}"

  if (( findings )); then
    bad "${findings} unattributed energy claim(s):"
    printf '%s' "${kept}" >&2
    printf '\n  Every energy figure in this tree is an output of estimation model E\n' >&2
    printf '  (docs/POWER_EFFICIENCY_PLAN.md 6.5a) — there is no hardware (2.5). Put an\n' >&2
    printf '  ESTIMATED marker AND a model anchor (model E / 6.5a / E-I4 / E-P3 /\n' >&2
    printf '  POWER_EFFICIENCY_PLAN) in the SAME sentence as the claim, or in the one\n' >&2
    printf '  next to it, or name the instrument that measured it. A negation ("no\n' >&2
    printf '  battery cost") and a superlative ("the dominant drain") are energy claims\n' >&2
    printf '  too — model E finding 2 already contradicts one of the superlatives that\n' >&2
    printf '  used to be in this tree.\n' >&2
  fi

  # --- stale allowlist ----------------------------------------------------
  for i in "${!allow_path[@]}"; do
    if (( allow_hit[i] == 0 )); then
      bad "allowlist entry matches nothing any more: ${allow_path[i]} :: ${allow_sub[i]}"
      printf '  Delete the entry (the claim was fixed) rather than leaving a hole open.\n' >&2
      findings=$(( findings + 1 ))
    fi
  done

  # --- check 2 ------------------------------------------------------------
  local cite hist strict resolved cand crate_root
  while IFS=$'\t' read -r f line_no cite hist strict; do
    [[ -n "${f}" ]] || continue
    rel="${f#"${base}"/}"
    resolved=''
    # A crate-relative cite (`tests/x.rs`) from a file under a nested crate
    # resolves against THAT crate's root, found by walking up to its manifest.
    crate_root="$(dirname "${f}")"
    while [[ "${crate_root}" != "${base}" && "${crate_root}" != "/" \
             && ! -f "${crate_root}/Cargo.toml" && ! -f "${crate_root}/pubspec.yaml" ]]; do
      crate_root="$(dirname "${crate_root}")"
    done
    # `tooling/soak` for the same reason `haven-core` and `haven` are here: a
    # guard under scripts/ci cites the soak crate's own tests crate-relatively,
    # and the walk above anchors at the repo root for a file that is in no
    # crate.
    for cand in "${base}/${cite}" "${crate_root}/${cite}" "${base}/haven-core/${cite}" \
                "${base}/haven/${cite}" "${base}/tooling/soak/${cite}"; do
      [[ -f "${cand}" ]] && { resolved="${cand}"; break; }
    done
    if [[ -z "${resolved}" ]]; then
      (( strict )) || continue
      bad "${rel}:${line_no} cites '${cite}' as a measurement source, and that file does not exist."
      printf '  A measurement whose instrument is gone is not a measurement. Either\n' >&2
      printf '  re-point it at a live instrument or say the figure is HISTORICAL.\n' >&2
      findings=$(( findings + 1 ))
      continue
    fi
    if head -n 8 "${resolved}" | grep -q 'DELETED-WITH-SUBJECT' && (( hist == 0 )); then
      bad "${rel}:${line_no} cites '${cite}' as a measurement source, but that file is a DELETED-WITH-SUBJECT tombstone."
      printf '  Say so in the CITING SENTENCE (HISTORICAL / DELETED / "no longer"), so a\n' >&2
      printf '  reader is not sent to a header where the numbers no longer live. A\n' >&2
      printf '  disclaimer elsewhere in the paragraph does not travel with the citation.\n' >&2
      findings=$(( findings + 1 ))
    fi
  done < <(
    printf '%s\n' "${files}" | xargs -r awk -v strict=1 "${CITATION_AWK}" || true
    [[ -n "${cite_files}" ]] \
      && { printf '%s\n' "${cite_files}" | xargs -r awk -v strict=0 "${CITATION_AWK}" || true; }
  )

  (( findings == 0 )) && return 0
  return 1
}

# ---------------------------------------------------------------------------
# --self-test: hermetic fixtures, both directions, for every shape.
#
# The count is pinned by EQUALITY, not a floor. A printed count is not an
# assertion: until it is compared with something, fixtures can be lost — to an
# edit, to a conflict resolved by keeping one side — while the suite keeps
# printing a pass over whatever survived.
#
# The pin alone is not enough either, and this suite used to prove that: a
# FAIL-direction fixture is self-protecting (gut its body and rc drops to 0, so
# the fixture fails), but a PASS-direction one is not — an empty probe passes
# every check. So each PASS fixture carries its own non-vacuity assertion:
#
#   * _case_attributed  — the same body with attribution DISABLED must FAIL.
#     That proves the body really does carry a claim, and that the marker is
#     what saves it.
#   * _case_not_a_claim — the body must PASS with attribution DISABLED (which
#     is strictly stronger than passing with it on, since attribution only ever
#     removes findings), and must still CONTAIN the near-miss it exists to
#     discriminate.
# ---------------------------------------------------------------------------
self_test() {
  # Bump this in the SAME commit that adds or removes an assertion.
  local -r SELF_TEST_FIXTURES=106
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

  # _run <dir> <allowlist|''> <no-attr 0|1> — the guard over one fixture tree.
  _run() {
    local dir="$1" allow="$2" na="$3" rc=0
    SCAN_NO_ATTR="${na}"
    scan_tree "${dir}" "${allow}" >/dev/null 2>&1 || rc=$?
    SCAN_NO_ATTR=0
    return "${rc}"
  }

  _write_probe() { # <body...> -> ${tmp}/case/probe.dart
    local dir="${tmp}/case"
    rm -rf "${dir}"; mkdir -p "${dir}"
    printf '%s\n' "$@" >"${dir}/probe.dart"
  }

  # _case <label> <want-rc> <body...> — one .dart file in a fresh tree.
  _case() {
    local label="$1" want="$2"; shift 2
    _write_probe "$@"
    local got=0
    _run "${tmp}/case" '' 0 || got=$?
    _record "${label}" "${want}" "${got}"
  }

  # _case_attributed <label> <body...> — passes, and FAILS without its marker.
  _case_attributed() {
    local label="$1"; shift
    _write_probe "$@"
    local got=0
    _run "${tmp}/case" '' 0 || got=$?
    _record "${label}" 0 "${got}"
    got=0
    _run "${tmp}/case" '' 1 || got=$?
    _record "${label} [and FAILS with its attribution ignored]" 1 "${got}"
  }

  # _case_not_a_claim <label> <near-miss substring> <body...> — passes because
  # the shape does not apply, not because something attributed it.
  _case_not_a_claim() {
    local label="$1" needle="$2"; shift 2
    _write_probe "$@"
    local got=0
    _run "${tmp}/case" '' 1 || got=$?
    _record "${label}" 0 "${got}"
    got=0
    grep -qF -- "${needle}" "${tmp}/case/probe.dart" || got=1
    _record "${label} [the near-miss '${needle}' is still in the fixture]" 0 "${got}"
  }

  log 'self-test: shape fixtures (each shape one FAIL and one PASS)'

  # --- shape 1: percent per time -----------------------------------------
  _case 'percent-per-time, bare -> FAIL' 1 \
    '/// Background sharing settles at 0.6 %/h once the burst lands.'
  _case_attributed 'percent-per-time, ESTIMATED + model anchor -> PASS' \
    '/// Background sharing settles at 0.6 %/h once the burst lands —' \
    '/// ESTIMATED from model E (docs/POWER_EFFICIENCY_PLAN.md 6.5a), never' \
    '/// measured on a device.'

  # --- shape 2: current ---------------------------------------------------
  _case 'current, bare -> FAIL' 1 \
    '/// Continuous GNSS costs 60-85 mA on this receiver.'
  _case_attributed 'current, third-party citation -> PASS' \
    '/// Continuous GNSS costs 60-85 mA (Karki & Won, a published third-party' \
    '/// draw; nothing here was measured on Haven).'

  # --- shape 3: joules ----------------------------------------------------
  _case 'joules, bare -> FAIL' 1 \
    '/// An isolated radio wake costs about 13 J.'
  _case_attributed 'joules, ESTIMATED + input id -> PASS' \
    '/// An isolated radio wake costs about 13 J — E-I6, so ESTIMATED' \
    '/// arithmetic and never observed here.'

  # --- shape 4: watts -----------------------------------------------------
  _case 'watts (mW), bare -> FAIL' 1 \
    '/// The modem holds 310 mW for as long as the socket stays open.'
  _case 'watts (a decimal and a bare W), bare -> FAIL' 1 \
    '/// A receiver pinned at Best costs 0.9 W on this class of handset.'
  _case_attributed 'watts, ESTIMATED + model anchor -> PASS' \
    '/// The modem holds 310 mW while the socket is open — ESTIMATED from the' \
    '/// plan s LTE wake model (docs/POWER_EFFICIENCY_PLAN.md 6.5a, E-I6) and' \
    '/// never observed on hardware.'
  _case_not_a_claim 'a logcat priority column is not a watt figure' '543 W Watchdog' \
    '/// A crash line from the fixture corpus:' \
    "/// '08-05 06:40:32.212   518   543 W Watchdog: *** WATCHDOG KILLING'"
  _case_not_a_claim 'a plan work-item id is not a watt figure' 'W3' \
    '/// The peeler s exporter-label override (plan §4 W3) must never be called.'

  # --- shape 5: wake rate -------------------------------------------------
  _case 'wake-rate, bare -> FAIL' 1 \
    '/// The pinging socket adds 65 wakes/h to the background budget.'
  _case 'wake-rate, "wakes per hour" prose, bare -> FAIL' 1 \
    '/// Roughly 150 wakes per hour reach the radio while paused.'
  _case_attributed 'wake-rate, ESTIMATED + model anchor -> PASS' \
    '/// The pinging socket adds 65 wakes/h (ESTIMATED, model E E-I8).'

  # --- shape 6: percent next to a time unit ------------------------------
  _case 'percent-of-time, bare, WRAPPED across two lines -> FAIL' 1 \
    '/// The controller can sit at Best for as much as 59 %' \
    '/// of the time before the dwell expires.'
  _case_attributed 'percent-of-time, ESTIMATED + model anchor -> PASS' \
    '/// The controller can sit at Best for as much as 59 %' \
    '/// of the time — arithmetic on two constants, so ESTIMATED and never' \
    '/// measured (docs/POWER_EFFICIENCY_PLAN.md 6.5a, E-I10).'
  _case 'percent-of-time, split by a paragraph BREAK mid-sentence -> FAIL' 1 \
    '/// The controller can sit at Best for as much as 59 %' \
    '///' \
    '/// of the time before the dwell expires.'
  _case 'percent-of-time, halves five lines apart around an aside -> FAIL' 1 \
    '/// The controller can sit at Best for as much as 59 %' \
    '/// — a figure that is arithmetic over two constants and nothing more,' \
    '/// and which the plan restates in its own table without either constant' \
    '/// in view, which is how it went stale twice before — of the time the' \
    '/// app is backgrounded and the device is stationary on a desk.'
  _case 'percent of a SESSION, bare -> FAIL' 1 \
    '/// The receiver sits at Best for 59 % of the session.'
  _case 'percent of EACH BACKGROUND CYCLE, bare -> FAIL' 1 \
    '/// The GNSS receiver is held on for 30 % of each background cycle.'
  _case_attributed 'percent of a session, ESTIMATED + model anchor -> PASS' \
    '/// The receiver sits at Best for 59 % of the session — ESTIMATED from the' \
    '/// cycle arithmetic (model E, docs/POWER_EFFICIENCY_PLAN.md 6.5a), and no' \
    '/// device has measured it.'
  _case_not_a_claim 'percent next to "timeline" is a motion curve' 'timeline' \
    '/// M3 motionEasingEmphasizedDecelerate. The panel arrives with most of' \
    '/// its motion in the first 60% of the timeline.'
  _case_not_a_claim 'a jitter bound over an interval is not a duty' 'nominal interval' \
    '/// The scheduler jitters within ±25 % of the nominal interval, so two' \
    '/// circles never share a publish tick.'

  # --- shape 7: battery delta --------------------------------------------
  _case 'battery delta in percentage points, bare -> FAIL' 1 \
    '/// Leaving the stream running drops the battery by 7 percentage points' \
    '/// over a working day.'
  _case_attributed 'battery delta, ESTIMATED + model anchor -> PASS' \
    '/// Leaving the stream running drops the battery by 7 percentage points' \
    '/// over a working day — ESTIMATED, model E (E-A1, 6.5a); no handset has' \
    '/// been watched doing it.'
  _case_not_a_claim 'a coverage floor moving 5 percentage points is not a battery delta' 'percentage points' \
    '/// The floor is re-pinned when a path outgrows it by more than 5' \
    '/// percentage points of line coverage.'

  # --- shape 8: before/after pair ----------------------------------------
  _case 'before/after pair, bare -> FAIL' 1 \
    '/// Releasing the stream takes the drain from 1.8 %/h -> 0.09 %/h.'
  _case_attributed 'before/after pair, ESTIMATED + model anchor -> PASS' \
    '/// Releasing the stream takes it from 1.8 %/h -> 0.09 %/h, both ESTIMATED' \
    '/// (model E 6.5a); no device has measured either endpoint.'
  _case_not_a_claim 'a bare percent pair with no energy context (a coverage table)' '90.74%' \
    '/// haven-core 90.74% (19419/21400) -> ~2290 lines of slack' \
    '/// haven      64.82% ( 6944/10712) -> ~1588 lines of slack'

  # --- shape 9: zero-cost verdicts ---------------------------------------
  _case 'zero-cost "no new battery cost" -> FAIL' 1 \
    '/// The extra read rides an existing wake, adding no new battery cost.'
  _case 'zero-cost "negligible battery" -> FAIL' 1 \
    '/// A probe every 30 s is negligible battery on any handset.'
  _case 'zero-cost "the battery cost is negligible" -> FAIL' 1 \
    '/// One more relay in the pool: the battery cost is negligible.'
  _case_attributed 'zero-cost, ESTIMATED + model anchor -> PASS' \
    '/// The extra read rides an existing wake, so model E predicts no new' \
    '/// battery cost at all (docs/POWER_EFFICIENCY_PLAN.md 6.5a, E-A2 moves' \
    '/// no wake count).'
  _case_not_a_claim 'zero-cost, mechanism argument with no energy noun' 'no GPS fix is requested' \
    '/// Each probe is two local platform calls — no GPS fix is requested and' \
    '/// no network traffic is generated — so the cost of the cadence is' \
    '/// negligible.'
  _case_not_a_claim 'zero-cost over EXPRESSIVE power, not watts' 'distinguishing power' \
    '/// precision 9 is ~37 mm; a longer geohash adds no distinguishing power' \
    '/// and every longer prefix contains the covered ones.'

  # --- shape 10: directional claims --------------------------------------
  _case 'directional "the dominant iOS drain" -> FAIL' 1 \
    '/// The one lever that removes the dominant iOS drain, a receiver held at' \
    '/// Best 24/7 while the device sits on a desk.'
  _case 'directional "the dominant cost of a background cycle" -> FAIL' 1 \
    '/// A second attempt buys a stale sample at the price of holding the radio' \
    '/// awake — the dominant cost of a background cycle.'
  _case 'directional "most of the receiver time" -> FAIL' 1 \
    '/// Restarting the dwell would spend a full dwell at Best on every expiry,' \
    '/// which is most of the receiver time this phase exists to remove.'
  _case_attributed 'directional, ESTIMATED + model anchor -> PASS' \
    '/// Model E (6.5a) makes the radio term, not the location term, the' \
    '/// dominant energy uncertainty — finding 2, and ESTIMATED like every' \
    '/// figure it produces.'
  _case_not_a_claim 'directional over a non-energy noun' 'memory consumer' \
    '/// No Gradle work runs in this step, and the emulator is the dominant' \
    '/// memory consumer.'
  _case_not_a_claim 'directional "the DOMINANT generator of MLS forks"' 'generator of forks' \
    '/// Leaderless periodic self-update is the DOMINANT generator of forks.'
  _case_not_a_claim 'superlative over a verb ("worst it costs")' 'worst it costs us' \
    '/// The row is re-read on the next open, so the worst it costs us is one' \
    '/// wasted query.'

  # --- shape 11: measurement verdicts ------------------------------------
  _case 'measurement verdict "leave the power claim unmeasured" -> FAIL' 1 \
    '/// Asserted before the count, because a session pinned at Best explains a' \
    '/// healthy count and would leave the power claim unmeasured behind a' \
    '/// green lane.'
  _case_attributed 'measurement verdict, named instrument -> PASS' \
    '/// The measured battery drain over an idle desk hour is bounded: the' \
    '/// dumpsys batterystats trace shows the scoped lock never older than 30 s.'
  _case 'measurement verdict, bare "dumpsys" is not an instrument -> FAIL' 1 \
    '/// The measured battery drain over an idle desk hour is bounded: the' \
    '/// dumpsys trace shows the scoped lock never older than 30 s.'

  # --- shape 12: causal energy assertions --------------------------------
  _case 'causal "burning wakeups, and therefore battery" -> FAIL' 1 \
    '/// At the tick rate it would fire about twice as often as the app own' \
    '/// background wake cadence — burning' \
    '/// wakeups, and therefore battery, for a surface nobody can see.'
  _case_attributed 'causal claim, ESTIMATED + model anchor -> PASS' \
    '/// The re-derivation would spend battery on a surface nobody can see:' \
    '/// one wake is ESTIMATED at c x 0.0208 %/h (model E E-A2), never' \
    '/// measured.'

  _case 'a claim carrying a TAB is still reported, not mis-parsed' 1 \
    "/// Continuous GNSS costs$(printf '\t')60-85 mA on this receiver."

  # --- the instrument list is closed -------------------------------------
  # Each of these exempted a bare energy claim until 2026-09-09 while measuring
  # no energy at all.
  _case 'a simctl citation is not an energy instrument -> FAIL' 1 \
    '/// The iOS lane costs 60-85 mA of receiver draw, as the simctl run shows.'
  _case 'a bare "third-party" adjective is not an instrument -> FAIL' 1 \
    '/// A third-party plugin holds the socket open, costing 13 J per wake.'
  _case 'a criterion (host CPU) benchmark is not an energy instrument -> FAIL' 1 \
    '/// The criterion suite puts the encrypt path at 0.6 %/h of the budget.'
  _case 'the POWER_MEASUREMENT document name is not an instrument -> FAIL' 1 \
    '/// POWER_MEASUREMENT.md records the background cycle at 0.6 %/h.'
  _case_attributed 'a powermetrics citation IS an instrument -> PASS' \
    '/// The powermetrics trace puts the modem at 310 mW while the socket is' \
    '/// open, sampled over ten minutes of an idle desk.'

  # --- attribution must be ANCHORED, and must REACH ----------------------
  _case 'a bare "estimate" with no model anchor -> FAIL' 1 \
    '/// Best costs roughly 1.8 %/h, which is our estimate.'
  _case 'attribution in the NEXT paragraph does not reach -> FAIL' 1 \
    '/// Best costs roughly 1.8 %/h.' \
    '///' \
    '/// ESTIMATED from model E (docs/POWER_EFFICIENCY_PLAN.md 6.5a).'
  _case_attributed 'attribution in the NEXT SENTENCE reaches -> PASS' \
    '/// The difference between ~1 % and ~29 % of the time at Best for a' \
    '/// stationary device. Both duties are ESTIMATED from the cycle arithmetic' \
    '/// (model E, docs/POWER_EFFICIENCY_PLAN.md 6.5a); no device has measured' \
    '/// a profile duty.'
  _case 'one tag does NOT cover a claim two sentences later -> FAIL' 1 \
    '/// Best costs roughly 1.8 %/h, ESTIMATED from model E' \
    '/// (docs/POWER_EFFICIENCY_PLAN.md 6.5a). The receiver draws 60-85 mA when' \
    '/// it is held on. An isolated radio wake costs about 13 J.'
  _case 'a tag does NOT reach across intervening CODE -> FAIL' 1 \
    '/// Best costs roughly 1.8 %/h (ESTIMATED, model E, 6.5a).' \
    'const Duration kA = Duration(seconds: 1);' \
    'const Duration kB = Duration(seconds: 2);' \
    'const Duration kC = Duration(seconds: 3);' \
    'const Duration kD = Duration(seconds: 4);' \
    'const Duration kE = Duration(seconds: 5);' \
    'const Duration kF = Duration(seconds: 6);' \
    'const Duration kG = Duration(seconds: 7);' \
    '/// The pinging socket adds 65 wakes/h to the background budget.'
  _case_attributed 'an "estimation model E" marker attributes -> PASS' \
    '/// Every battery figure in this tree is an output of estimation model E' \
    '/// (6.5a), and the guard refuses a zero-cost verdict like "no new battery' \
    '/// cost" for exactly that reason.'
  _case_attributed 'a NAMED PLATFORM SOURCE attributes a definitional duty -> PASS' \
    '/// LocationProviderManager.MIN_REQUEST_DELAY_MS (30 s, `:181`) plus a' \
    '/// second. At or below that threshold the S+ manager delivers no' \
    '/// historical fix and runs the request CONTINUOUSLY at HIGH_ACCURACY —' \
    '/// the 100 % GNSS duty cycle the delivery-driven cadence exists to' \
    '/// remove.'
  _case 'a platform class with NO locus does not attribute -> FAIL' 1 \
    '/// At or below the LocationProviderManager threshold the S+ manager runs' \
    '/// the request CONTINUOUSLY at HIGH_ACCURACY — the 100 % GNSS duty cycle' \
    '/// the delivery-driven cadence exists to remove.'

  # --- check 2: instrument-citation liveness -----------------------------
  _cite_case() {
    local label="$1" want="$2" instrument_body="$3"; shift 3
    local dir="${tmp}/cite"
    rm -rf "${dir}"; mkdir -p "${dir}/tests"
    printf '%s\n' "$@" >"${dir}/probe.rs"
    if [[ -n "${instrument_body}" ]]; then
      printf '%s\n' "${instrument_body}" >"${dir}/tests/probe_test.rs"
    fi
    local got=0
    _run "${dir}" '' 0 || got=$?
    _record "${label}" "${want}" "${got}"
    if (( want == 0 )); then
      got=0
      grep -qF -- 'tests/probe_test.rs' "${dir}/probe.rs" || got=1
      _record "${label} [the fixture still cites an instrument]" 0 "${got}"
    fi
  }
  _cite_case 'cited instrument missing -> FAIL' 1 '' \
    '//! The authoritative real-relay MEASUREMENT lives in' \
    '//! `tests/probe_test.rs`: p50 ~= 104 ms, p99 ~= 106 ms.'
  _cite_case 'cited instrument is a tombstone, unmarked -> FAIL' 1 \
    '//! DELETED-WITH-SUBJECT (Dark Matter, DM-5a).' \
    '//! The authoritative real-relay MEASUREMENT lives in' \
    '//! `tests/probe_test.rs`: p50 ~= 104 ms, p99 ~= 106 ms.'
  _cite_case 'a tombstone excuse in ANOTHER sentence does not travel -> FAIL' 1 \
    '//! DELETED-WITH-SUBJECT (Dark Matter, DM-5a).' \
    '//! The authoritative real-relay MEASUREMENT lives in' \
    '//! `tests/probe_test.rs`: p50 ~= 104 ms, p99 ~= 106 ms. The legacy poll' \
    '//! path was removed in M11.'
  _cite_case 'cited instrument is a tombstone, marked HISTORICAL -> PASS' 0 \
    '//! DELETED-WITH-SUBJECT (Dark Matter, DM-5a).' \
    '//! HISTORICAL measurement: `tests/probe_test.rs` sampled p50 ~= 104 ms,' \
    '//! and that suite is DELETED, so the figure cannot be reproduced.'
  _nested_cite_case() {
    local dir="${tmp}/cite_nested" want="$1" label="$2" got=0
    rm -rf "${dir}"; mkdir -p "${dir}/tooling/probe/src" "${dir}/tooling/probe/tests"
    printf '[package]\nname = "probe"\n' >"${dir}/tooling/probe/Cargo.toml"
    printf '//! The MEASUREMENT lives in `tests/probe_test.rs`: p99 ~= 106 ms.\n' \
      >"${dir}/tooling/probe/src/lib.rs"
    (( want == 0 )) && printf '#[test] fn probe() {}\n' >"${dir}/tooling/probe/tests/probe_test.rs"
    _run "${dir}" '' 0 || got=$?
    _record "${label}" "${want}" "${got}"
  }
  _nested_cite_case 0 'a nested crate cites its OWN tests/ dir -> PASS (resolved at the crate root)'
  _nested_cite_case 1 'a nested crate cites a tests/ file it does not have -> FAIL'

  _cite_case 'cited instrument is live -> PASS' 0 \
    '//! A live probe.' \
    '//! The MEASUREMENT lives in `tests/probe_test.rs`: p99 ~= 106 ms.'

  # --- check 2 over docs/: the tombstone leg only ------------------------
  _docs_cite_case() {
    local label="$1" want="$2" instrument_body="$3"; shift 3
    local dir="${tmp}/docs_cite"
    rm -rf "${dir}"; mkdir -p "${dir}/docs" "${dir}/tests"
    printf '%s\n' '// A code file, so the check-1 root is not empty.' >"${dir}/probe.dart"
    printf '%s\n' "$@" >"${dir}/docs/plan.md"
    if [[ -n "${instrument_body}" ]]; then
      printf '%s\n' "${instrument_body}" >"${dir}/tests/probe_test.rs"
    fi
    local got=0
    _run "${dir}" '' 0 || got=$?
    _record "${label}" "${want}" "${got}"
  }
  _docs_cite_case 'a doc citing a TOMBSTONE as a measurement -> FAIL' 1 \
    '// DELETED-WITH-SUBJECT (Dark Matter, DM-5a).' \
    'P-15 real-strfry measurement DONE: `tests/probe_test.rs` measured' \
    'p50 ~= 104 ms, p99 ~= 106 ms (n=100 x3).'
  _docs_cite_case 'a doc citing a PLANNED instrument that does not exist yet -> PASS' 0 '' \
    '| P1 | `tests/mesh_sim.rs` (routing-only) | the simulator is the source' \
    'of the relay multiplier, and the capacity numbers stay hypotheses until' \
    'it is measured on hardware |'
  _docs_cite_case 'a doc citing a LIVE instrument -> PASS' 0 \
    '//! A live probe.' \
    'The settle window is sized off `tests/probe_test.rs`, which measured' \
    'p99 ~= 106 ms against a pinned strfry.'

  # --- fail-closed --------------------------------------------------------
  local got=0
  rm -rf "${tmp}/empty"; mkdir -p "${tmp}/empty/sub"
  : >"${tmp}/empty/sub/notes.txt"
  _run "${tmp}/empty" '' 0 || got=$?
  _record 'a root with no in-scope file is MISCONFIGURED, not clean' 2 "${got}"

  got=0
  _run "${tmp}/does-not-exist" '' 0 || got=$?
  _record 'a missing root is MISCONFIGURED, not clean' 2 "${got}"

  # --- the allowlist ------------------------------------------------------
  local dir="${tmp}/allow"
  rm -rf "${dir}"; mkdir -p "${dir}"
  printf '%s\n' '/// Best costs roughly 1.8 %/h on this handset.' >"${dir}/probe.dart"
  printf 'probe.dart\t1.8 %%/h\ta fixture reason\n' >"${tmp}/allow.txt"
  got=0; _run "${dir}" "${tmp}/allow.txt" 0 || got=$?
  _record 'an allowlisted claim passes' 0 "${got}"
  printf 'probe.dart\t2.9 %%/h\ta fixture reason\n' >"${tmp}/allow.txt"
  got=0; _run "${dir}" "${tmp}/allow.txt" 0 || got=$?
  _record 'a stale allowlist entry FAILS (a rotted exemption is a hole)' 1 "${got}"
  # The exemption is a SENTENCE, not a radius: a second claim one sentence away
  # is still reported.
  printf '%s\n' \
    '/// Best costs roughly 1.8 %/h on this handset. An isolated radio wake' \
    '/// costs about 13 J.' >"${dir}/probe.dart"
  printf 'probe.dart\t1.8 %%/h\ta fixture reason\n' >"${tmp}/allow.txt"
  got=0; _run "${dir}" "${tmp}/allow.txt" 0 || got=$?
  _record 'an allowlist entry does NOT exempt the next sentence claim' 1 "${got}"

  if (( checked != SELF_TEST_FIXTURES )); then
    bad "the self-test ran ${checked} assertions; SELF_TEST_FIXTURES pins ${SELF_TEST_FIXTURES}."
    printf '  Every shape in this guard is backed by a FAIL fixture and a PASS fixture,\n' >&2
    printf '  and every PASS fixture by its own non-vacuity assertion, so a lost one is a\n' >&2
    printf '  shape that has stopped being tested while the suite still reports a pass. If\n' >&2
    printf '  one was added or removed deliberately, say so in SELF_TEST_FIXTURES in the\n' >&2
    printf '  same commit.\n' >&2
    fails=1
  fi
  if (( fails )); then
    bad 'self-test failed — this guard cannot be trusted until it is fixed'
    exit 2
  fi
  log "OK: self-test passed (${checked} assertions, pinned)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == '--self-test' ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  command -v awk >/dev/null 2>&1 || misconfig 'awk is required'
  # Every shape below bounds its proximity with a `{n,m}` interval. An awk
  # without interval support matches those literally, so every pattern would
  # quietly stop firing and this guard would pass over anything — the exact
  # false green it exists to prevent. Refuse to run instead.
  awk 'BEGIN { exit !(("aa" ~ /^a{2}$/) && (match("x 12", /[0-9]{2}/) > 0)) }' \
    || misconfig 'this awk does not support {n,m} interval expressions, so every proximity-bounded shape would silently stop matching (install gawk or mawk >= 1.3.4)'

  local root
  for root in "${SCAN_ROOTS[@]}"; do
    [[ -d "${REPO_ROOT}/${root}" ]] || misconfig "scan root missing: ${root}"
  done
  # Fails CLOSED like the others: check 2 covers these, so losing one silently
  # would drop half of what this guard certifies.
  for root in "${CITE_EXTRA_ROOTS[@]}"; do
    [[ -d "${REPO_ROOT}/${root}" ]] || misconfig "citation scan root missing: ${root}"
  done

  log "Scanning ${#SCAN_ROOTS[@]} roots for energy claims that carry no attribution ..."
  local rc=0
  scan_tree "${REPO_ROOT}" "${ALLOWLIST}" "${SCAN_ROOTS[@]}" || rc=$?
  if (( rc == 0 )); then
    log 'OK: every energy claim in code and CI names model E, a real instrument or a platform source.'
  fi
  exit "${rc}"
}

main "$@"
