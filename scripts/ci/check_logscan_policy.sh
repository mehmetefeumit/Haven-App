#!/usr/bin/env bash
#
# CI guard: the runtime log scanner's policy and allowlist keep their shape —
# checked from the text, without cargo, so the shape holds on every push even
# where the crate is not built.
#
# ## Why this exists
#
# `tooling/logscan/policy.toml` is compiled into `haven-logscan`, and the crate
# validates it at load. That validation runs where the crate runs: the
# rust-check job that builds it, and the lanes that call it. A policy edit that
# quietly re-introduces a deferral class, switches a sink's structural rules
# off, or drops a plant expectation is a change to what "clean" means in every
# lane at once, and it is a one-line diff in a file nobody reads by default.
# This guard reads it on every push, in the guards job, with the shape pinned
# as a list rather than as a property of whatever the file currently says.
#
# ## What is checked
#
#   P1  NO DEFERRAL. The policy's code lines (comments stripped) and the whole
#       allowlist carry none of `deferred`, `deferral`, `until`, `class_b`. The
#       owner rejected deferral classes (OD-L1/OD-L2); a key, a value or a
#       justification that speaks of "until" is that decision being undone. The
#       policy's own header may NAME the rejection in a comment.
#   P2  STRUCTURAL RULES ON. Every `[sinks]` entry has `structural_rules = true`
#       except the ones in STRUCTURAL_RULES_OFF, each with its reason here.
#   P3  PLANT EXPECTATION PINNED. Every `[sinks]` entry carries
#       `declared_plants_expected`; it is `false` for exactly the sinks in
#       DECLARED_PLANTS_OFF and `true` for every other one; and the README's
#       positive-controls bullet names each `false` sink, so the reason is
#       written where the next reader looks.
#   P4  ALLOWLIST SHAPE. A JSON array; every entry has exactly `rule`, `scope`
#       (`sink_glob`, optional `tag`), `pattern`, `justification`, `proof`,
#       `owner`, `expires`; `rule` is an `S<n>` id; `justification` and
#       `owner` are non-empty; `expires` is a real `YYYY-MM-DD` not before
#       today; `proof` is `file` or `file:line` under the repository root, with
#       no `..`, the file present and the line within it.
#   P5  LEDGER COMPLETE. Every class in `[classes]` other than the `plant` kind
#       (matched literally, never expanded) has a `[ledger.<class>]` table, and
#       every ledger table names a declared class.
#   P6  CARGO EXEMPTION CONFINED. `cargo_status = "exempt"` appears on exactly
#       the sinks in CARGO_STATUS_EXEMPT (today: `rust-test`, `soak`), every other
#       `[sinks]` entry either omits the key or says `"scanned"`, and the
#       README explains the knob and names each exempt sink. It is the one
#       exemption that belongs to a sink class rather than to a rule, so a
#       second sink acquiring it silently is a widening nothing else reports.
#   P7  NEEDLE EXEMPTION PINNED. `emitter_scoped_out` — the classes NOT searched
#       on one named emitter's own records — appears on exactly the sinks in
#       EMITTER_SCOPED_OUT, spelled exactly as pinned there, and the README
#       names the emitter. It is the only exemption in this tree that touches
#       the NEEDLE search (a value the run actually minted), so widening it by
#       an emitter, a class or a sink must not be a one-line diff nobody reads.
#   P8  PROOF-OF-RUN PINNED. `proof_of_run` — the line that proves a capture is
#       of a run that HAPPENED — appears on exactly the sinks in PROOF_OF_RUN
#       (today: `drive` alone, the one class whose every capture comes from a
#       test reporter), spelled exactly as pinned there, and the README explains
#       it. Both directions matter: dropping it from `drive` would leave that
#       class's anti-vacuity check to a line count, which cannot tell a short
#       COMPLETE transcript from an empty one (CI run 35464818348), and adding
#       it to a class whose producer writes no such line would be rc 4 on every
#       green run.
#
# Floors on the number of sinks and classes parsed keep a policy the parser
# has stopped reading from passing as compliant. What the floors CANNOT see is a
# sink written as a block table (`[sinks.ios]`) rather than as the inline table
# every entry uses today: `section_entries` reads inline tables only, so a sink
# rewritten that way would be parsed by nothing here and would collapse the
# floor instead of passing quietly. The crate's own
# `the_emitter_needle_scope_is_pinned` covers that shape, because it reads the
# PARSED policy rather than its text.
#
# ## What is deliberately NOT here
#
#   * the ledger's reconciliation against the expander, the per-sink framing
#     rules, the term floors — the crate's own tests and `--self-test`;
#   * where `--rules-only` may appear and which lanes run the wrapper —
#     check_logscan_wired_everywhere.sh.
#
# Usage:
#   check_logscan_policy.sh              # enforce over the repo
#   check_logscan_policy.sh --self-test  # hermetic fixtures, count pinned
#
# Exit codes:
#   0  every rule holds
#   1  a violation was found
#   2  the guard could not read its inputs (missing file, unparseable JSON, floor, self-test failure)

set -euo pipefail

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SELF_NAME
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

readonly POLICY_REL='tooling/logscan/policy.toml'
readonly ALLOWLIST_REL='tooling/logscan/allowlist.json'
readonly README_REL='tooling/logscan/README.md'
# `_` is a boundary too, so `deferred_until` is two hits, not a new word.
readonly DEFERRAL_RE='(^|[^a-z])(deferred|deferral|until|class_b)([^a-z]|$)'
readonly PLANT_KIND='plant'
# Measured 2026-09-16: 7 sinks, 18 classes. A parser that stops matching
# collapses well past these.
readonly MIN_SINKS=6
readonly MIN_CLASSES=14

# Sinks whose structural rules are off, with the reason.
declare -A STRUCTURAL_RULES_OFF=(
  ['relay']='a relay log legitimately holds pubkeys, event ids and #h tags; the public classes are scoped out and the secret classes, names and coordinates stay searched'
)
# Sinks that skip cargo's crate-build line for S2 and S6, with the reason; the
# README must explain the knob and name each one. A second entry here is a
# second capture claiming to be a cargo transcript — which is what the scanner's
# narrowest exemption rests on.
declare -A CARGO_STATUS_EXEMPT=(
  ['rust-test']='the only class that holds a cargo transcript; cargo prints the public pinned git revision of every git dependency and every crate name before a test runs'
  ['soak']='the soak lane captures the rig binary through cargo run, so a cold build prints the same pinned git revisions and crate names ahead of the rig'
)
# The policy's ONE needle exemption, pinned verbatim: the emitter whose own
# records are the SOURCE of a class rather than a place it leaked to. Every
# other exemption in this tree belongs to a structural rule, so a second one
# appearing — or this one widening to another emitter, another class or another
# sink — is a change to what "clean" means that nothing else reports from the
# text. The README must name the emitter.
declare -A EMITTER_SCOPED_OUT=(
  ['ios']='emitter_scoped_out = [{ process = "locationd", emitter = "com.apple.locationd.Position", classes = ["coordinate"] }]'
)
readonly EMITTER_SCOPE_KEY='emitter_scoped_out'
readonly EMITTER_SCOPE_DOC='com.apple.locationd.Position'
# The sink classes that prove a capture is of a run that HAPPENED, pinned
# verbatim with the line they prove it by. A line floor cannot make that
# distinction — how long a `flutter drive` transcript is depends on the device
# chatter the tool forwarded, so the floor that clears the shortest complete one
# clears an empty one too — and the test reporter's progress line, written
# before the first test body runs, can. Only a class whose every capture comes
# from a test reporter may carry it; on any other class it would be rc 4 on
# every green run. The README must explain the key.
declare -A PROOF_OF_RUN=(
  ['drive']="proof_of_run = '[0-9]{2}:[0-9]{2} \\+[0-9]+( -[0-9]+)?: '"
)
readonly PROOF_OF_RUN_KEY='proof_of_run'
# Sinks whose DECLARED Dart plant tokens are not demanded, with the reason;
# the README's positive-controls bullet must name each one.
declare -A DECLARED_PLANTS_OFF=(
  ['ios']='no captured log show export has yet shown a Dart token; unproven, not impossible — the first capture that carries one flips it'
  ['rust-test']='a unit-test transcript carries no app output'
  ['proxy']='the recorder log carries no app output'
  ['diag']='host diagnostics carry no app output'
  ['relay']='a relay log carries no app output'
  ['soak']='the Tier-1 rig is a Rust process with no Dart channel at all: nothing can hand it a declared token to print, so a Dart plant would be a control nothing could ever satisfy. Its `rust` shape plant is what proves the sink was reached — emitted through the installed log sink as the first and last line of every scenario capture, never written straight to the file'
)

VIOLATIONS=0
BROKEN=0
violation() { printf 'FAIL: %s\n' "$*" >&2; VIOLATIONS=$((VIOLATIONS + 1)); }
broken()    { printf 'BROKEN: %s\n' "$*" >&2; BROKEN=$((BROKEN + 1)); }
log()       { printf '[%s] %s\n' "${SELF_NAME}" "$*"; }

# Code lines of the policy: full-line comments dropped, trailing ` #…` cut.
policy_code() { sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#.*$//' "$1"; }

# `<name>\t<body>` for every inline-table entry under a `[section]` header.
section_entries() { # section_entries <policy> <section>
  policy_code "$1" | awk -v sec="[$2]" '
    /^\[/ { insec = ($0 == sec); next }
    insec && match($0, /^[a-z_-]+[[:space:]]*=[[:space:]]*\{/) {
      name = $0; sub(/[[:space:]]*=.*$/, "", name)
      body = $0; sub(/^[^{]*\{/, "", body); sub(/\}[[:space:]]*$/, "", body)
      print name "\t" body
    }'
}

field_of() { # field_of <body> <key> → the bare value, or ""
  sed -nE "s/.*(^|[[:space:],])$2[[:space:]]*=[[:space:]]*(\"[^\"]*\"|[^,[:space:]]+).*/\2/p" <<<"$1" | tr -d '"'
}

check_policy() { # check_policy <policy> <readme>
  local policy="$1" readme="$2" rel="${POLICY_REL}"
  local hits
  hits="$(policy_code "${policy}" | grep -niE -- "${DEFERRAL_RE}" || true)"
  if [[ -n "${hits}" ]]; then
    violation "${rel}: deferral vocabulary on a code line (\`$(awk 'NR == 1' <<<"${hits}")\`). The policy is all-blocking: no class is deferred, no allowance waits \"until\" anything. Delete the key or the value; the header comment is the only place the rejected words belong."
  fi

  local entries name body v n_sinks=0
  entries="$(section_entries "${policy}" sinks)"
  while IFS=$'\t' read -r name body; do
    [[ -n "${name}" ]] || continue
    n_sinks=$((n_sinks + 1))
    v="$(field_of "${body}" structural_rules)"
    if [[ -n "${STRUCTURAL_RULES_OFF[${name}]+x}" ]]; then
      [[ "${v}" == "false" ]] || violation "${rel}: sink \`${name}\` is listed in STRUCTURAL_RULES_OFF (${STRUCTURAL_RULES_OFF[${name}]}) but has structural_rules = ${v:-<absent>}. Re-decide: switch it off, or delete the entry from the list in the same change."
    elif [[ "${v}" != "true" ]]; then
      violation "${rel}: sink \`${name}\` has structural_rules = ${v:-<absent>}. Every sink runs S1–S12 unless it is in STRUCTURAL_RULES_OFF with its reason; switching a sink's rules off silently widens what \"clean\" means in every lane that scans it."
    fi
    v="$(field_of "${body}" declared_plants_expected)"
    if [[ -z "${v}" ]]; then
      violation "${rel}: sink \`${name}\` carries no declared_plants_expected. Whether the declared Dart tokens must reach a sink is a per-sink decision recorded on the entry, never a default."
    elif [[ -n "${DECLARED_PLANTS_OFF[${name}]+x}" ]]; then
      [[ "${v}" == "false" ]] || violation "${rel}: sink \`${name}\` is listed in DECLARED_PLANTS_OFF (${DECLARED_PLANTS_OFF[${name}]}) but has declared_plants_expected = ${v}. If a capture proved the token reaches it, delete the entry from the list and the README's reason in the same change."
    elif [[ "${v}" != "true" ]]; then
      violation "${rel}: sink \`${name}\` has declared_plants_expected = ${v} but is not in DECLARED_PLANTS_OFF. Waiving the positive control is the one way a dead capture reads as clean; list the sink with its reason and name it in the README's positive-controls bullet."
    fi
    # P6: the cargo exemption, which skips S2 and S6 on cargo's crate-build
    # line. Absent means scanned, so only an explicit `"exempt"` is a decision.
    v="$(field_of "${body}" cargo_status)"
    v="${v//\"/}"
    if [[ -n "${CARGO_STATUS_EXEMPT[${name}]+x}" ]]; then
      [[ "${v}" == "exempt" ]] || violation "${rel}: sink \`${name}\` is listed in CARGO_STATUS_EXEMPT (${CARGO_STATUS_EXEMPT[${name}]}) but has cargo_status = ${v:-<absent>}. Re-decide: set it, or delete the entry from the list in the same change."
    elif [[ -n "${v}" && "${v}" != "scanned" ]]; then
      violation "${rel}: sink \`${name}\` has cargo_status = ${v}. Only a class that holds a CARGO transcript may skip cargo's crate-build line (S2 and S6 on it); on any other capture that shape is app output. List the sink with its reason here and in the README, or delete the key."
    fi
    # P7: the per-emitter NEEDLE exemption, pinned as a literal. A needle is a
    # value this run minted, so not searching for it somewhere is the widest
    # allowance the policy can make.
    if [[ -n "${EMITTER_SCOPED_OUT[${name}]+x}" ]]; then
      grep -qF -- "${EMITTER_SCOPED_OUT[${name}]}" <<<"${body}" \
        || violation "${rel}: sink \`${name}\` no longer carries the pinned needle exemption \`${EMITTER_SCOPED_OUT[${name}]}\`. Widening it (a second emitter, a second class) or dropping it are both decisions; make the same change here, with the reason, and in the README."
    elif grep -qF -- "${EMITTER_SCOPE_KEY}" <<<"${body}"; then
      violation "${rel}: sink \`${name}\` scopes a needle class out of an emitter and is not pinned here. A needle is a value the run minted; declining to search for it on some emitter's lines is the one allowance with no allowlist path, so it is listed here verbatim and explained in the README, or it does not exist."
    fi
    # P8: the proof that a capture's subject ran at all, pinned as a literal in
    # both directions.
    if [[ -n "${PROOF_OF_RUN[${name}]+x}" ]]; then
      grep -qF -- "${PROOF_OF_RUN[${name}]}" <<<"${body}" \
        || violation "${rel}: sink \`${name}\` no longer carries the pinned proof-of-run line \`${PROOF_OF_RUN[${name}]}\`. Without it this class's only anti-vacuity check is a line count, which cannot tell a short COMPLETE capture from one in which nothing ran (CI run 35464818348). Changing what proves a run is a decision; make it here, with the reason, and in the README."
    elif grep -qF -- "${PROOF_OF_RUN_KEY}" <<<"${body}"; then
      violation "${rel}: sink \`${name}\` declares a proof_of_run and is not pinned here. Only a class whose every capture comes from a test reporter has a line written before the first test body; demanding one from any other producer is rc 4 on every green run. List it here with the reason, and in the README, or delete the key."
    fi
  done <<<"${entries}"
  if (( n_sinks < MIN_SINKS )); then
    broken "${rel}: parsed ${n_sinks} sink(s) under [sinks], expected at least ${MIN_SINKS}. The section parser has stopped matching, so every verdict above is vacuous."
  fi

  # The README names why each waived sink is waived, in the bullet that
  # defines the knob.
  local bullet s
  bullet="$(awk '/declared_plants_expected/ && !found { found = 1 } found { if ($0 ~ /^[[:space:]]*$/) exit; print }' "${readme}")"
  if [[ -z "${bullet}" ]]; then
    violation "${README_REL}: no paragraph mentions declared_plants_expected. The waived sinks' reasons are recorded there; a knob the README does not explain is a knob the next reader flips blind."
  else
    for s in "${!DECLARED_PLANTS_OFF[@]}"; do
      grep -qF -- "\`${s}\`" <<<"${bullet}" || violation "${README_REL}: the declared_plants_expected paragraph does not name \`${s}\`, which the policy waives. Say why, there."
    done
  fi

  # …and the same cross-check for the cargo exemption: the knob is explained
  # where the next reader looks, and every exempt sink is named there.
  local cargo_doc
  cargo_doc="$(grep -nF -- 'cargo_status = "exempt"' "${readme}" || true)"
  if [[ -z "${cargo_doc}" ]]; then
    violation "${README_REL}: nothing explains \`cargo_status = \"exempt\"\`. It is the only exemption that belongs to a sink class rather than a rule; a knob the README does not explain is a knob the next reader widens blind."
  else
    for s in "${!CARGO_STATUS_EXEMPT[@]}"; do
      grep -qF -- "\`${s}\`" "${readme}" || violation "${README_REL}: the README does not name \`${s}\`, which the policy exempts from S2 and S6 on cargo's crate-build line. Say why, there."
    done
  fi

  # …and the same cross-check for the needle exemption: the emitter whose
  # records are searched for one class less is named where the next reader looks.
  if (( ${#EMITTER_SCOPED_OUT[@]} > 0 )) && ! grep -qF -- "${EMITTER_SCOPE_DOC}" "${readme}"; then
    violation "${README_REL}: the README does not name \`${EMITTER_SCOPE_DOC}\`, the emitter the policy scopes a needle class out of. It is the only needle exemption in the tree; say there which class, why that emitter holds the value by construction, and what still catches a real leak of it."
  fi

  # …and for the proof-of-run line: the one anti-vacuity check that is not a
  # number, so the next reader has to find it where the floors are explained.
  if (( ${#PROOF_OF_RUN[@]} > 0 )) && ! grep -qF -- "${PROOF_OF_RUN_KEY}" "${readme}"; then
    violation "${README_REL}: nothing explains \`${PROOF_OF_RUN_KEY}\`. It is what a line floor cannot be — the proof that a capture's subject ran at all — so say there which class carries it, which line proves it, and why a floor could not."
  fi

  local classes ledgers kind n_classes=0
  classes="$(section_entries "${policy}" classes)"
  ledgers="$(policy_code "${policy}" | sed -nE 's/^\[ledger\.([a-z_]+)\][[:space:]]*$/\1/p')"
  while IFS=$'\t' read -r name body; do
    [[ -n "${name}" ]] || continue
    n_classes=$((n_classes + 1))
    kind="$(field_of "${body}" kind)"
    [[ "${kind}" != "${PLANT_KIND}" ]] || continue
    grep -qxF -- "${name}" <<<"${ledgers}" || violation "${rel}: class \`${name}\` has no [ledger.${name}] table. Every expanded class carries a hand-written claim per encoding, reconciled on every seal; a class with no table is a class whose coverage nobody stated."
  done <<<"${classes}"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    grep -qE -- "^${name}"$'\t' <<<"${classes}" || violation "${rel}: [ledger.${name}] names a class that [classes] does not declare. A ledger for nothing asserts coverage of nothing; delete it or declare the class."
  done <<<"${ledgers}"
  if (( n_classes < MIN_CLASSES )); then
    broken "${rel}: parsed ${n_classes} class(es) under [classes], expected at least ${MIN_CLASSES}. The section parser has stopped matching."
  fi
}

check_allowlist() { # check_allowlist <allowlist> <proof-root>
  local file="$1" root="$2" rel="${ALLOWLIST_REL}"
  if ! jq -e 'type == "array"' "${file}" >/dev/null 2>&1; then
    broken "${rel}: not a JSON array. The scanner refuses it too (rc 2), but a guard that cannot read its subject must say so rather than pass."
    return
  fi
  local hits
  hits="$(grep -niE -- "${DEFERRAL_RE}" "${file}" || true)"
  [[ -z "${hits}" ]] || violation "${rel}: deferral vocabulary (\`$(awk 'NR == 1' <<<"${hits}")\`). An allowance that waits \"until\" something is a deferred class with better manners."

  local n i today
  n="$(jq 'length' "${file}")"
  today="$(date +%F)"
  for (( i = 0; i < n; i++ )); do
    local entry keys extra missing
    entry="$(jq -c ".[$i]" "${file}")"
    keys="$(jq -r 'keys[]' <<<"${entry}" | sort | tr '\n' ' ')"
    missing="$(comm -23 <(printf '%s\n' expires justification owner pattern proof rule scope | sort) <(jq -r 'keys[]' <<<"${entry}" | sort) | tr '\n' ' ')"
    extra="$(comm -13 <(printf '%s\n' expires justification owner pattern proof rule scope | sort) <(jq -r 'keys[]' <<<"${entry}" | sort) | tr '\n' ' ')"
    [[ -z "${missing}" ]] || violation "${rel}: entry ${i} lacks ${missing}(has: ${keys}). Every allowance says what rule, where, which line shape, why, what proves the why, who owns it and when it lapses."
    [[ -z "${extra}" ]] || violation "${rel}: entry ${i} carries unknown key(s) ${extra}— the scanner denies unknown fields, and a key nobody reads is a claim nobody checks."
    [[ -n "${missing}" ]] && continue
    jq -e '.rule | type == "string" and test("^S[0-9]+$")' <<<"${entry}" >/dev/null || violation "${rel}: entry ${i}: rule must be a structural-rule id (S<n>); a needle hit has no allowlist path."
    jq -e '.scope | type == "object" and (.sink_glob | type == "string" and length > 0) and ((keys - ["sink_glob", "tag"]) | length == 0)' <<<"${entry}" >/dev/null || violation "${rel}: entry ${i}: scope must be {sink_glob, [tag]}; an allowance with no sink is an allowance everywhere."
    jq -e '.pattern | type == "string" and length > 0' <<<"${entry}" >/dev/null || violation "${rel}: entry ${i}: pattern must be a non-empty regex over the line."
    jq -e '.justification | type == "string" and (gsub("^\\s+|\\s+$"; "") | length > 0)' <<<"${entry}" >/dev/null || violation "${rel}: entry ${i} has no justification."
    jq -e '.owner | type == "string" and (gsub("^\\s+|\\s+$"; "") | length > 0)' <<<"${entry}" >/dev/null || violation "${rel}: entry ${i} has no owner."
    local expires
    expires="$(jq -r '.expires' <<<"${entry}")"
    if [[ ! "${expires}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || [[ "$(date -d "${expires}" +%F 2>/dev/null || true)" != "${expires}" ]]; then
      violation "${rel}: entry ${i}: expires \`${expires}\` is not a real YYYY-MM-DD date."
    elif [[ "${expires}" < "${today}" ]]; then
      violation "${rel}: entry ${i} expired on ${expires}; a stale allowance cannot accumulate — renew it with a fresh proof or delete it."
    fi
    local proof path line
    proof="$(jq -r '.proof' <<<"${entry}")"
    if [[ "${proof}" =~ (^|/)\.\.(/|$) ]]; then
      violation "${rel}: entry ${i}: proof \`${proof}\` climbs out of the tree with \`..\` and proves nothing about it."
      continue
    fi
    path="${proof}"; line=""
    if [[ "${proof}" =~ ^(.+):([0-9]+)$ ]]; then path="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"; fi
    if [[ -z "${path}" || ! -f "${root}/${path}" ]]; then
      violation "${rel}: entry ${i}: proof cites \`${path}\`, which this tree does not contain."
    elif [[ -n "${line}" ]] && (( line > $(wc -l < "${root}/${path}") )); then
      violation "${rel}: entry ${i}: proof cites \`${proof}\`, but that file has fewer lines than that."
    fi
  done
}

check_all() { # check_all <policy> <allowlist> <readme> <proof-root>
  VIOLATIONS=0; BROKEN=0
  local f
  for f in "$1" "$2" "$3"; do
    [[ -f "${f}" ]] || { broken "${f} not found"; return; }
  done
  check_policy "$1" "$3"
  check_allowlist "$2" "$4"
}

# ---------------------------------------------------------------------------
# Self-test: the real files, copied and mutated, plus allowlists written from
# scratch. Every rule has a fixture in both directions; the count is pinned.
# ---------------------------------------------------------------------------
self_test() {
  local -r SELF_TEST_CASES=46
  local tmp cases=0 failures=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/base/tooling/logscan"
  cp "${REPO_ROOT}/${POLICY_REL}" "${REPO_ROOT}/${README_REL}" "${tmp}/base/tooling/logscan/"
  printf '[]\n' > "${tmp}/base/tooling/logscan/allowlist.json"
  printf 'line 1\nline 2\nline 3\n' > "${tmp}/base/Cargo.toml"

  _expect() { # _expect <desc> <root> <want-rc> [want-substring]
    local desc="$1" root="$2" want="$3" want_grep="${4:-}" out rc=0
    cases=$(( cases + 1 ))
    check_all "${root}/tooling/logscan/policy.toml" "${root}/tooling/logscan/allowlist.json" \
      "${root}/tooling/logscan/README.md" "${root}" >"${tmp}/out.txt" 2>"${tmp}/err.txt"
    out="$(cat "${tmp}/out.txt" "${tmp}/err.txt")"
    if (( BROKEN > 0 )); then rc=2; elif (( VIOLATIONS > 0 )); then rc=1; fi
    if (( rc != want )) || { [[ -n "${want_grep}" ]] && ! grep -qF -- "${want_grep}" <<<"${out}"; }; then
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d%s, got rc=%d)\n' "${desc}" "${want}" "${want_grep:+ mentioning \"${want_grep}\"}" "${rc}" >&2
      sed 's/^/        /' <<<"${out}" >&2
      failures=1
    else
      printf '  \033[1;32mPASS\033[0m %s\n' "${desc}"
    fi
  }
  mut() { # mut <dst> <file-under-tooling/logscan> <sed-expr>...
    local dst="$1" file="$2"; shift 2
    rm -rf "${dst}"; cp -r "${tmp}/base" "${dst}"
    local e; for e in "$@"; do sed -i -E "${e}" "${dst}/tooling/logscan/${file}"; done
  }
  allow() { # allow <dst> <json>
    rm -rf "$1"; cp -r "${tmp}/base" "$1"
    printf '%s\n' "$2" > "$1/tooling/logscan/allowlist.json"
  }
  local live='{"rule":"S7","scope":{"sink_glob":"*flutter-drive.log","tag":null},"pattern":"^dialing","justification":"a fixture entry","proof":"Cargo.toml:2","owner":"selftest","expires":"2099-01-01"}'

  local b="${tmp}/base" d
  _expect "the shipped policy, README and an empty allowlist pass" "${b}" 0

  # P1
  d="${tmp}/p1a"; mut "${d}" policy.toml 's|^min_term_len = 6|min_term_len = 6\ndeferred_until = "2027-01-01"|'
  _expect "(P1) a deferred_until key fails" "${d}" 1 "deferral vocabulary on a code line"
  d="${tmp}/p1b"; mut "${d}" policy.toml 's|^"hex-lower" = "secret-class raw never serialised"|"hex-lower" = "class_b, searched later"|'
  _expect "(P1) deferral vocabulary in a ledger reason fails" "${d}" 1 "deferral vocabulary on a code line"
  d="${tmp}/p1c"; mut "${d}" policy.toml 's|^schema = 1|# nothing here is deferred until anything\nschema = 1|'
  _expect "(P1) the words in a comment pass" "${d}" 0
  d="${tmp}/p1d"; allow "${d}" "[$(jq -c '.justification = "kept until the fix lands"' <<<"${live}")]"
  _expect "(P1) \"until\" in an allowlist justification fails" "${d}" 1 "deferral vocabulary"

  # P2
  d="${tmp}/p2a"; mut "${d}" policy.toml '/^drive = /s|structural_rules = true|structural_rules = false|'
  _expect "(P2) structural_rules off on an unlisted sink fails" "${d}" 1 "sink \`drive\` has structural_rules = false"
  d="${tmp}/p2b"; mut "${d}" policy.toml '/^relay = /s|structural_rules = false|structural_rules = true|'
  _expect "(P2) a listed sink switched back on is a stale list entry" "${d}" 1 "listed in STRUCTURAL_RULES_OFF"
  _expect "(P2) relay off passes (base)" "${b}" 0

  # P3
  d="${tmp}/p3a"; mut "${d}" policy.toml '/^drive = /s|declared_plants_expected = true, ||'
  _expect "(P3) a sink without declared_plants_expected fails" "${d}" 1 "carries no declared_plants_expected"
  d="${tmp}/p3b"; mut "${d}" policy.toml '/^logcat = /s|declared_plants_expected = true|declared_plants_expected = false|'
  _expect "(P3) waiving an unlisted sink fails" "${d}" 1 "is not in DECLARED_PLANTS_OFF"
  d="${tmp}/p3c"; mut "${d}" policy.toml '/^ios = /s|declared_plants_expected = false|declared_plants_expected = true|'
  _expect "(P3) a listed sink flipped to true is a stale list entry" "${d}" 1 "listed in DECLARED_PLANTS_OFF"
  d="${tmp}/p3d"; mut "${d}" README.md 's|`rust-test`, `proxy`, `diag`, `relay`|`proxy`, `diag`, `relay`|'
  _expect "(P3) a waived sink the README does not name fails" "${d}" 1 "does not name \`rust-test\`"
  d="${tmp}/p3e"; mut "${d}" README.md 's|declared_plants_expected|declared-plants-expected|g'
  _expect "(P3) a README that never mentions the knob fails" "${d}" 1 "no paragraph mentions declared_plants_expected"

  # P4
  d="${tmp}/p4a"; allow "${d}" "[${live}]"
  _expect "(P4) a live, fully-shaped entry passes" "${d}" 0
  d="${tmp}/p4b"; allow "${d}" "[$(jq -c '.expires = "2020-01-01"' <<<"${live}")]"
  _expect "(P4) an expired entry fails" "${d}" 1 "expired on 2020-01-01"
  d="${tmp}/p4c"; allow "${d}" "[$(jq -c '.expires = "2099-13-01"' <<<"${live}")]"
  _expect "(P4) an impossible date fails" "${d}" 1 "not a real YYYY-MM-DD"
  d="${tmp}/p4d"; allow "${d}" "[$(jq -c 'del(.owner)' <<<"${live}")]"
  _expect "(P4) a missing key fails" "${d}" 1 "lacks owner"
  d="${tmp}/p4e"; allow "${d}" "[$(jq -c '.deferred_until = "2027-01-01"' <<<"${live}")]"
  _expect "(P4) an unknown key fails" "${d}" 1 "unknown key(s) deferred_until"
  d="${tmp}/p4f"; allow "${d}" "[$(jq -c '.justification = "  "' <<<"${live}")]"
  _expect "(P4) a blank justification fails" "${d}" 1 "has no justification"
  d="${tmp}/p4g"; allow "${d}" "[$(jq -c '.proof = "src/nowhere.rs:12"' <<<"${live}")]"
  _expect "(P4) a dangling proof fails" "${d}" 1 "which this tree does not contain"
  d="${tmp}/p4h"; allow "${d}" "[$(jq -c '.proof = "Cargo.toml:99"' <<<"${live}")]"
  _expect "(P4) a proof past the end of its file fails" "${d}" 1 "fewer lines than that"
  d="${tmp}/p4i"; allow "${d}" "[$(jq -c '.proof = "../Cargo.toml:1"' <<<"${live}")]"
  _expect "(P4) a proof that climbs out of the tree fails" "${d}" 1 "climbs out of the tree"
  d="${tmp}/p4j"; allow "${d}" "[$(jq -c '.proof = "Cargo.toml"' <<<"${live}")]"
  _expect "(P4) a bare-file proof passes" "${d}" 0
  d="${tmp}/p4k"; allow "${d}" "[$(jq -c '.rule = "pubkey"' <<<"${live}")]"
  _expect "(P4) a needle class as the rule fails" "${d}" 1 "must be a structural-rule id"
  d="${tmp}/p4l"; allow "${d}" "[$(jq -c '.scope = {"tag": "x"}' <<<"${live}")]"
  _expect "(P4) a scope with no sink_glob fails" "${d}" 1 "scope must be"
  d="${tmp}/p4m"; allow "${d}" '{"rule": "S7"}'
  _expect "(P4) an allowlist that is not an array is BROKEN" "${d}" 2 "not a JSON array"

  # P5
  d="${tmp}/p5a"; mut "${d}" policy.toml 's|^\[ledger\.petname\]|[ledger.petname_gone]|'
  _expect "(P5) a class without its ledger table fails, and the orphan table fails" "${d}" 1 "class \`petname\` has no [ledger.petname] table"
  _expect "(P5) the orphan table is named" "${d}" 1 "[ledger.petname_gone] names a class"
  _expect "(P5) the plant class needs no ledger (base)" "${b}" 0

  # P6
  d="${tmp}/p6a"; mut "${d}" policy.toml '/^drive = /s|entry_format = "plain"|entry_format = "plain", cargo_status = "exempt"|'
  _expect "(P6) the cargo exemption on an unlisted sink fails" "${d}" 1 "sink \`drive\` has cargo_status = exempt"
  d="${tmp}/p6b"; mut "${d}" policy.toml '/^rust-test = /s|, cargo_status = "exempt"||'
  _expect "(P6) a listed sink that dropped the key is a stale list entry" "${d}" 1 "listed in CARGO_STATUS_EXEMPT"
  d="${tmp}/p6c"; mut "${d}" policy.toml '/^logcat = /s|entry_format = "logcat"|entry_format = "logcat", cargo_status = "scanned"|'
  _expect "(P6) an explicit \"scanned\" passes" "${d}" 0
  d="${tmp}/p6d"; mut "${d}" README.md 's|`cargo_status = "exempt"`|`cargo-status = exempt`|g'
  _expect "(P6) a README that never explains the knob fails" "${d}" 1 "nothing explains"
  _expect "(P6) rust-test exempt passes (base)" "${b}" 0

  # P7
  d="${tmp}/p7a"; mut "${d}" policy.toml 's|classes = \["coordinate"\]|classes = ["coordinate", "pubkey"]|'
  _expect "(P7) widening the needle exemption to a second class fails" "${d}" 1 "no longer carries the pinned needle exemption"
  d="${tmp}/p7b"; mut "${d}" policy.toml 's|emitter_scoped_out|emitter_scoped_gone|'
  _expect "(P7) a pinned sink that dropped the exemption is a stale list entry" "${d}" 1 "no longer carries the pinned needle exemption"
  d="${tmp}/p7c"; mut "${d}" policy.toml '/^drive = /s|entry_format = "plain"|entry_format = "plain", emitter_scoped_out = [{ process = "locationd", emitter = "locationd", classes = ["coordinate"] }]|'
  _expect "(P7) a second sink acquiring a needle exemption fails" "${d}" 1 "sink \`drive\` scopes a needle class out of an emitter"
  d="${tmp}/p7d"; mut "${d}" README.md 's|com\.apple\.locationd\.Position|com.apple.locationd.Elsewhere|g'
  _expect "(P7) a README that never names the scoped emitter fails" "${d}" 1 "does not name \`com.apple.locationd.Position\`"
  _expect "(P7) the shipped exemption passes (base)" "${b}" 0

  # P8
  d="${tmp}/p8a"; mut "${d}" policy.toml "/^drive = /s|, proof_of_run = '[^']*'||"
  _expect "(P8) dropping the proof-of-run line from the test-reporter sink fails" "${d}" 1 "no longer carries the pinned proof-of-run line"
  d="${tmp}/p8b"; mut "${d}" policy.toml "/^drive = /s|proof_of_run = '[^']*'|proof_of_run = 'ran'|"
  _expect "(P8) a proof-of-run line rewritten to something else fails" "${d}" 1 "no longer carries the pinned proof-of-run line"
  d="${tmp}/p8c"; mut "${d}" policy.toml "/^logcat = /s|entry_format = \"logcat\"|entry_format = \"logcat\", proof_of_run = 'x'|"
  _expect "(P8) a second sink acquiring a proof-of-run line fails" "${d}" 1 "sink \`logcat\` declares a proof_of_run"
  d="${tmp}/p8d"; mut "${d}" README.md 's|proof_of_run|proof-of-run-line|g'
  _expect "(P8) a README that never explains the key fails" "${d}" 1 "nothing explains"
  _expect "(P8) the shipped proof passes (base)" "${b}" 0

  # floors
  d="${tmp}/v1"; mut "${d}" policy.toml 's|^\[sinks\]|[sinks_renamed]|'
  _expect "floor: a [sinks] section the parser cannot find is BROKEN" "${d}" 2 "parsed 0 sink(s)"
  d="${tmp}/v2"; mut "${d}" policy.toml 's|^\[classes\]|[classes_renamed]|'
  _expect "floor: a [classes] section the parser cannot find is BROKEN" "${d}" 2 "parsed 0 class(es)"

  if (( cases != SELF_TEST_CASES )); then
    echo "self-test: ran ${cases} fixture(s), expected exactly ${SELF_TEST_CASES}; a fixture was added or removed without moving the pin" >&2
    failures=1
  fi
  if (( failures )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  echo "self-test: OK (${cases} fixtures)"
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
  fi
  if [[ $# -gt 0 ]]; then
    echo "usage: ${SELF_NAME} [--self-test]" >&2
    exit 2
  fi
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }
  log "checking ${POLICY_REL} and ${ALLOWLIST_REL}"
  check_all "${REPO_ROOT}/${POLICY_REL}" "${REPO_ROOT}/${ALLOWLIST_REL}" "${REPO_ROOT}/${README_REL}" "${REPO_ROOT}"
  if (( BROKEN > 0 )); then
    echo >&2
    echo "This guard could not read the policy the way it expects to; that is not a pass." >&2
    exit 2
  fi
  if (( VIOLATIONS > 0 )); then
    echo >&2
    echo "The scanner's policy is what \"clean\" means in every lane. See tooling/logscan/README.md" >&2
    echo "and CLAUDE.md (Log anonymity, Security Rule 15)." >&2
    exit 1
  fi
  log "OK — no deferral vocabulary, structural rules on except relay, the cargo exemption on the listed cargo-transcript sinks only and explained, the needle exemption pinned to one emitter and one class and explained, the proof-of-run line pinned to the test-reporter class and explained, plant expectations pinned and explained, allowlist entries shaped and live, every class ledgered."
}

main "$@"
