#!/usr/bin/env bash
#
# File the GitHub issue a red soak night owes — composed from an allowlist and
# NOTHING else.
#
# LINUX ONLY, bash 4+ (associative arrays): the one caller is soak-nightly.yml's
# `file-issue` job on `ubuntu-latest`, and the self-test runs in repo-guards.yml
# on the same image.
#
# ## What it reads
#
# The artifact directories the `file-issue` job downloads, one per slot:
# `<tree>/soak-core-<profile>-<slot>-<run_id>/`. The SLOT is taken from the
# directory NAME, never from a file, so a corrupt verdict cannot misattribute a
# slot. A slot's files at the TOP of the tree are refused (exit 2): that is a
# flattened download, and read as it lies every slot would be filed as
# `no-verdict`. Per slot it reads exactly one file, `verdict.log` (the rig's CI-R2
# answer, tooling/soak/src/verdict.rs), one member at a time BY NAME — never a
# walk over the object's values, because an allowlist is only an allowlist if
# the reader names its members. Nothing else in the tree is opened: not the
# timeline, not the banner, not a snapshot, not the containment note.
#
# And the run's job listing, `--jobs-json`: the raw response of
# `GET /repos/<r>/actions/runs/<id>/jobs?filter=latest&per_page=100`, saved by
# the caller and parsed HERE, because a slot is red by its JOB as well as by its
# verdict. A slot whose job `Soak Core (<profile>, <slot>) /
# e2e_soak_core_<profile>` is absent, or did not conclude `success`, is red. A
# listing that fills its page is refused (exit 2): the slot's job may be on the
# next page, and reading it as absent would file a green slot. Only a job's
# `name` and `conclusion` are read.
#
# ## The allowlist is the control; the scan is a BACKSTOP
#
# Two key sets, named separately (PLAN_PHASE2 decision 0.42): VERDICT_KEYS is
# what the file may carry — a key outside it refuses the whole run rather than
# being dropped, because a silently dropped key is indistinguishable from a
# field set that rotted — and BODY_FIELDS is what an issue body may carry, each
# with one source and one shape (PLAN_PHASE2 §1.14). Every value is validated
# against its shape BEFORE it is used; one value that fails refuses the WHOLE
# run: exit 2 and nothing is filed, for any slot. An undeclared value must
# never reach a public issue, and Rule 15 does not trade that for filing the
# other slots.
#
# The composed title and body are then run through
# `tooling/e2e/ci/scan-logs.sh --rules-only --sink diag=…` before any `gh` call.
# That scan is a BACKSTOP, not the control: a scanner cannot catch an
# undeclared value — a display name, a petname, a relay host nobody declared —
# because nothing declared it. It catches a structural shape (a long hex run,
# an endpoint, an address, a coordinate). The allowlist is the control.
#
# ## Filing is opt-in: `--file`
#
# Without `--file` the script composes, validates and backstop-scans exactly as
# it would before filing, writes each body to `--out`, and makes NO `gh` call of
# any kind — not even the dedup listing. soak-nightly.yml passes `--file` only
# when `github.event_name == 'schedule'` (PLAN_PHASE2 OQ-H), so a
# `workflow_dispatch` repro proves the whole contract and files nothing. The
# body goes to a FILE and never to stdout: the job log is public, and the file
# is the same bytes the backstop scanned and `gh` would have been handed.
#
# ## Keys, titles, dedup
#
# A red slot's KEY is its invariant id (rc 1), else its finding class, else a
# synthetic literal — `violation-or-leak` (rc 1 with neither), `rig-broken`
# (rc 2), `no-faults-fired` (rc 3), `ungraded` (rc 4), `leak-contained` (the
# runner contained the tree), `no-verdict` (no directory, or no `verdict.log`
# in it), `lane-red` (the rig's verdict is rc 0 but the slot's JOB is red —
# `--jobs-json` — because the lane's own scan or a later step reddened it; the
# verdict is the rig's rc, never the lane's). Every key is either an
# allowlisted field or a literal of this file.
# The title is `soak(<profile>): <key>`: the seed is NOT in it — it rotates
# nightly, so a seed-keyed title would file the same defect fourteen times.
# One issue per KEY, not per run: four slots on one invariant are one issue
# with four slot blocks; two invariants are two issues.
#
# Dedup is one listing of the open issues labelled BOTH `soak` and `soak:core`,
# matched on the exact title here (`gh issue list --search` is fuzzy): zero
# matches create, one comments the same body, two or more is a broken dedup
# (exit 2, never a third issue), and a listing that fills the page is not a
# dedup either (exit 2). Issues are labelled and never assigned
# (PLAN_PHASE2 OQ-N). The two labels must exist in the repository: `gh` refuses
# to create an issue carrying a label it cannot resolve.
#
# ## `--assert-no-artifacts`: may a failed download be read as an empty tree?
#
# `gh run download` exits 1 when no artifact matched — the commonest cause is a
# night whose every build failed — and also when a download broke. The caller
# hands the run's artifact listing (`GET .../runs/<id>/artifacts?per_page=100`)
# to this mode, which answers 0 only when no unexpired
# `soak-core-<profile>-*-<run_id>` artifact exists; a match, a full page or a
# malformed listing is exit 2, and nothing is composed from a partial tree. It
# lives here rather than in a script of its own because the artifact name it
# matches is compose_slot's, and one self-test keeps the two from drifting.
#
# Usage:
#   file_soak_issue.sh --profile <pr|nightly|weekly> --tree <dir> --out <dir> \
#                      --slots <s1> [<s2> ...] --jobs-json <file> [--file]
#   file_soak_issue.sh --assert-no-artifacts <listing.json> --profile <pr|nightly|weekly>
#   file_soak_issue.sh --self-test
#
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT —
#   the run being reported, as every Actions step already has them.
#
# Exit codes:
#   0  nothing red, or every body composed (and, with --file, filed)
#   2  REFUSED or broken: a value off its shape, an unknown verdict key, a
#      flattened tree, a job or artifact listing that is malformed or fills its
#      page, a slot artifact behind a failed download, the backstop scan not
#      clean, a broken dedup, a `gh` failure, a usage error.
#      Never 1: a filed issue is not a CI failure — the slot that failed has
#      already reddened the run.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCAN_LOGS="${REPO_ROOT}/tooling/e2e/ci/scan-logs.sh"

# tooling/soak/src/verdict.rs `VERDICT_KEYS`, re-typed on purpose: this is the
# reader's copy, and the fixtures pin both it and the body by equality.
readonly VERDICT_KEYS=(profile seed schedule_tag commit rustc rc rc_name scenario arm
  invariant tick bound_secs observed_secs finding_class handles)
# PLAN_PHASE2 §1.14's table. Nineteen rendered keys from its rows: `rc` renders
# the code and its name as one key, and `bound_secs`/`observed_secs` are two.
readonly BODY_FIELDS=(profile slot run_url run_attempt commit toolchain seed schedule_tag
  rc scenario arm invariant tick bound_secs observed_secs handles finding_class repro
  artifact)
readonly LABELS=(soak soak:core)
readonly LIST_LIMIT=100
# The REST page the caller asks for (`per_page=100`, the API's maximum).
readonly API_PAGE=100
readonly VERDICT_LOG='verdict.log'
# run-soak-core.sh's SOAK_CONTAINED_LOG: its PRESENCE is the fact; it is never read.
readonly CONTAINED_LOG='soak-contained.log'

readonly RE_PROFILE='^(pr|nightly|weekly)$'
readonly RE_SLOT='^s[1-4]$'
readonly RE_RUN_ID='^[1-9][0-9]{0,19}$'
readonly RE_ATTEMPT='^[1-9][0-9]{0,2}$'
readonly RE_SERVER='^https://github[.]com$'
readonly RE_REPO='^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'
readonly RE_COMMIT='^([0-9a-fA-F]{1,12}|unknown)$'
readonly RE_TOOLCHAIN='^([0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}(-(beta|nightly)([.][0-9]{1,3})?)?|unknown)$'
readonly RE_SEED='^0x[0-9a-f]{16}$'
readonly RE_TAG='^[0-9a-f]{8}$'
readonly RE_SCENARIO='^(S[0-9]{2}|nemesis)$'
readonly RE_ARM='^[a-z0-9]{1,24}(-[a-z0-9]{1,24}){0,7}$'
# PLAN_PHASE2's `^INV-[A-Z0-9-]+$`, bounded: unbounded, it also spells a 64-hex
# event id in upper case — the class of value this one free-form field exists
# to keep out (verdict.rs `is_invariant_id` says the same of its closed set).
readonly RE_INVARIANT='^INV-[A-Z0-9-]{1,16}$'
# Nine digits at most: a tick, a bound and an observation are relative, and a
# ten-digit value in any of them is the shape of an absolute Unix instant.
readonly RE_UINT='^(0|[1-9][0-9]{0,8})$'
readonly RE_HANDLE='^sim(dev|circle|relay|evt)#[0-9a-f]{1,8}$'
readonly RE_CLASS='^[a-z]{1,24}(-[a-z]{1,24}){0,5}$'
readonly RE_KEY_NAME='^[a-z_]{1,32}$'
readonly RE_ISSUE='^[1-9][0-9]{0,9}$'

# rc.rs's closed map from code to name.
readonly RC_NAMES=(clean violation-or-leak rig unusable meta)

PROFILE='' TREE='' OUT='' FILE_MODE=0
SLOTS=()
declare -A RED=()
RUN_ID='' RUN_ATTEMPT='' RUN_URL=''
# key -> the slot blocks filed under it, in slot order; KEY_ORDER is first-seen.
declare -A BLOCKS=()
KEY_ORDER=()

say() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*"; }

# Every refusal names a slot (a validated literal) and a FIELD NAME, never a
# value: the value is exactly what failed to be one the allowlist declares.
refuse() { # refuse <what>
  printf '%s: REFUSED — %s; nothing was filed\n' "${SCRIPT_NAME}" "$1" >&2
  exit 2
}

usage() {
  echo "usage: ${SCRIPT_NAME} --profile <pr|nightly|weekly> --tree <dir> --out <dir> --slots <s1> [<s2> ...] --jobs-json <file> [--file] | --assert-no-artifacts <listing.json> --profile <pr|nightly|weekly> | --self-test" >&2
  exit 2
}

# The JSON encoding of one member, read by name; empty when absent.
member() { # member <file> <key>
  jq -c --arg k "$2" 'if has($k) then .[$k] else empty end' "$1"
}

# A string member, validated against <re>. Sets VALUE; an absent member leaves
# it empty and answers 1. The shapes admit no quote and no backslash, so the
# JSON encoding of a conforming string is exactly `"<value>"` — an escape of
# any kind cannot pass.
string_member() { # string_member <file> <key> <re> <slot>
  local json
  json="$(member "$1" "$2")"
  VALUE=''
  [[ -n "${json}" ]] || return 1
  [[ "${json}" == \"*\" && "${json:1:${#json}-2}" =~ $3 ]] \
    || refuse "slot $4: verdict.log field '$2' is not the shape the allowlist declares"
  VALUE="${json:1:${#json}-2}"
}

uint_member() { # uint_member <file> <key> <slot>
  local json
  json="$(member "$1" "$2")"
  VALUE=''
  [[ -n "${json}" ]] || return 1
  [[ "${json}" =~ ${RE_UINT} ]] \
    || refuse "slot $3: verdict.log field '$2' is not a relative integer of at most nine digits"
  VALUE="${json}"
}

add_block() { # add_block <key> <line>...
  local key="$1" block
  shift
  block="$(printf '%s\n' "$@")"
  if [[ -z "${BLOCKS[${key}]+x}" ]]; then
    KEY_ORDER+=("${key}")
    BLOCKS[${key}]="${block}"
  else
    BLOCKS[${key}]+=$'\n\n'"${block}"
  fi
}

compose_slot() { # compose_slot <slot>
  local slot="$1" artifact dir file json
  artifact="soak-core-${PROFILE}-${slot}-${RUN_ID}"
  dir="${TREE}/${artifact}"
  file="${dir}/${VERDICT_LOG}"
  local -a head=("profile: ${PROFILE}" "slot: ${slot}" "run_url: ${RUN_URL}"
    "run_attempt: ${RUN_ATTEMPT}")

  # Contained first: the runner deleted everything else, and nothing it left
  # — the note included — is a field.
  if [[ -e "${dir}/${CONTAINED_LOG}" ]]; then
    add_block leak-contained "${head[@]}" "artifact: ${artifact}"
    return
  fi
  # No directory is the COMMONEST no-verdict (a build failure skips the soak
  # step, and the upload is gated on it), not only an empty one.
  if [[ ! -f "${file}" ]]; then
    add_block no-verdict "${head[@]}" "artifact: ${artifact}"
    return
  fi

  [[ "$(jq -s 'length' "${file}" 2>/dev/null)" == 1 && "$(jq -r 'type' "${file}")" == object ]] \
    || refuse "slot ${slot}: verdict.log is not exactly one JSON object"
  local allowed unknown
  allowed="$(printf '%s\n' "${VERDICT_KEYS[@]}" | jq -R . | jq -sc .)"
  unknown="$(jq -c --argjson a "${allowed}" '(keys_unsorted - $a) | if length == 0 then empty else .[0] end' "${file}")"
  if [[ -n "${unknown}" ]]; then
    local named='an unprintable key' bare="${unknown:1:${#unknown}-2}"
    [[ "${unknown}" == \"*\" && "${bare}" =~ ${RE_KEY_NAME} ]] && named="the key '${bare}'"
    refuse "slot ${slot}: verdict.log carries ${named}, which VERDICT_KEYS does not declare"
  fi

  local profile seed tag commit rustc rc rc_name
  string_member "${file}" profile "${RE_PROFILE}" "${slot}" || refuse "slot ${slot}: verdict.log has no 'profile'"
  profile="${VALUE}"
  [[ "${profile}" == "${PROFILE}" ]] || refuse "slot ${slot}: verdict.log names a different profile than --profile"
  string_member "${file}" seed "${RE_SEED}" "${slot}" || refuse "slot ${slot}: verdict.log has no 'seed'"
  seed="${VALUE}"
  string_member "${file}" schedule_tag "${RE_TAG}" "${slot}" || refuse "slot ${slot}: verdict.log has no 'schedule_tag'"
  tag="${VALUE}"
  string_member "${file}" commit "${RE_COMMIT}" "${slot}" || refuse "slot ${slot}: verdict.log has no 'commit'"
  commit="${VALUE}"
  string_member "${file}" rustc "${RE_TOOLCHAIN}" "${slot}" || refuse "slot ${slot}: verdict.log has no 'rustc'"
  rustc="${VALUE}"
  json="$(member "${file}" rc)"
  [[ "${json}" =~ ^[0-4]$ ]] || refuse "slot ${slot}: verdict.log field 'rc' is not a code of the rc taxonomy"
  rc="${json}"
  string_member "${file}" rc_name '^[a-z-]{1,24}$' "${slot}" || refuse "slot ${slot}: verdict.log has no 'rc_name'"
  rc_name="${VALUE}"
  [[ "${rc_name}" == "${RC_NAMES[${rc}]}" ]] || refuse "slot ${slot}: verdict.log field 'rc_name' is not the name of its 'rc'"

  # The violation half, validated whole whether or not the slot is red: a
  # field the file carries is a field the reader vouches for or refuses.
  local scenario='' arm='' invariant='' tick='' bound='' observed='' class='' handles=''
  local has_violation=0
  if string_member "${file}" scenario "${RE_SCENARIO}" "${slot}"; then
    scenario="${VALUE}"
    has_violation=1
  fi
  string_member "${file}" arm "${RE_ARM}" "${slot}" && arm="${VALUE}"
  string_member "${file}" invariant "${RE_INVARIANT}" "${slot}" && invariant="${VALUE}"
  uint_member "${file}" tick "${slot}" && tick="${VALUE}"
  uint_member "${file}" bound_secs "${slot}" && bound="${VALUE}"
  uint_member "${file}" observed_secs "${slot}" && observed="${VALUE}"
  string_member "${file}" finding_class "${RE_CLASS}" "${slot}" && class="${VALUE}"
  json="$(member "${file}" handles)"
  if [[ -n "${json}" ]]; then
    [[ "$(jq -r '.handles | type' "${file}")" == array ]] \
      || refuse "slot ${slot}: verdict.log field 'handles' is not a list"
    local handle
    local -a list=()
    # The one walk in this file, over a member it named: the list's ELEMENTS,
    # each validated before it is kept.
    while IFS= read -r handle; do
      [[ "${handle}" == \"*\" && "${handle:1:${#handle}-2}" =~ ${RE_HANDLE} ]] \
        || refuse "slot ${slot}: a verdict.log 'handles' element is not one of the rig's own handles"
      list+=("${handle:1:${#handle}-2}")
    done < <(jq -c '.handles[]' "${file}")
    handles="${list[*]:-}"
  fi
  if (( has_violation )); then
    [[ -n "${arm}" && -n "${tick}" && -n "${bound}" && -n "${observed}" && -n "${class}" && -n "${json}" ]] \
      || refuse "slot ${slot}: verdict.log carries a partial violation"
  else
    [[ -z "${arm}${invariant}${tick}${bound}${observed}${class}${json}" ]] \
      || refuse "slot ${slot}: verdict.log carries violation fields without a scenario"
  fi

  if (( rc == 0 )); then
    # The lane reddened a slot its rig called clean: its scan, or a step after
    # the drive. Nothing in the verdict explains it, so nothing of it is carried.
    [[ -z "${RED[${slot}]+x}" ]] || add_block lane-red "${head[@]}" "artifact: ${artifact}"
    return 0
  fi

  local key
  case "${rc}" in
    1) key="${invariant:-${class:-violation-or-leak}}" ;;
    2) key=rig-broken ;;
    3) key=no-faults-fired ;;
    4) key=ungraded ;;
  esac
  local -a lines=("${head[@]}" "commit: ${commit}" "toolchain: ${rustc}" "seed: ${seed}"
    "schedule_tag: ${tag}" "rc: ${rc} ${rc_name}")
  if (( has_violation )); then
    lines+=("scenario: ${scenario}" "arm: ${arm}" "invariant: ${invariant:--}"
      "tick: ${tick}" "bound_secs: ${bound}" "observed_secs: ${observed}"
      "handles: ${handles:--}" "finding_class: ${class}")
  fi
  lines+=("repro: scripts/run_soak_local.sh core --profile ${PROFILE} --seed ${seed} --count 3"
    "artifact: ${artifact}")
  add_block "${key}" "${lines[@]}"
}

# One REST listing page, validated before a member is read: exactly one JSON
# object whose `total_count` is a count and whose <member> is a list of objects
# each carrying the string <field>. Sets TOTAL. A page the listing fills is a
# refusal: what it did not return may be exactly the entry being looked for.
listing_page() { # listing_page <file> <member> <field> <what>
  [[ -f "$1" ]] || refuse "$4 is not a file"
  TOTAL="$(jq -s --arg m "$2" --arg f "$3" '
      if length == 1 and (.[0] | type == "object" and (.total_count | type) == "number"
          and (.[$m] | type) == "array" and all(.[$m][]; type == "object" and (.[$f] | type) == "string"))
      then .[0].total_count else error end' "$1" 2>/dev/null)" \
    && [[ "${TOTAL}" =~ ${RE_UINT} ]] || refuse "$4 is not one page of the API's listing"
  (( TOTAL < API_PAGE )) || refuse "$4 filled its page of ${API_PAGE}, so what it did not return cannot be read as absent"
}

# RED from the run's job listing: a slot is red unless its job exists and every
# row of it concluded success.
read_red_slots() { # read_red_slots <jobs.json>
  local slots_json red_out slot
  listing_page "$1" jobs name "the --jobs-json job listing"
  slots_json="$(printf '%s\n' "${SLOTS[@]}" | jq -R . | jq -sc .)"
  red_out="$(jq -r --arg p "${PROFILE}" --argjson slots "${slots_json}" '
      .jobs as $jobs | $slots[] | . as $s
      | [$jobs[] | select(.name == "Soak Core (\($p), \($s)) / e2e_soak_core_\($p)")] as $m
      | select(($m | length) == 0 or any($m[]; .conclusion != "success")) | $s' "$1")"
  while IFS= read -r slot; do
    [[ -z "${slot}" ]] || RED[${slot}]=1
  done <<<"${red_out}"
}

assert_no_artifacts() { # assert_no_artifacts <listing.json>
  local matched
  listing_page "$1" artifacts name "the artifact listing"
  matched="$(jq --arg re "^soak-core-${PROFILE}-.*-${RUN_ID}\$" \
    '[.artifacts[] | select(.expired == false and (.name | test($re)))] | length' "$1")"
  [[ "${matched}" == 0 ]] || refuse "the download failed although slot artifacts exist; nothing is composed from a partial tree"
  say "no slot uploaded an artifact: every slot is filed as no-verdict"
}

# The composed files, and the backstop over exactly those bytes.
write_and_scan() { # write_and_scan <key>
  local key="$1" title body scanned
  title="${OUT}/${key}.title.log"
  body="${OUT}/${key}.body.log"
  scanned="${OUT}/${key}.backstop.log"
  printf 'soak(%s): %s\n' "${PROFILE}" "${key}" >"${title}"
  { printf '```\n'; printf '%s\n' "${BLOCKS[${key}]}"; printf '```\n'; } >"${body}"
  if ! bash "${SCAN_LOGS}" --rules-only --sink "diag=${title},${body}" >"${scanned}" 2>&1; then
    rm -f -- "${title}" "${body}"
    refuse "the backstop scan of the '${key}' body was not clean"
  fi
}

file_all() {
  local open="${OUT}/open-issues.json" gh_err="${OUT}/gh.err.log" rows key title n
  gh issue list --label "${LABELS[0]}" --label "${LABELS[1]}" --state open \
    --limit "${LIST_LIMIT}" --json number,title >"${open}" 2>"${gh_err}" \
    || refuse "the open-issue listing failed"
  rows="$(jq 'if type == "array" then length else error end' "${open}" 2>/dev/null)" \
    || refuse "the open-issue listing is not a list"
  (( rows < LIST_LIMIT )) || refuse "the open-issue listing filled its page, which is not a dedup"
  for key in "${KEY_ORDER[@]}"; do
    title="soak(${PROFILE}): ${key}"
    local -a matches=()
    mapfile -t matches < <(jq -r --arg t "${title}" 'map(select(.title == $t)) | .[].number' "${open}")
    case "${#matches[@]}" in
      0)
        gh issue create --title "${title}" --body-file "${OUT}/${key}.body.log" \
          --label "${LABELS[0]}" --label "${LABELS[1]}" >"${OUT}/${key}.filed.log" 2>>"${gh_err}" \
          || refuse "creating the '${key}' issue failed (do the labels ${LABELS[*]} exist?)"
        say "${key}: filed as a new issue"
        ;;
      1)
        n="${matches[0]}"
        [[ "${n}" =~ ${RE_ISSUE} ]] || refuse "the open-issue listing returned a malformed number"
        gh issue comment "${n}" --body-file "${OUT}/${key}.body.log" \
          >"${OUT}/${key}.filed.log" 2>>"${gh_err}" \
          || refuse "commenting on the open '${key}' issue failed"
        say "${key}: commented on the open issue"
        ;;
      *) refuse "more than one open issue carries the '${key}' title — a broken dedup, never a third issue" ;;
    esac
  done
}

main() {
  local jobs_json=''
  [[ $# -gt 0 ]] || usage
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) [[ $# -ge 2 ]] || usage; PROFILE="$2"; shift 2 ;;
      --tree) [[ $# -ge 2 ]] || usage; TREE="$2"; shift 2 ;;
      --out) [[ $# -ge 2 ]] || usage; OUT="$2"; shift 2 ;;
      --file) FILE_MODE=1; shift ;;
      --jobs-json) [[ $# -ge 2 ]] || usage; jobs_json="$2"; shift 2 ;;
      --slots)
        shift
        while [[ $# -gt 0 && "$1" != --* ]]; do SLOTS+=("$1"); shift; done
        ;;
      *) usage ;;
    esac
  done
  [[ "${PROFILE}" =~ ${RE_PROFILE} ]] || refuse "--profile is not pr, nightly or weekly"
  [[ -n "${TREE}" && -n "${OUT}" && -n "${jobs_json}" ]] || usage
  (( ${#SLOTS[@]} >= 1 && ${#SLOTS[@]} <= 4 )) || refuse "--slots takes one to four slots"
  local slot seen=' '
  for slot in "${SLOTS[@]}"; do
    [[ "${slot}" =~ ${RE_SLOT} ]] || refuse "--slots takes s1..s4"
    [[ "${seen}" != *" ${slot} "* ]] || refuse "--slots names a slot twice"
    seen+="${slot} "
  done
  local server="${GITHUB_SERVER_URL:-}" repo="${GITHUB_REPOSITORY:-}"
  RUN_ID="${GITHUB_RUN_ID:-}"
  RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
  [[ "${server}" =~ ${RE_SERVER} ]] || refuse "GITHUB_SERVER_URL is not https://github.com"
  [[ "${repo}" =~ ${RE_REPO} ]] || refuse "GITHUB_REPOSITORY is not an owner/name pair"
  [[ "${RUN_ID}" =~ ${RE_RUN_ID} ]] || refuse "GITHUB_RUN_ID is not a run id"
  [[ "${RUN_ATTEMPT}" =~ ${RE_ATTEMPT} ]] || refuse "GITHUB_RUN_ATTEMPT is not an attempt number"
  RUN_URL="${server}/${repo}/actions/runs/${RUN_ID}"
  read_red_slots "${jobs_json}"

  # An emptied or fresh directory only: a body left by an earlier invocation
  # would be filed as this run's.
  mkdir -p "${OUT}"
  [[ -z "$(find "${OUT}" -mindepth 1 -print -quit)" ]] || refuse "--out is not empty"
  [[ ! -e "${TREE}/${VERDICT_LOG}" && ! -e "${TREE}/${CONTAINED_LOG}" ]] \
    || refuse "--tree holds a slot's files at its top level, a flattened download; every slot would read as no-verdict"

  for slot in "${SLOTS[@]}"; do compose_slot "${slot}"; done
  if (( ${#KEY_ORDER[@]} == 0 )); then
    say "every slot is green; nothing to file"
    return 0
  fi
  local key
  for key in "${KEY_ORDER[@]}"; do write_and_scan "${key}"; done
  if (( ! FILE_MODE )); then
    for key in "${KEY_ORDER[@]}"; do say "${key}: composed and scanned, not filed (no --file)"; done
    return 0
  fi
  file_all
}

# ---------------------------------------------------------------------------
# --self-test — hermetic. `gh` and `haven-logscan` are stubs on PATH / in
# HAVEN_LOGSCAN_BIN; the key-material floor and scan-logs.sh are the real ones.
# ---------------------------------------------------------------------------

# Pinned by equality against the fixtures that actually ran: a fixture that
# stops running is the one way a deleted fixture reports success.
readonly SELF_TEST_FIXTURES=98

self_test() {
  local tmp n=0 fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _ok() { # _ok <0|1> <label>
    n=$((n + 1))
    if [[ "$1" == 0 ]]; then
      printf '  PASS %s\n' "$2"
    else
      printf '  FAIL %s\n' "$2" >&2
      fails=1
    fi
  }
  _t() { if "$@"; then echo 0; else echo 1; fi; }

  local bin="${tmp}/bin"
  mkdir -p "${bin}"
  # The `gh` stub is STATEFUL: a create appends to the open-issue list the next
  # listing serves, so "a second night with the same key comments" is driven,
  # not asserted. Output shapes measured 2026-09-27 against this repository:
  # `gh issue list --json number,title` prints one JSON array (and `[]` for a
  # label that does not exist yet, rc 0).
  cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_GH_CALLS}"
case "$1 $2" in
  "issue list")
    [[ -z "${STUB_GH_LIST_FILE:-}" ]] || { jq -c . "${STUB_GH_LIST_FILE}"; exit 0; }
    jq -c . "${STUB_GH_OPEN}"
    ;;
  "issue create")
    [[ -z "${STUB_GH_CREATE_FAIL:-}" ]] || { echo "could not add label: 'soak' not found" >&2; exit 1; }
    title="" body=""
    while (($#)); do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body-file) body="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    number=$(( $(jq 'length' "${STUB_GH_OPEN}") + 1 ))
    cp "${body}" "${STUB_GH_BODIES}/create-${number}"
    jq -c --arg t "${title}" --argjson n "${number}" '. + [{"number": $n, "title": $t}]' \
      "${STUB_GH_OPEN}" >"${STUB_GH_OPEN}.next"
    mv "${STUB_GH_OPEN}.next" "${STUB_GH_OPEN}"
    echo "https://github.com/o/r/issues/${number}"
    ;;
  "issue comment")
    body="" number="$3"
    while (($#)); do
      case "$1" in
        --body-file) body="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cp "${body}" "${STUB_GH_BODIES}/comment-${number}"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  # The scanner stub records its argv and the bytes of every sink it was
  # handed, and answers STUB_SCAN_RC. What it models is scan-logs.sh's contract
  # with the binary; that the real binary finds a planted endpoint or hex run is
  # tooling/logscan's own suite's claim, and the file-issue job runs the real
  # one.
  cat >"${bin}/haven-logscan" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_SCAN_CALLS}"
for a in "$@"; do
  case "${a}" in
    diag=*)
      IFS=, read -r -a sinks <<<"${a#diag=}"
      for s in "${sinks[@]}"; do cat -- "${s}" >>"${STUB_SCAN_SEEN}"; done
      ;;
  esac
done
exit "${STUB_SCAN_RC:-0}"
STUB
  chmod +x "${bin}/gh" "${bin}/haven-logscan"

  local run_id=4242
  local good='{"profile":"nightly","seed":"0x5eed5eed5eed5eed","schedule_tag":"a1b2c3d4","commit":"269b46c1a2b3","rustc":"1.98.0","rc":1,"rc_name":"violation-or-leak","scenario":"S01","arm":"single-relay-outage","invariant":"INV-O1","tick":41,"bound_secs":145,"observed_secs":190,"finding_class":"probe-not-delivered","handles":["simdev#0","simdev#1","simcircle#2"]}'
  local clean='{"profile":"nightly","seed":"0x000000000000002a","schedule_tag":"0badc0de","commit":"unknown","rustc":"unknown","rc":0,"rc_name":"clean"}'

  local tree out calls bodies open scan_calls scan_seen stdout stderr rc
  _reset() {
    tree="${tmp}/tree"; out="${tmp}/out"
    calls="${tmp}/gh.calls"; bodies="${tmp}/bodies"; open="${tmp}/open.json"
    scan_calls="${tmp}/scan.calls"; scan_seen="${tmp}/scan.seen"
    stdout="${tmp}/stdout"; stderr="${tmp}/stderr"
    rm -rf "${tree}" "${out}" "${bodies}"
    mkdir -p "${tree}" "${bodies}"
    : >"${calls}"; : >"${scan_calls}"; : >"${scan_seen}"
    printf '[]\n' >"${open}"
  }
  _slot() { # _slot <slot> <verdict-json> — a slot directory holding a verdict
    mkdir -p "${tree}/soak-core-nightly-$1-${run_id}"
    printf '%s\n' "$2" >"${tree}/soak-core-nightly-$1-${run_id}/${VERDICT_LOG}"
  }
  _mut() { jq -c "$1" <<<"${good}"; }
  # A job listing in the shape `gh api .../runs/<id>/jobs?filter=latest` answered
  # for Soak Nightly run 36375782567: per slot the called job plus its two
  # skipped siblings, `prepare`, and this job itself still running. Each
  # argument is <slot>=<conclusion>; a slot not named is absent.
  _jobs() { # _jobs <file> [<slot>=<conclusion> ...]
    local out="$1" pair
    shift
    {
      printf '{"id":1,"name":"Derive the slot seeds","status":"completed","conclusion":"success","runner_name":"GitHub Actions 1000000001"}\n'
      for pair in "$@"; do
        printf '{"id":2,"name":"Soak Core (nightly, %s) / e2e_soak_core_nightly","status":"completed","conclusion":"%s","runner_name":"GitHub Actions 1000000002"}\n' "${pair%%=*}" "${pair#*=}"
        printf '{"id":3,"name":"Soak Core (nightly, %s) / e2e_soak_core_pr","status":"completed","conclusion":"skipped"}\n' "${pair%%=*}"
        printf '{"id":4,"name":"Soak Core (nightly, %s) / e2e_soak_core_weekly","status":"completed","conclusion":"skipped"}\n' "${pair%%=*}"
      done
      printf '{"id":5,"name":"File the night'"'"'s soak issue","status":"in_progress","conclusion":null}\n'
    } | jq -sc '{total_count: length, jobs: .}' >"${out}"
  }
  _run() { # _run [--file] [--red <csv> | --jobs <file>] [NAME=VALUE ...] -- <slot>...
    local file_flag=() kv jobs="${tmp}/jobs.json" red='' pair
    local -a envs=() pairs=()
    while [[ $# -gt 0 && "$1" != -- ]]; do
      case "$1" in
        --file) file_flag=(--file) ;;
        --red) red="$2"; shift ;;
        --jobs) jobs="$2"; shift ;;
        *) envs+=("$1") ;;
      esac
      shift
    done
    shift
    if [[ "${jobs}" == "${tmp}/jobs.json" ]]; then
      for pair in s1 s2 s3 s4; do
        if [[ ",${red}," == *",${pair},"* ]]; then pairs+=("${pair}=failure"); else pairs+=("${pair}=success"); fi
      done
      _jobs "${jobs}" "${pairs[@]}"
    fi
    rc=0
    ( export PATH="${bin}:${PATH}" HAVEN_LOGSCAN_BIN="${bin}/haven-logscan" \
             STUB_GH_CALLS="${calls}" STUB_GH_BODIES="${bodies}" STUB_GH_OPEN="${open}" \
             STUB_SCAN_CALLS="${scan_calls}" STUB_SCAN_SEEN="${scan_seen}" \
             GITHUB_SERVER_URL='https://github.com' GITHUB_REPOSITORY='mehmetefeumit/Haven-App' \
             GITHUB_RUN_ID="${run_id}" GITHUB_RUN_ATTEMPT=1
      for kv in "${envs[@]+"${envs[@]}"}"; do export "${kv?}"; done
      main --profile nightly --tree "${tree}" --out "${out}" --slots "$@" \
        --jobs-json "${jobs}" "${file_flag[@]+"${file_flag[@]}"}"
    ) >"${stdout}" 2>"${stderr}" || rc=$?
  }
  _no_gh() { [[ ! -s "${calls}" ]]; }
  _creates() { grep -c '^issue create' "${calls}" || true; }
  _comments() { grep -c '^issue comment' "${calls}" || true; }
  # The rendered key set of every `key: value` line, and nothing else may be
  # in the body but the fence and blank separators.
  _body_keys() { # _body_keys <body-file>
    grep -vxF -e '```' -e '' "$1" | sed -E 's/^([a-z_]+): .*$/\1/' | sort -u
  }
  _field_set_is() { # _field_set_is <body-file> <field>...
    local body="$1" want got lines
    shift
    lines="$(grep -vxF -e '```' -e '' "${body}" || true)"
    ! grep -qvE '^[a-z_]+: ' <<<"${lines}" || return 1
    want="$(printf '%s\n' "$@" | sort -u)"
    got="$(_body_keys "${body}")"
    [[ "${want}" == "${got}" ]]
  }
  # A refusal: rc 2, no gh call of any kind, and no body left in --out.
  _refuses() { # _refuses <label> [--file] <verdict-json>
    local label="$1" file_flag=()
    shift
    [[ "$1" != --file ]] || { file_flag=(--file); shift; }
    _reset
    _slot s1 "$1"
    _run "${file_flag[@]+"${file_flag[@]}"}" -- s1
    _ok "$([[ "${rc}" == 2 ]] && _no_gh && [[ -z "$(find "${out}" -name '*.body.log' 2>/dev/null)" ]] && echo 0 || echo 1)" "${label}"
  }

  printf -- '--- the allowlist: every field, from its one source ---\n'
  _reset
  _slot s1 "${good}"
  _run -- s1
  local body="${out}/INV-O1.body.log"
  _ok "$([[ "${rc}" == 0 ]] && echo 0 || echo 1)" '(A1) a violation composes, rc 0'
  local golden="${tmp}/golden"
  cat >"${golden}" <<'EOF'
```
profile: nightly
slot: s1
run_url: https://github.com/mehmetefeumit/Haven-App/actions/runs/4242
run_attempt: 1
commit: 269b46c1a2b3
toolchain: 1.98.0
seed: 0x5eed5eed5eed5eed
schedule_tag: a1b2c3d4
rc: 1 violation-or-leak
scenario: S01
arm: single-relay-outage
invariant: INV-O1
tick: 41
bound_secs: 145
observed_secs: 190
handles: simdev#0 simdev#1 simcircle#2
finding_class: probe-not-delivered
repro: scripts/run_soak_local.sh core --profile nightly --seed 0x5eed5eed5eed5eed --count 3
artifact: soak-core-nightly-s1-4242
```
EOF
  _ok "$(_t cmp -s "${golden}" "${body}")" \
    '(A2) the body is byte-for-byte the nineteen fields, each from its source (slot from the directory name, run_url/run_attempt from the run, the rest from verdict.log, repro composed)'
  _ok "$(_t _field_set_is "${body}" "${BODY_FIELDS[@]}")" '(A3) the body field set EQUALS BODY_FIELDS'
  _ok "$([[ "${#BODY_FIELDS[@]}" == 19 && "${#VERDICT_KEYS[@]}" == 15 ]] && echo 0 || echo 1)" \
    '(A4) BODY_FIELDS is nineteen and VERDICT_KEYS is verdict.rs'"'"'s fifteen'
  local extra="${tmp}/extra" missing="${tmp}/missing"
  sed '$i peer_npub: x' "${body}" >"${extra}"
  _ok "$(_t eval '! _field_set_is "${extra}" "${BODY_FIELDS[@]}"')" '(A5) an extra key FAILS the equality'
  grep -v '^tick: ' "${body}" >"${missing}"
  _ok "$(_t eval '! _field_set_is "${missing}" "${BODY_FIELDS[@]}"')" '(A6) a missing key FAILS the equality'
  _ok "$([[ "$(cat "${out}/INV-O1.title.log")" == 'soak(nightly): INV-O1' ]] && echo 0 || echo 1)" \
    '(A7) the title is soak(<profile>): <invariant id>'
  _ok "$(_t _no_gh)" '(A8) without --file there is no gh call of any kind'
  _ok "$(_t eval '! grep -qF -e "simdev#0" -e "0x5eed5eed5eed5eed" -e "run_url" "${stdout}" "${stderr}"')" \
    '(A9) the body never reaches stdout or stderr (the job log is public)'
  _ok "$(_t cmp -s <(cat "${out}/INV-O1.title.log" "${body}") "${scan_seen}")" \
    '(A10) the backstop scanned exactly the title and body gh would be handed'
  _ok "$(_t grep -qxF -- "scan --rules-only --sink diag=${out}/INV-O1.title.log,${body}" "${scan_calls}")" \
    '(A11) the backstop is a --rules-only scan of the diag class'
  # The same verdict with the seed moved: only the body may change.
  local title_a title_b
  title_a="$(cat "${out}/INV-O1.title.log" || true)"
  _reset
  _slot s1 "$(_mut '.seed = "0x0123456789abcdef"')"
  _run -- s1
  title_b="$(cat "${out}/INV-O1.title.log" || true)"
  _ok "$([[ "${title_a}" == "${title_b}" ]] && grep -qF '0x0123456789abcdef' "${out}/INV-O1.body.log" && echo 0 || echo 1)" \
    '(A12) two seeds, one title — the seed is in the body, never the title'

  printf -- '--- refusals: an unknown key, and one per shape ---\n'
  _reset
  _slot s1 "$(_mut '.peer_npub = "npub1needleneedleneedle"')"
  _run --file -- s1
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && echo 0 || echo 1)" '(R1) a key outside VERDICT_KEYS refuses the run: rc 2, zero gh calls'
  _ok "$(_t grep -qF "the key 'peer_npub'" "${stderr}")" '(R2) ...naming the key'
  _ok "$(_t eval '! grep -qF needle "${stdout}" "${stderr}"')" '(R3) ...and never its value'
  _reset
  _slot s1 "$(_mut '.["Saturday Ride"] = 1')"
  _run -- s1
  _ok "$([[ "${rc}" == 2 ]] && grep -qF 'an unprintable key' "${stderr}" && ! grep -qF 'Saturday' "${stderr}" && echo 0 || echo 1)" \
    '(R4) a key that is itself a value is refused without being printed'
  _refuses '(R5) a profile other than --profile' "$(_mut '.profile = "weekly"')"
  _refuses '(R6) a seed that is not 0x + 16 hex (32 hex)' "$(_mut '.seed = "0x0123456789abcdef0123456789abcdef"')"
  _refuses '(R7) a schedule_tag that is not 8 hex' "$(_mut '.schedule_tag = "a1b2c3d4e5"')"
  _refuses '(R8) a 40-hex commit' "$(_mut '.commit = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"')"
  _refuses '(R9) a toolchain that is prose' "$(_mut '.rustc = "rustc 1.98.0 (built on relay.example.com)"')"
  _refuses '(R10) an rc outside the taxonomy' "$(_mut '.rc = 7')"
  _refuses '(R11) an rc_name that is not its rc'"'"'s' "$(_mut '.rc_name = "clean"')"
  _refuses '(R12) a scenario that is not a registry id' "$(_mut '.scenario = "Saturday Ride"')"
  _refuses '(R13) an arm that is prose' "$(_mut '.arm = "arm at wss://relay.example.com"')"
  _refuses '(R14) an invariant id that is not namespaced' "$(_mut '.invariant = "O1"')"
  _refuses '(R15) an invariant id spelling a 64-hex event id' \
    "$(_mut '.invariant = "INV-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"')"
  _refuses '(R16) a tick that is an absolute Unix instant' "$(_mut '.tick = 1727430000')"
  _refuses '(R17) a bound that is not an integer' "$(_mut '.bound_secs = "145"')"
  _refuses '(R18) an observation that is fractional' "$(_mut '.observed_secs = 190.5')"
  _refuses '(R19) a handle that is a name' "$(_mut '.handles = ["simdev#0", "Saturday Ride"]')"
  _refuses '(R20) a handle that is an endpoint' "$(_mut '.handles = ["wss://relay.example.com"]')"
  _refuses '(R21) a handle that is an IPv4 literal' "$(_mut '.handles = ["198.51.100.7"]')"
  _refuses '(R22) a handle that is a coordinate pair' "$(_mut '.handles = ["52.5200,13.4050"]')"
  _refuses '(R23) a handle with a 40-hex ordinal' "$(_mut '.handles = ["simdev#9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"]')"
  _refuses '(R24) a finding_class that is prose' "$(_mut '.finding_class = "probe lost near 52.52, 13.40"')"
  _refuses '(R25) a string carrying an escape' "$(_mut '.arm = "single-relay-outage\n"')"
  _refuses '(R26) two JSON objects in one verdict.log' "${good}${good}"
  _refuses '(R27) a verdict.log that is not an object' '["simdev#0"]'
  _refuses '(R28) a partial violation (a scenario with no arm)' "$(_mut 'del(.arm)')"
  _reset
  _slot s1 "${good}"
  _run 'GITHUB_REPOSITORY=owner/repo name' -- s1
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && echo 0 || echo 1)" '(R29) a run identity off its shape refuses'
  _reset
  _slot s1 "${good}"
  _run -- s5
  _ok "$([[ "${rc}" == 2 ]] && echo 0 || echo 1)" '(R30) a slot outside s1..s4 refuses'
  # One bad slot refuses the whole run, the good slot included.
  _reset
  _slot s1 "${good}"
  _slot s2 "$(_mut '.handles = ["Saturday Ride"]')"
  _run --file -- s1 s2
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && echo 0 || echo 1)" '(R31) one refused slot files nothing for ANY slot'
  # A flattened download: download-artifact puts a LONE matching artifact's
  # files at the root of its path. Read as it lies, every slot is no-verdict.
  _reset
  printf '%s\n' "${good}" >"${tree}/${VERDICT_LOG}"
  _run --file -- s1 s2
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && grep -qF 'flattened download' "${stderr}" && [[ -z "$(find "${out}" -name '*.body.log' 2>/dev/null)" ]] && echo 0 || echo 1)" \
    '(R32) a verdict.log at the top of the tree refuses: never filed as no-verdict'
  _reset
  printf 'contained\n' >"${tree}/${CONTAINED_LOG}"
  _run --file -- s1
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && echo 0 || echo 1)" '(R33) a containment note at the top of the tree refuses too'
  _reset
  _slot s1 "${clean}"
  _run --red s2 -- s1
  _ok "$([[ "${rc}" == 0 ]] && _no_gh && [[ -z "$(find "${out}" -mindepth 1)" ]] && echo 0 || echo 1)" \
    '(R34) a red job for a slot --slots does not name files nothing: the slot list decides which slots were run'
  # No refusal line ever carries a VALUE: each run plants one and reads the
  # public stderr back for it. A slot literal, a field name, or a key the
  # title already makes public is all a refusal may say.
  local leaked=0 mutation planted
  while IFS='|' read -r mutation planted; do
    _reset
    _slot s1 "$(_mut "${mutation}")"
    _run --file -- s1
    [[ "${rc}" == 2 ]] || leaked=1
    ! grep -qF -- "${planted}" "${stdout}" "${stderr}" || leaked=1
  done <<'PLANTS'
.seed = "0x0123456789abcdef0123456789abcdef"|0123456789abcdef0123
.commit = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"|9f86d081884c7d65
.rustc = "rustc 1.98.0 (built on relay.example.com)"|relay.example.com
.scenario = "Saturday Ride"|Saturday Ride
.arm = "arm at wss://relay.example.com"|wss://
.invariant = "INV-0123456789ABCDEF0123456789ABCDEF"|0123456789ABCDEF
.tick = 1727430000|1727430000
.handles = ["simdev#0", "Quiet Wanderer"]|Quiet Wanderer
.handles = ["198.51.100.7"]|198.51.100.7
.finding_class = "probe lost near 52.52, 13.40"|52.52
.["npub1needle"] = 1|npub1needle
PLANTS
  _reset
  _slot s1 "${good}"
  _run 'GITHUB_REPOSITORY=Saturday Ride/repo' -- s1
  [[ "${rc}" == 2 ]] || leaked=1
  ! grep -qF 'Saturday' "${stdout}" "${stderr}" || leaked=1
  _ok "${leaked}" '(R35) no refusal line carries the value it refused, for eleven planted shapes and a run identity'

  printf -- '--- the negative half: nothing from the tree but verdict.log ---\n'
  _reset
  _slot s1 "${good}"
  local d="${tree}/soak-core-nightly-s1-${run_id}"
  printf '%s\n' 'haven-soak timeline tail: Saturday Ride members=7 epoch 1812 at 1727430000' >"${d}/soak-timeline.log"
  printf '%s\n' 'banner: ws://198.51.100.7:7777 /tmp/haven-soak/evidence/s01.log' >"${d}/banner.log"
  printf '%s\n' 'first violation: the relay at wss://relay.example.com refused; Quiet Wanderer' >"${d}/soak-violation-0000000000000001.log"
  printf '%s\n' 'an invariant broke; the first-violation snapshot beside this marker is the evidence' >"${d}/VIOLATION.marker"
  _run -- s1
  body="${out}/INV-O1.body.log"
  local needle
  for needle in 'Saturday Ride' 'members=7' 'epoch 1812' '1727430000' '198.51.100.7' '/tmp/' 'wss://' 'Quiet Wanderer' 'first violation' 'snapshot'; do
    _ok "$(_t eval '! grep -qF -- "${needle}" "${body}" "${out}/INV-O1.title.log"')" "(N) a stray file's '${needle}' is not in the body"
  done

  printf -- '--- synthetic keys: no red is ever unreported ---\n'
  _reset
  mkdir -p "${tree}/soak-core-nightly-s1-${run_id}"
  _run -- s1 s2
  _ok "$([[ "${rc}" == 0 && "$(cat "${out}/no-verdict.title.log")" == 'soak(nightly): no-verdict' ]] && echo 0 || echo 1)" \
    '(K1) an empty slot directory AND a missing one are no-verdict'
  _ok "$(_t _field_set_is "${out}/no-verdict.body.log" profile slot run_url run_attempt artifact)" \
    '(K2) ...with run_attempt in the body and no field read from a tree'
  _ok "$([[ "$(grep -c '^slot: ' "${out}/no-verdict.body.log")" == 2 ]] && echo 0 || echo 1)" \
    '(K3) ...one block per slot, both under the one key'
  _reset
  mkdir -p "${tree}/soak-core-nightly-s1-${run_id}"
  printf '%s\n' 'haven-soak: the log-privacy scan reported a LEAK and every capture was' \
    >"${tree}/soak-core-nightly-s1-${run_id}/${CONTAINED_LOG}"
  _run -- s1
  _ok "$(_t _field_set_is "${out}/leak-contained.body.log" profile slot run_url run_attempt artifact)" \
    '(K4) a contained tree is leak-contained, carrying no field read from it'
  _ok "$(_t eval '! grep -qF "log-privacy" "${out}/leak-contained.body.log"')" '(K5) ...and not quoting the containment note'
  _reset
  _slot s1 "$(_mut '.rc = 3 | .rc_name = "unusable" | del(.invariant) | .finding_class = "floor-unmet" | .handles = []')"
  _slot s2 "$(jq -c '.rc = 2 | .rc_name = "rig"' <<<"${clean}")"
  _slot s3 "$(jq -c '.rc = 4 | .rc_name = "meta"' <<<"${clean}")"
  _run -- s1 s2 s3
  _ok "$([[ -f "${out}/no-faults-fired.body.log" && -f "${out}/rig-broken.body.log" && -f "${out}/ungraded.body.log" ]] && echo 0 || echo 1)" \
    '(K6) rc 3, 2 and 4 file under no-faults-fired, rig-broken and ungraded'
  _ok "$(_t grep -qxF 'rc: 3 unusable' "${out}/no-faults-fired.body.log")" '(K7) ...the rc-3 body says the run proves nothing, by its rc'
  _ok "$(grep -qxF 'invariant: -' "${out}/no-faults-fired.body.log" && grep -qxF 'handles: -' "${out}/no-faults-fired.body.log" && echo 0 || echo 1)" \
    '(K8) ...a floor carries no invariant and no handles, rendered as absent'
  _reset
  _slot s1 "$(_mut 'del(.invariant)')"
  _run -- s1
  _ok "$(_t test -f "${out}/probe-not-delivered.body.log")" '(K9) rc 1 with no invariant keys on its finding class'
  # The lane folds its own scan into the job: a rig rc 0 under a red job is a
  # red slot the verdict alone would never file.
  _reset
  _slot s1 "${clean}"
  _slot s2 "${clean}"
  _run --red s1 -- s1 s2
  _ok "$([[ "${rc}" == 0 && "$(cat "${out}/lane-red.title.log")" == 'soak(nightly): lane-red' ]] \
      && _field_set_is "${out}/lane-red.body.log" profile slot run_url run_attempt artifact \
      && [[ "$(grep '^slot: ' "${out}/lane-red.body.log")" == 'slot: s1' ]] && echo 0 || echo 1)" \
    '(K10) a red slot whose verdict is rc 0 files lane-red, header fields and artifact only; its green sibling files nothing'
  _reset
  _slot s1 "${good}"
  mkdir -p "${tree}/soak-core-nightly-s2-${run_id}"
  _run --red s1,s2 -- s1 s2
  _ok "$([[ "${rc}" == 0 && -f "${out}/INV-O1.body.log" && -f "${out}/no-verdict.body.log" && ! -e "${out}/lane-red.body.log" ]] && echo 0 || echo 1)" \
    '(K11) a red slot with a verdict files under its key and one with none under no-verdict — never also lane-red'

  printf -- '--- the job listing: a slot is red by its job, read here ---\n'
  local jobs="${tmp}/sample-jobs.json"
  _reset
  for d in s1 s2 s3 s4; do _slot "${d}" "${clean}"; done
  _jobs "${jobs}" s1=success s2=failure s3=success
  _run --jobs "${jobs}" -- s1 s2 s3 s4
  _ok "$([[ "${rc}" == 0 && "$(grep '^slot: ' "${out}/lane-red.body.log" | tr '\n' ' ')" == 'slot: s2 slot: s4 ' ]] \
      && [[ "$(find "${out}" -name '*.body.log' | wc -l)" == 1 ]] && echo 0 || echo 1)" \
    '(J1) a job listing with one failed slot job and one absent slot job files exactly those two as lane-red, and nothing else'
  _reset
  for d in s1 s2 s3 s4; do _slot "${d}" "${clean}"; done
  _jobs "${jobs}" s1=cancelled s2=skipped s3=success s4=success
  jq -c '.jobs |= map(if .name == "Soak Core (nightly, s3) / e2e_soak_core_nightly" then .conclusion = null else . end)' \
    "${jobs}" >"${jobs}.next" && mv "${jobs}.next" "${jobs}"
  _run --jobs "${jobs}" -- s1 s2 s3 s4
  _ok "$([[ "${rc}" == 0 && "$(grep '^slot: ' "${out}/lane-red.body.log" | tr '\n' ' ')" == 'slot: s1 slot: s2 slot: s3 ' ]] && echo 0 || echo 1)" \
    '(J2) cancelled, skipped and not-yet-concluded are red: only success is green'
  # A refusal: rc 2, named, no gh call, no body, and no byte of the listing on
  # the public streams (each listing plants a name).
  _jobs_refuses() { # _jobs_refuses <label> <jobs-file> <message>
    _reset
    _slot s1 "${good}"
    _run --file --jobs "$2" -- s1
    _ok "$([[ "${rc}" == 2 ]] && _no_gh && grep -qF -- "$3" "${stderr}" \
        && ! grep -qF 'Saturday Ride' "${stdout}" "${stderr}" \
        && [[ -z "$(find "${out}" -name '*.body.log' 2>/dev/null)" ]] && echo 0 || echo 1)" "$1"
  }
  jq -nc '{total_count: 100, jobs: [range(0; 100) | {name: "Saturday Ride \(.)", conclusion: "success"}]}' >"${jobs}"
  _jobs_refuses '(J3) a job listing that fills its page of 100 refuses, named: a slot job past it would read as absent' \
    "${jobs}" 'filled its page of 100'
  jq -nc '{total_count: 250, jobs: [range(0; 100) | {name: "Saturday Ride \(.)", conclusion: "success"}]}' >"${jobs}"
  _jobs_refuses '(J4) ...and so does a first page of a longer listing' "${jobs}" 'filled its page of 100'
  _jobs "${jobs}" s1=success
  head -c 90 "${jobs}" >"${jobs}.cut"
  printf '"Saturday Ride"\n' >>"${jobs}.cut"
  _jobs_refuses '(J5) a truncated job listing refuses, named' "${jobs}.cut" 'is not one page of the API'"'"'s listing'
  printf '{"total_count":1,"jobs":{"name":"Saturday Ride"}}\n' >"${jobs}"
  _jobs_refuses '(J6) a job listing whose jobs member is not a list refuses' "${jobs}" 'is not one page'
  printf '{"total_count":1,"jobs":[{"name":"Saturday Ride"}]}\n{"total_count":0,"jobs":[]}\n' >"${jobs}"
  _jobs_refuses '(J7) two JSON values in one listing refuse' "${jobs}" 'is not one page'
  _jobs_refuses '(J8) an absent listing file refuses' "${tmp}/no-such-jobs.json" 'is not a file'
  _reset
  _slot s1 "${good}"
  ( export GITHUB_SERVER_URL='https://github.com' GITHUB_REPOSITORY='o/r' GITHUB_RUN_ID="${run_id}" GITHUB_RUN_ATTEMPT=1
    main --profile nightly --tree "${tree}" --out "${out}" --slots s1 ) >"${stdout}" 2>"${stderr}" && rc=0 || rc=$?
  _ok "$([[ "${rc}" == 2 && ! -e "${out}" ]] && echo 0 || echo 1)" \
    '(J9) no --jobs-json is a usage error: a slot is never read as green for want of its job'

  printf -- '--- --assert-no-artifacts: a failed download is an empty night only if the listing agrees ---\n'
  local listing="${tmp}/artifacts.json"
  _assert() { # _assert <listing> — runs the mode as the download step does
    rc=0
    ( export GITHUB_RUN_ID="${run_id}"
      "${BASH_SOURCE[0]}" --assert-no-artifacts "$1" --profile nightly ) >"${stdout}" 2>"${stderr}" || rc=$?
  }
  jq -nc --arg r "${run_id}" '{total_count: 3, artifacts: [
      {name: "soak-core-nightly-s1-\($r)", expired: true},
      {name: "soak-core-nightly-s1-99", expired: false},
      {name: "soak-core-pr-s1-\($r)", expired: false}]}' >"${listing}"
  _assert "${listing}"
  _ok "$([[ "${rc}" == 0 ]] && grep -qF 'every slot is filed as no-verdict' "${stdout}" && echo 0 || echo 1)" \
    '(D1) no unexpired slot artifact of this run and profile: the empty tree is honest, rc 0'
  jq -nc --arg r "${run_id}" '{total_count: 2, artifacts: [
      {name: "Saturday Ride", expired: false}, {name: "soak-core-nightly-s3-\($r)", expired: false}]}' >"${listing}"
  _assert "${listing}"
  _ok "$([[ "${rc}" == 2 ]] && grep -qF 'slot artifacts exist' "${stderr}" && ! grep -qF 'Saturday Ride' "${stdout}" "${stderr}" && echo 0 || echo 1)" \
    '(D2) one unexpired slot artifact behind a failed download refuses, named, printing no artifact name'
  jq -nc '{total_count: 100, artifacts: [range(0; 100) | {name: "Saturday Ride", expired: false}]}' >"${listing}"
  _assert "${listing}"
  _ok "$([[ "${rc}" == 2 ]] && grep -qF 'filled its page of 100' "${stderr}" && echo 0 || echo 1)" \
    '(D3) an artifact listing that fills its page refuses: a slot artifact past it would read as absent'
  printf '{"total_count":0,"artifacts":\n' >"${listing}"
  _assert "${listing}"
  _ok "$([[ "${rc}" == 2 ]] && grep -qF 'is not one page' "${stderr}" && echo 0 || echo 1)" '(D4) a malformed artifact listing refuses'
  printf '{"total_count":0,"artifacts":[]}\n' >"${listing}"
  rc=0
  ( export GITHUB_RUN_ID='Saturday Ride'
    "${BASH_SOURCE[0]}" --assert-no-artifacts "${listing}" --profile nightly ) >"${stdout}" 2>"${stderr}" || rc=$?
  _ok "$([[ "${rc}" == 2 ]] && ! grep -qF 'Saturday' "${stderr}" && echo 0 || echo 1)" '(D5) a run id off its shape refuses without printing it'

  printf -- '--- filing: one per key, dedup, labels, the gate ---\n'
  _reset
  for d in s1 s2 s3 s4; do _slot "${d}" "${good}"; done
  _run --file -- s1 s2 s3 s4
  _ok "$([[ "${rc}" == 0 && "$(_creates)" == 1 && "$(_comments)" == 0 ]] && echo 0 || echo 1)" \
    '(F1) four slots on one invariant file exactly ONE issue'
  _ok "$([[ "$(grep -c '^slot: ' "${bodies}/create-1")" == 4 ]] && echo 0 || echo 1)" '(F2) ...whose body carries four slot blocks'
  _ok "$(_t grep -qxF 'issue create --title soak(nightly): INV-O1 --body-file '"${out}"'/INV-O1.body.log --label soak --label soak:core' "${calls}")" \
    '(F3) ...labelled soak and soak:core, and assigned to nobody'
  _ok "$(_t grep -qxF 'issue list --label soak --label soak:core --state open --limit 100 --json number,title' "${calls}")" \
    '(F4) the dedup listing is the open issues carrying both labels'
  # The same night again: the listing now serves the issue the first created.
  : >"${calls}"; rm -rf "${out}"
  _run --file -- s1 s2 s3 s4
  _ok "$([[ "${rc}" == 0 && "$(_creates)" == 0 && "$(_comments)" == 1 ]] && echo 0 || echo 1)" \
    '(F5) a second night on the same key does not create: it comments'
  _ok "$(_t cmp -s "${bodies}/create-1" "${bodies}/comment-1")" '(F6) ...with the same body'
  _reset
  _slot s1 "${good}"
  _slot s2 "$(_mut '.invariant = "INV-O6" | .finding_class = "not-quiescent"')"
  _run --file -- s1 s2
  _ok "$([[ "${rc}" == 0 && "$(_creates)" == 2 ]] && echo 0 || echo 1)" '(F7) two invariants are two issues'
  _reset
  for d in s1 s2 s3 s4; do _slot "${d}" "${clean}"; done
  _run --file -- s1 s2 s3 s4
  _ok "$([[ "${rc}" == 0 ]] && _no_gh && [[ -z "$(find "${out}" -mindepth 1)" ]] && echo 0 || echo 1)" \
    '(F8) four green slots are silent: zero gh calls, no body'
  _reset
  _slot s1 "${good}"
  printf '[{"number":3,"title":"soak(nightly): INV-O1"},{"number":9,"title":"soak(nightly): INV-O1"}]\n' >"${open}"
  _run --file -- s1
  _ok "$([[ "${rc}" == 2 && "$(_creates)" == 0 && "$(_comments)" == 0 ]] && echo 0 || echo 1)" \
    '(F9) two open issues with one title: rc 2, never a third'
  _reset
  _slot s1 "${good}"
  jq -nc '[range(1; 101) | {"number": ., "title": "unrelated"}]' >"${tmp}/full.json"
  _run --file "STUB_GH_LIST_FILE=${tmp}/full.json" -- s1
  _ok "$([[ "${rc}" == 2 && "$(_creates)" == 0 ]] && echo 0 || echo 1)" '(F10) a listing that fills its page is not a dedup: rc 2'
  _reset
  _slot s1 "${good}"
  _run --file 'STUB_GH_CREATE_FAIL=1' -- s1
  _ok "$([[ "${rc}" == 2 ]] && grep -qF 'do the labels soak soak:core exist?' "${stderr}" && echo 0 || echo 1)" \
    '(F11) a create gh refuses (a label that does not exist) is rc 2, named'
  _reset
  _slot s1 "${good}"
  mkdir -p "${out}"
  printf 'stale\n' >"${out}/INV-O1.body.log"
  _run --file -- s1
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && echo 0 || echo 1)" '(F12) a non-empty --out refuses: a stale body is never filed'

  printf -- '--- the backstop runs, and refuses on anything but clean ---\n'
  _reset
  _slot s1 "${good}"
  _run --file 'STUB_SCAN_RC=1' -- s1
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && [[ ! -e "${out}/INV-O1.body.log" ]] && echo 0 || echo 1)" \
    '(B1) a backstop LEAK refuses: zero gh calls, the body removed'
  _reset
  _slot s1 "${good}"
  _run --file 'STUB_SCAN_RC=3' -- s1
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && echo 0 || echo 1)" '(B2) an unusable backstop scan refuses too'
  _reset
  _slot s1 "${good}"
  _run --file "HAVEN_LOGSCAN_BIN=${tmp}/absent-scanner" -- s1
  _ok "$([[ "${rc}" == 2 ]] && _no_gh && echo 0 || echo 1)" '(B3) an absent scanner is a refusal, never a skipped scan'
  _ok "$(grep -qF 'is a BACKSTOP, not the control: a scanner cannot catch an' "${BASH_SOURCE[0]}" \
      && grep -qF 'undeclared value' "${BASH_SOURCE[0]}" && grep -qF 'The allowlist is the control.' "${BASH_SOURCE[0]}" \
      && echo 0 || echo 1)" \
    '(B4) the header says, in those words, that the scan is a backstop and the allowlist the control'

  printf '\n'
  if ((fails != 0)); then
    printf '%s --self-test: FAILED\n' "${SCRIPT_NAME}" >&2
    return 1
  fi
  if ((n != SELF_TEST_FIXTURES)); then
    printf '%s --self-test: ran %d fixture(s), expected exactly %d. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success.\n' \
      "${SCRIPT_NAME}" "${n}" "${SELF_TEST_FIXTURES}" >&2
    return 1
  fi
  printf 'OK: %s --self-test passed (%d/%d fixtures).\n' "${SCRIPT_NAME}" "${n}" "${SELF_TEST_FIXTURES}"
}

if [[ "${1:-}" == --self-test ]]; then
  [[ $# -eq 1 ]] || usage
  self_test
  exit $?
fi
if [[ "${1:-}" == --assert-no-artifacts ]]; then
  [[ $# -eq 4 && "$3" == --profile ]] || usage
  PROFILE="$4"
  RUN_ID="${GITHUB_RUN_ID:-}"
  [[ "${PROFILE}" =~ ${RE_PROFILE} ]] || refuse "--profile is not pr, nightly or weekly"
  [[ "${RUN_ID}" =~ ${RE_RUN_ID} ]] || refuse "GITHUB_RUN_ID is not a run id"
  assert_no_artifacts "$2"
  exit 0
fi
main "$@"
