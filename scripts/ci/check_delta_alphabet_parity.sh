#!/usr/bin/env bash
# CI guard: the observable whole-second `created_at` delta alphabet must not
# drift between the code that produces it and the four places that quote it.
#
# `PublishStagger.maxGapFor` prices every stagger gap at the burst's own size —
# `clamp(kPublishStaggerMaxSpread / (n - 1), minGap + 1 s, kPublishStaggerMaxGap)`
# — and `created_at` is whole seconds, so what an archive reader can actually
# observe is the set `{2 … ceil(maxGapFor(n) / 1000)}`. That set thins as the
# roster grows: `{2..9}` up to four circles, `{2..8}` at five, `{2..6}` at six,
# `{2..5}` at seven and eight, `{2,3,4}` at nine and ten, `{2,3}` at eleven.
#
# TWO different circle bounds sit in that tail, one circle apart, and which one
# a sentence is about is the whole claim:
#
#   * `kMaxCirclesPerAccount` (10) is the largest burst production can produce.
#     Its alphabet is what the record must state as SHIPPED.
#   * `kMaxCirclesPerBurst` (11) is `maxGapFor`'s next answer. Its `{2,3}` is
#     UNREACHABLE while the account bound holds, so stating it as the shipped
#     alphabet overstates the leak by one whole value — a third of it.
#
# The truth lives in two literal tables in `publish_stagger_test.dart`
# (`_expectedDeltaAlphabet`, `_expectedMaxGapMs`), deliberately literal so that
# a pricing change is a visible edit rather than a re-derivation that agrees
# with whatever ships. Those tables are checked against the real function by
# `expected whole-second delta alphabet, swept over every burst size the app
# admits`. What NOTHING checked until this guard is the other half: that the
# PROSE quoting them still quotes them. `check_privacy_invariants.sh` verifies
# that cited symbols, tests, guards and anchors EXIST; no rule of it compares a
# quoted figure against the code. All four manifest sites that carry this
# alphabet were mutated from the account bound's three values to the cap's two
# and `check_privacy_invariants.sh` exited 0 — the manifest then understated
# nothing and OVERSTATED the leak, in the document the privacy record is read
# from. `haven-core/SECURITY.md` and `haven/lib/src/constants/location.dart`
# carry the same figures with the same exposure.
#
# Six things are checked, each with a distinct failure mode:
#
#   1. THE TRUTH IS READABLE. Every figure is extracted from a declaration —
#      never hard-coded here, because a guard that hard-codes the value keeps
#      passing after a coordinated rename and is then checking nothing. A
#      declaration that moved makes this guard scan nothing, which is a
#      failure and not a pass.
#   2. THE TWO ALPHABETS ARE DISTINCT. If the code's own account-bound and
#      cap alphabets collapse to the same set, every "at the bound it is X, one
#      circle further it is Y" sentence in the record is meaningless and the
#      per-site counts below cannot both hold. Reported as itself rather than
#      as a confusing count mismatch.
#   3. PER-SITE OCCURRENCE COUNTS, BY EQUALITY. Each site must state the
#      account-bound alphabet exactly as often as it does today, and the cap's
#      alphabet exactly as often. Equality and not "at least once": the
#      reviewer's mutation replaced one with the other, which an at-least-one
#      rule sees as "still mentioned". Under-count catches a deleted
#      disclosure; over-count catches a new unreviewed mention.
#   4. THE CARDINALITY WORD. `PUB-COALESCE.forbidden_claim` states the size of
#      the alphabet as an English word rather than the set, so it drifts
#      independently of check 3 and needs its own needle.
#   5. THE PER-GAP CEILING THE MANIFEST QUOTES, in milliseconds, against
#      `_expectedMaxGapMs` at the account bound. The alphabet is derived FROM
#      that ceiling, so a stale ceiling is a stale alphabet stated twice.
#   6. THE PARENTHESISED BOUNDS. Every `kMaxCirclesPerAccount (N)` /
#      `kMaxCirclesPerBurst (N)` gloss in the prose must match the constant,
#      digits or English word. This is what gives `constants/location.dart` —
#      which glosses both bounds but quotes no alphabet — a real check, and it
#      is the figure the whole "one circle apart" distinction rests on.
#
# Pure-grep gate (no Rust or Flutter toolchain), belongs in the shared
# repo-guards job.
#
# Usage:
#   check_delta_alphabet_parity.sh            # check the repo
#   check_delta_alphabet_parity.sh --self-test
#
# Exit codes:
#   0  all checks pass
#   1  a divergence was found (including "could not read" — a moved or renamed
#      declaration scans nothing, which is a guard failure, not a pass)
#   2  misconfiguration, or the self-test failed (the guard itself is broken)

set -Eeuo pipefail

SCRIPT_NAME="check_delta_alphabet_parity"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Pinned by EQUALITY at the end of the self-test, never merely printed: a count
# in prose cannot tell a deleted fixture from a passing run.
readonly SELF_TEST_FIXTURES=20

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Small extractors
# ---------------------------------------------------------------------------

# The value side of one entry of a `const <name> = <...>{ key: value, };` Dart
# map literal, spaces squeezed out.
dart_map_entry() { # dart_map_entry <file> <map-name> <key>
  awk -v head="const $2 = " -v key="  $3: " '
    index($0, head) == 1 { inblock = 1; next }
    inblock && /^};/ { inblock = 0 }
    inblock && index($0, key) == 1 {
      sub(/^[^:]*: /, ""); sub(/,[[:space:]]*$/, "")
      gsub(/[[:space:]]/, "")
      print; exit
    }
  ' "$1"
}

dart_int_const() { # dart_int_const <file> <name>
  sed -n "s/^const int $2 = \([0-9]\+\);\$/\1/p" "$1" | head -1
}

# The line carrying `"<key>":` within 12 lines of the first line matching
# <anchor>. Bounded so a key missing from the anchored object fails closed
# instead of silently matching the next object's copy of it.
json_field() { # json_field <file> <anchor-regex> <key>
  local start
  start="$(grep -n -m1 -E "$2" "$1" | cut -d: -f1 || true)"
  [[ -n "${start}" ]] || return 0
  awk -v start="${start}" -v key="\"$3\":" '
    NR >= start && NR <= start + 12 && index($0, key) { print; exit }
  ' "$1"
}

# ZERO is an answer here, not an error: a count that fell to zero is the
# headline failure this guard reports. `grep` exits 1 on no match, and under
# `pipefail` that would abort the assignment — reporting rc 1 with no message
# at any call site that is not errexit-exempt.
count_needle() { # count_needle <text> <fixed-needle>
  printf '%s' "$1" | { grep -o -F -- "$2" || true; } | wc -l | tr -d ' '
}

num_word() { # num_word <1..12>
  case "$1" in
    1) printf one ;;   2) printf two ;;    3) printf three ;;
    4) printf four ;;  5) printf five ;;   6) printf six ;;
    7) printf seven ;; 8) printf eight ;;  9) printf nine ;;
    10) printf ten ;;  11) printf eleven ;; 12) printf twelve ;;
    *) return 1 ;;
  esac
}

word_num() { # word_num <one..twelve> -> digits, or nothing if not a number word
  local n
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [[ "$1" == "$(num_word "${n}")" ]]; then printf '%s' "${n}"; return 0; fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# check_parity <stagger.dart> <stagger_test.dart> <manifest.json> <security.md>
#              <location.dart>
# ---------------------------------------------------------------------------
check_parity() {
  local stagger="$1" stagger_test="$2" manifest="$3" security="$4" location="$5"
  local fail=0

  # --- check 1: the truth -------------------------------------------------
  local account_bound burst_cap account_alpha cap_alpha account_gap_ms
  account_bound="$(dart_int_const "${stagger}" kMaxCirclesPerAccount)"
  burst_cap="$(dart_int_const "${stagger}" kMaxCirclesPerBurst)"

  if [[ -z "${account_bound}" ]]; then
    fail_msg "could not read kMaxCirclesPerAccount from \
${stagger#"${REPO_ROOT}/"} — the declaration moved or changed shape, so this guard is \
scanning nothing. Re-point dart_int_const at the new declaration."
    fail=1
  fi
  if [[ -z "${burst_cap}" ]]; then
    fail_msg "could not read kMaxCirclesPerBurst from \
${stagger#"${REPO_ROOT}/"} — the declaration moved or changed shape. Re-point \
dart_int_const at the new declaration."
    fail=1
  fi
  (( fail == 0 )) || return 1

  account_alpha="$(dart_map_entry "${stagger_test}" _expectedDeltaAlphabet "${account_bound}")"
  cap_alpha="$(dart_map_entry "${stagger_test}" _expectedDeltaAlphabet "${burst_cap}")"
  account_gap_ms="$(dart_map_entry "${stagger_test}" _expectedMaxGapMs "${account_bound}")"

  if [[ -z "${account_alpha}" || -z "${cap_alpha}" ]]; then
    fail_msg "could not read _expectedDeltaAlphabet[${account_bound}] and/or \
[${burst_cap}] from ${stagger_test#"${REPO_ROOT}/"} — the table moved, was renamed, or no \
longer keys at the account bound and the burst cap. Re-point dart_map_entry, or restore \
the rows: the prose below is measured against them."
    fail=1
  fi
  if [[ -z "${account_gap_ms}" ]]; then
    fail_msg "could not read _expectedMaxGapMs[${account_bound}] from \
${stagger_test#"${REPO_ROOT}/"} — the table moved, was renamed, or no longer keys at the \
account bound. Re-point dart_map_entry."
    fail=1
  fi
  (( fail == 0 )) || return 1

  echo "  [1/6] truth read: kMaxCirclesPerAccount=${account_bound} \
kMaxCirclesPerBurst=${burst_cap} alphabet=${account_alpha} \
(cap ${cap_alpha}) ceiling=${account_gap_ms}ms."

  # --- check 2: the two alphabets are distinct ----------------------------
  if [[ "${account_alpha}" == "${cap_alpha}" ]]; then
    fail_msg "the code's own alphabets at the account bound (${account_bound}) and the \
burst cap (${burst_cap}) are both ${account_alpha}. Every record sentence of the form \
'X at the bound, Y one circle further' is then false, and the per-site counts below \
cannot distinguish them. Fix _expectedDeltaAlphabet or the pricing rule first."
    return 1
  fi
  echo "  [2/6] the account-bound and cap alphabets are distinct."

  # --- check 3: per-site occurrence counts, by equality -------------------
  #
  # `<label>|<text>|<expected account mentions>|<expected cap mentions>`.
  # The counts are prose facts and therefore literals; the STRINGS counted are
  # read from the code above, which is what makes this a parity check rather
  # than a spell-check.
  local sites=() label text want_a want_c got_a got_c
  local f_summary f_statement
  f_summary="$(json_field "${manifest}" '"id": "PUB-COALESCE"' summary)"
  f_statement="$(json_field "${manifest}" \
    '"id": "INV-R-PER-CIRCLE-PUBLISH-DECORRELATED"' statement)"

  local site_missing=0
  [[ -n "${f_summary}" ]] || { fail_msg "manifest: no \"summary\" within 12 lines of the \
PUB-COALESCE entry (${manifest#"${REPO_ROOT}/"}) — the entry moved or was renamed, so this \
guard would check nothing. Re-point the json_field anchor."; site_missing=1; }
  [[ -n "${f_statement}" ]] || { fail_msg "manifest: no \"statement\" within 12 lines of \
the INV-R-PER-CIRCLE-PUBLISH-DECORRELATED entry — the entry moved or was renamed. \
Re-point the json_field anchor."; site_missing=1; }
  (( site_missing == 0 )) || return 1

  sites+=("PUB-COALESCE.summary|${f_summary}|2|1")
  sites+=("INV-R-PER-CIRCLE-PUBLISH-DECORRELATED.statement|${f_statement}|1|1")
  # Never `ratchet_override.reason`: it is PR-scoped justification that
  # check_privacy_invariants.sh REQUIRES be deleted in the first commit after
  # a merge, so pinning it made the two guards contradict each other.
  sites+=("${security#"${REPO_ROOT}/"}|$(cat "${security}")|2|1")
  sites+=("${stagger#"${REPO_ROOT}/"} (doc comment)|$(cat "${stagger}")|1|1")

  local site
  for site in "${sites[@]}"; do
    label="${site%%|*}"; site="${site#*|}"
    want_c="${site##*|}"; site="${site%|*}"
    want_a="${site##*|}"; text="${site%|*}"

    got_a="$(count_needle "${text}" "${account_alpha}")"
    got_c="$(count_needle "${text}" "${cap_alpha}")"

    if [[ "${got_a}" != "${want_a}" ]]; then
      fail_msg "${label}: states the account-bound alphabet ${account_alpha} \
${got_a} time(s), expected ${want_a}. That set is what the app can actually produce \
(_expectedDeltaAlphabet[kMaxCirclesPerAccount] = ${account_alpha}); losing a mention is a \
disclosure that stopped being made, and gaining one is a claim nobody reviewed. If the new \
prose is right, update this guard's count for ${label} in the same commit."
      fail=1
    fi
    if [[ "${got_c}" != "${want_c}" ]]; then
      fail_msg "${label}: states the burst-cap alphabet ${cap_alpha} ${got_c} \
time(s), expected ${want_c}. ${cap_alpha} is maxGapFor's answer at \
kMaxCirclesPerBurst (${burst_cap}) — one circle past anything the account bound \
(${account_bound}) admits — so presenting it as the shipped alphabet overstates the leak, \
and dropping the 'one circle further, unreachable' aside hides that the record ever \
distinguished them. If the new prose is right, update this guard's count for ${label}."
      fail=1
    fi
  done
  (( fail == 0 )) && echo "  [3/6] every site states ${account_alpha} for the account \
bound, and ${cap_alpha} only as the unreachable next answer."

  # --- check 4: the cardinality word --------------------------------------
  local f_forbidden card_word claimed
  f_forbidden="$(json_field "${manifest}" '"id": "PUB-COALESCE"' forbidden_claim)"
  if [[ -z "${f_forbidden}" ]]; then
    fail_msg "manifest: no \"forbidden_claim\" within 12 lines of the PUB-COALESCE entry \
— re-point the json_field anchor."
    fail=1
  else
    # |{2,3,4}| — the commas plus one, over the extracted set.
    card_word="$(num_word "$(( $(count_needle "${account_alpha}" ',') + 1 ))")"
    claimed="$(printf '%s' "${f_forbidden}" \
      | grep -oE 'falls to [a-z]+ at kMaxCirclesPerAccount' | head -1 || true)"
    if [[ -z "${claimed}" ]]; then
      fail_msg "PUB-COALESCE.forbidden_claim no longer contains 'falls to <word> at \
kMaxCirclesPerAccount' — the phrase that states the alphabet's SIZE as a word, which \
drifts independently of the set itself. Re-point this needle at wherever the size is now \
stated, or restore the phrase."
      fail=1
    elif [[ "${claimed}" != "falls to ${card_word} at kMaxCirclesPerAccount" ]]; then
      fail_msg "PUB-COALESCE.forbidden_claim says '${claimed}', but \
_expectedDeltaAlphabet[${account_bound}] = ${account_alpha} has ${card_word} values. The \
forbidden claim is what copy is graded against; a wrong size there licenses copy that \
understates or overstates the leak."
      fail=1
    else
      echo "  [4/6] the forbidden claim's cardinality word (${card_word}) matches \
${account_alpha}."
    fi
  fi

  # --- check 5: the per-gap ceiling the manifest quotes -------------------
  local quoted_ceiling
  quoted_ceiling="$(printf '%s' "${f_statement}" \
    | grep -oE 'shrinks to [0-9]+ ms at kMaxCirclesPerAccount' | head -1 || true)"
  if [[ -z "${quoted_ceiling}" ]]; then
    fail_msg "INV-R-PER-CIRCLE-PUBLISH-DECORRELATED.statement no longer contains \
'shrinks to <N> ms at kMaxCirclesPerAccount' — the per-gap ceiling the alphabet is DERIVED \
from. Re-point this needle, or restore the figure."
    fail=1
  elif [[ "${quoted_ceiling}" != "shrinks to ${account_gap_ms} ms at kMaxCirclesPerAccount" ]]; then
    fail_msg "INV-R-PER-CIRCLE-PUBLISH-DECORRELATED.statement says '${quoted_ceiling}', \
but _expectedMaxGapMs[${account_bound}] = ${account_gap_ms}. The alphabet is \
ceil(ceiling / 1000) wide, so a stale ceiling is a stale alphabet stated a second way."
    fail=1
  else
    echo "  [5/6] the manifest's per-gap ceiling at the bound (${account_gap_ms} ms) \
matches _expectedMaxGapMs."
  fi

  # --- check 6: the parenthesised bounds ---------------------------------
  local prose_file sym want got raw seen
  for prose_file in "${manifest}" "${security}" "${location}"; do
    for sym in kMaxCirclesPerAccount kMaxCirclesPerBurst; do
      want="${account_bound}"
      [[ "${sym}" == kMaxCirclesPerBurst ]] && want="${burst_cap}"
      seen=0
      while IFS= read -r raw; do
        [[ -n "${raw}" ]] || continue
        got="${raw#*(}"
        # Only glosses that state a NUMBER are graded; '(owner decision, …)'
        # and friends are prose, not a figure this guard owns.
        [[ "${got}" =~ ^[0-9]+$ ]] || got="$(word_num "${got}")"
        [[ -n "${got}" ]] || continue
        seen=$(( seen + 1 ))
        if [[ "${got}" != "${want}" ]]; then
          fail_msg "${prose_file#"${REPO_ROOT}/"}: glosses ${sym} as (${got}) but the \
constant is ${want}. The account bound and the burst cap are ONE circle apart and the \
whole alphabet claim turns on which is which, so a wrong gloss silently moves the \
disclosure to the other bound."
          fail=1
        fi
      done < <(grep -oE "${sym}\`? \([A-Za-z0-9]+" "${prose_file}" | sed 's/^[^(]*(/(/' || true)
      if (( seen == 0 )); then
        fail_msg "${prose_file#"${REPO_ROOT}/"}: no numeric gloss of ${sym} found at all \
— every occurrence lost its '(N)', so check 6 would pass vacuously here. Restore one \
gloss, or drop this file from the loop deliberately."
        fail=1
      fi
    done
  done
  (( fail == 0 )) && echo "  [6/6] every numeric gloss of both bounds matches its \
constant."

  (( fail == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state, no toolchain.
#
# (2)-(5) are the defect this guard exists for: the reviewer's mutation, run at
# each of the four manifest sites that carry the claim, including the one that
# states the size as a word rather than as a set. (6)-(9) are the same drift in
# the two other documents and in the code file's own doc comment. (10)-(13) are
# the CODE moving under the prose, which is the direction that leaves the docs
# stale without anybody touching them. (14)-(19) are the fail-closed paths: a
# declaration, table row, anchor or gloss that moved must FAIL, never pass for
# want of something to compare.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local d="${tmp}/base"
  mkdir -p "${d}"

  _write_base() {
    cat > "${d}/stagger.dart" <<'DART'
/// Doc: the alphabet thins to `{2,3,4}` at [kMaxCirclesPerAccount], and
/// `maxGapFor` answers `{2,3}` one circle further, which nothing reaches.
const int kMaxCirclesPerBurst = 11;
const int kMaxCirclesPerAccount = 10;
DART
    cat > "${d}/stagger_test.dart" <<'DART'
const _expectedMaxGapMs = <int, int>{
  2: 9000,
  10: 3333,
  11: 3000,
};
const _expectedDeltaAlphabet = <int, Set<int>>{
  2: {2, 3, 4, 5, 6, 7, 8, 9},
  10: {2, 3, 4},
  11: {2, 3},
};
DART
    cat > "${d}/manifest.json" <<'JSON'
{
  "deviations": [
    {
      "id": "PUB-COALESCE",
      "summary": "thins to {2,3,4} at kMaxCirclesPerAccount (10); the {2,3} maxGapFor answers at kMaxCirclesPerBurst (11) is unreachable, and {2,3,4} is what ships.",
      "forbidden_claim": "Copy must not present the stagger as buying more than a number that falls to three at kMaxCirclesPerAccount."
    }
  ],
  "invariants": [
    {
      "id": "INV-R-PER-CIRCLE-PUBLISH-DECORRELATED",
      "statement": "the ceiling shrinks to 3333 ms at kMaxCirclesPerAccount (10), so the alphabet is {2,3,4}; {2,3} is maxGapFor's answer at kMaxCirclesPerBurst (11)."
    }
  ]
}
JSON
    cat > "${d}/security.md" <<'MD'
The alphabet is `{2,3,4}` at `kMaxCirclesPerAccount` (10), the largest burst a
bounded roster can produce, and `{2,3,4}` is therefore what ships. `maxGapFor`
answers `{2,3}` one circle further, at `kMaxCirclesPerBurst` (11).
MD
    cat > "${d}/location.dart" <<'DART'
/// `kMaxCirclesPerAccount` (10) keeps the deferral branch of
/// `kMaxCirclesPerBurst` (11) out of production reach.
DART
  }

  _case() { # _case <label> <expect-rc> [<file> <sed-expr>]...
    local label="$1" want="$2" got=0
    shift 2
    checked=$(( checked + 1 ))
    rm -rf "${d}"; mkdir -p "${d}"; _write_base
    while (( $# >= 2 )); do
      if [[ "$2" == "DELETE" ]]; then : > "${d}/$1"; else sed -i "$2" "${d}/$1"; fi
      shift 2
    done
    ( check_parity "${d}/stagger.dart" "${d}/stagger_test.dart" \
        "${d}/manifest.json" "${d}/security.md" "${d}/location.dart" ) \
      >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  log "self-test: delta-alphabet parity"

  # (1) Happy path.
  _case "a record that quotes the account bound passes" 0

  # (2)-(5) THE CRITICAL FIXTURES — the account bound's alphabet replaced by
  #         the cap's, at each DURABLE manifest site that carries it; (4) is
  #         the opposite direction, proving the PR-scoped override reason is
  #         not one of them.
  _case "PUB-COALESCE.summary downgraded to the cap alphabet FAILS" 1 \
    manifest.json '/"summary"/ s/{2,3,4}/{2,3}/g'
  _case "the invariant statement downgraded to the cap alphabet FAILS" 1 \
    manifest.json '/"statement"/ s/{2,3,4}/{2,3}/g'
  _case "a stale override reason is not a pinned site, so it never FAILS" 0 \
    manifest.json '$ s/^}$/  ,"ratchet_override": {"reason": "justified the old cap alphabet {2,3}"}\n}/'
  _case "the forbidden claim's cardinality word downgraded FAILS" 1 \
    manifest.json 's/falls to three at/falls to two at/'

  # (6)-(8) The same drift outside the manifest.
  _case "SECURITY.md downgraded to the cap alphabet FAILS" 1 \
    security.md 's/{2,3,4}/{2,3}/g'
  _case "the code file's own doc comment downgraded FAILS" 1 \
    stagger.dart 's/{2,3,4}/{2,3}/'
  _case "a bound glossed with the other bound's figure FAILS" 1 \
    location.dart 's/kMaxCirclesPerAccount` (10)/kMaxCirclesPerAccount` (11)/'

  # (9) The manifest's quoted per-gap ceiling drifts alone.
  _case "a stale per-gap ceiling in the manifest FAILS" 1 \
    manifest.json 's/shrinks to 3333 ms/shrinks to 3000 ms/'

  # (10)-(13) The CODE moves under prose nobody touched.
  _case "the code's account-bound alphabet thinning FAILS" 1 \
    stagger_test.dart 's/^  10: {2, 3, 4},$/  10: {2, 3},/'
  _case "the code's per-gap ceiling moving FAILS" 1 \
    stagger_test.dart 's/^  10: 3333,$/  10: 3400,/'
  _case "the account bound moving FAILS" 1 \
    stagger.dart 's/kMaxCirclesPerAccount = 10;/kMaxCirclesPerAccount = 9;/'
  _case "the burst cap moving FAILS" 1 \
    stagger.dart 's/kMaxCirclesPerBurst = 11;/kMaxCirclesPerBurst = 12;/'

  # (14)-(15) Count equality in BOTH directions, so the rule is not
  #           "at least one mention".
  _case "an extra unreviewed mention FAILS" 1 \
    security.md '2 s/$/ Also {2,3,4}./'
  _case "a deleted 'one circle further' aside FAILS" 1 \
    security.md 's/`{2,3}` one circle further, at/one circle further, at/'

  # (16)-(19) Fail-closed: nothing to compare is a FAILURE.
  _case "a renamed account-bound constant FAILS" 1 \
    stagger.dart 's/kMaxCirclesPerAccount = 10;/kMaxCirclesPerAccountV2 = 10;/'
  _case "a renamed alphabet table FAILS" 1 \
    stagger_test.dart 's/_expectedDeltaAlphabet/_expectedDeltaAlphabetV2/'
  _case "a moved PUB-COALESCE entry FAILS" 1 \
    manifest.json 's/"id": "PUB-COALESCE"/"id": "PUB-COALESCE-V2"/'
  _case "a gloss that lost its figure FAILS" 1 \
    location.dart 's/`kMaxCirclesPerBurst` (11)/`kMaxCirclesPerBurst`/'

  # (20) Anti-vacuity on check 2: if the code's two alphabets collapse, say so
  #      rather than emitting confusing count mismatches.
  _case "the code's two alphabets collapsing FAILS" 1 \
    stagger_test.dart 's/^  11: {2, 3},$/  11: {2, 3, 4},/'

  if (( fails )); then
    fail_msg "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    fail_msg "self-test ran ${checked} fixture(s), expected exactly \
${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one \
way a deleted fixture reports success."
    exit 2
  fi
  log "OK: self-test passed (${checked}/${SELF_TEST_FIXTURES} fixtures)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  local stagger="${REPO_ROOT}/haven/lib/src/services/publish_stagger.dart"
  local stagger_test="${REPO_ROOT}/haven/test/services/publish_stagger_test.dart"
  local manifest="${REPO_ROOT}/docs/privacy/privacy_invariants.json"
  local security="${REPO_ROOT}/haven-core/SECURITY.md"
  local location="${REPO_ROOT}/haven/lib/src/constants/location.dart"

  local f
  for f in "${stagger}" "${stagger_test}" "${manifest}" "${security}" "${location}"; do
    [[ -f "${f}" ]] || misconfig "${f#"${REPO_ROOT}/"} not found — a moved file makes this \
guard scan nothing; re-point main()."
  done

  if check_parity "${stagger}" "${stagger_test}" "${manifest}" "${security}" "${location}"; then
    log "OK: the observable delta alphabet agrees between the code and every site \
that quotes it."
    exit 0
  fi
  fail_msg "the quoted delta alphabet diverged from the code (see above)."
  exit 1
}

main "$@"
