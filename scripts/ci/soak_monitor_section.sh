#!/usr/bin/env bash
#
# The Soak Nightly section of the weekly flakiness monitor (e2e-flakiness.yml).
#
# ## Why this is a script and not more of the monitor's inline block
#
# The monitor's lane table is inline bash with no fixture of its own; growing
# it would add the one kind of change nothing can self-test. So the section
# lives here, with a `--self-test` that drives the real `main` against a `gh`
# stub and the real scripts/ci/soak_seed.sh, and the workflow only calls it.
#
# ## What a row is, and why a soak red is never a flake
#
# soak-nightly.yml runs one matrix slot per seed a night (four today), each
# under `name: Soak Core (nightly, <slot>)` over the reusable's inner job id, so each
# slot reaches the API as `Soak Core (nightly, <slot>) / e2e_soak_core_nightly`
# — the " / e2e_" branch of the lane regex at e2e-flakiness.yml's job filter,
# with no change to it. Rows are grouped by that FULL display name, one per
# slot, so a red on s1 is not averaged away by three greens.
#
# A red slot is a schedule that found something (rc 1) or a rig that could not
# prove anything (rc 2/3/4, or a build failure). Neither is an intermittent
# wobble to be rated, so this section counts reds and prints no rate and no
# goal. The monitor's fail-rate table does not read soak-nightly.yml at all
# (its union is ci.yml, e2e-nightly.yml and the stress loop); the PR-profile
# soak lane it does read runs one fixed seed, so a red there that comes and
# goes on main IS rig non-determinism, and the table rates it like any lane.
# The filed issue (scripts/ci/file_soak_issue.sh) carries rc and rc_name; this
# section links it and does not re-derive it.
#
# ## The streak, and why it reads job conclusions
#
# A night is green only when EVERY scheduled `core` slot concluded `success`. A red,
# cancelled, skipped or absent slot ends the streak: soak-nightly.yml runs the
# matrix `fail-fast: false`, so an unrun slot is a slot that asserted nothing,
# and a phase gated on "every slot green" cannot count it as a pass. It is read
# from the slot jobs' conclusions and never from the run's, because `file-issue`
# runs `if: always()` and can red a run on its own. "Consecutive" counts
# scheduled runs, so the cron's Sunday gap never breaks it; a run still in
# progress is not a night yet and is skipped.
#
# ## Seeds are derived, and from the run's created_at only
#
# The seed each slot ran is `soak_seed.sh --seed nightly <date> <slot>`, the
# one definition soak-nightly.yml's `prepare` job uses; a second copy here
# would be a copy that could name a seed no slot ran. `<date>` is the first ten
# characters of the RUN's `createdAt` — the value `prepare` read — never a
# job's start, never `/attempts/<n>` (a re-run keeps its run's created_at and
# therefore its seeds). Only `--event schedule` runs are read: a
# `workflow_dispatch` repro may carry a pinned seed the derivation never
# produced, and it is a human already looking, not a night.
#
# ## The coverage knee, and the 30-night cost review
#
# The review (PLAN §8 OQ-R) is due once 30 scheduled nights have completed —
# the fifth Monday report after the nightly lands. This section is its trigger
# and its input: it says when the review is due, and prints the two numbers it
# reads — the median per-slot minutes, and the coverage knee: per slot-night,
# the first probe after the last new fault label — the largest first_tick of
# the rig's coverage.log probe-round triples — and the lower median of those.
# The knee's window is 14 days, not the report's 30, because that is the artifact
# retention; older nights have nothing left to download.
#
# ## Rule 15, and what may be printed
#
# Every value printed is from a closed set: a date (YYYY-MM-DD), a run link
# BUILT here from GITHUB_SERVER_URL/GITHUB_REPOSITORY/run id (never a URL the
# API returned), a slot name, a derived seed, a fixed outcome word, an issue
# number, and rig counts (nights, reds, streaks, minutes, ticks). No job name
# from the API, no issue text, no log line, no step name, no instant. Nothing
# goes to stdout: the section is written to the `--out` file in one piece, so
# a failure leaves that file untouched.
#
# Usage:
#   soak_monitor_section.sh --out <file> --since <T> --coverage-since <T>
#       <T> is an RFC 3339 UTC instant (YYYY-MM-DDTHH:MM:SSZ). Reads
#       GITHUB_REPOSITORY (owner/name), GITHUB_SERVER_URL (default
#       https://github.com) and the token `gh` reads (GH_TOKEN).
#   soak_monitor_section.sh --self-test
#
# Exit codes:
#   0  the section was written
#   2  misconfiguration, or an input this script refuses to interpret (a
#      malformed listing, a coverage.log off its schema, a refused seed)
#   3  a GitHub API read failed; NOTHING was written — a section missing its
#      soak rows must never read as a quiet week

set -euo pipefail

readonly SCRIPT_NAME='soak_monitor_section'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SEED_SCRIPT="${SCRIPT_DIR}/soak_seed.sh"

readonly NIGHTLY_WORKFLOW='soak-nightly.yml'
readonly PROFILE='nightly'
# A scheduled night runs the slots `soak_seed.sh --default-slots` prints — the
# list --prepare derives when nothing is dispatched. Asked, not restated:
# DEFAULT_SLOTS there is the documented lever for cutting a night to two slots,
# and a list kept here would then call two slots absent every night and hold
# the streak at 0.
SLOTS=()
load_slots() {
  local s seen=' '
  mapfile -t SLOTS < <(bash "${SEED_SCRIPT}" --default-slots 2>/dev/null) || true
  ((${#SLOTS[@]} >= 1 && ${#SLOTS[@]} <= 4)) \
    || misconfig 'soak_seed.sh --default-slots gave no scheduled slots (its DEFAULT_SLOTS); the scheduled slots are unknown.'
  for s in "${SLOTS[@]}"; do
    [[ "${s}" =~ ^s[1-4]$ && "${seen}" != *" ${s} "* ]] \
      || misconfig 'soak_seed.sh --default-slots printed something that is not a slot list.'
    seen="${seen}${s} "
  done
}
readonly REVIEW_NIGHTS=30
readonly ISSUE_LABELS=(soak soak:core)

misconfig() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }
api_refused() {
  printf '%s: the GitHub API refused %s; no section was written.\n' "${SCRIPT_NAME}" "$1" >&2
  exit 3
}

valid_instant() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

job_name() { printf 'Soak Core (%s, %s) / e2e_soak_core_%s' "${PROFILE}" "$1" "${PROFILE}"; }

seed_for() { # <date> <slot>
  local seed
  seed="$(bash "${SEED_SCRIPT}" --seed "${PROFILE}" "$1" "$2")" \
    || misconfig 'soak_seed.sh refused to derive a seed.'
  [[ "${seed}" =~ ^0x[0-9a-f]{16}$ ]] || misconfig 'soak_seed.sh printed something that is not a seed.'
  printf '%s' "${seed}"
}

# The night objects, newest first: {id, date, completed, cov, slots: {sN: {o, m}}}
# where o is one of green/red/cancelled/skipped/running/absent/undecided and m
# the job's minutes (null unless decided).
readonly NIGHT_JQ='
  def outcome: if . == null then "absent"
    elif .conclusion == "success" then "green"
    elif .conclusion == "failure" then "red"
    elif .conclusion == "cancelled" then "cancelled"
    elif .conclusion == "skipped" then "skipped"
    elif .conclusion == null then "running"
    else "undecided" end;
  .jobs as $jobs
  | {id: $id, date: $date, completed: ($status == "completed"), cov: ($cov == "1"),
     slots: ($names | to_entries | map(.key as $s | .value as $n
       | ([$jobs[] | select(.name == $n)] | first) as $j
       | {key: $s, value: {o: ($j | outcome),
           m: (if ($j | outcome) == "green" or ($j | outcome) == "red"
               then ((($j.completedAt | fromdate) - ($j.startedAt | fromdate)) / 60 | round)
               else null end)}}) | from_entries)}'

# Per slot, over completed nights (newest first): decided nights, reds,
# streak, the latest completed night's date, the last red night, the lower
# median of the decided minutes. One line per slot, in SLOTS order, joined by
# the unit separator: IFS whitespace (a tab) collapses the empty fields a slot
# with no red night has, and would shift every later field left.
readonly ROWS_JQ='
  def lower_median: sort | if length == 0 then null else .[((length - 1) / 2 | floor)] end;
  [.[] | select(.completed)] as $done
  | $slots[] as $s
  | [$done[] | {id, date, o: .slots[$s].o, m: .slots[$s].m}] as $n
  | [$n[] | select(.o == "green" or .o == "red")] as $decided
  | [$n[] | select(.o == "red")] as $reds
  | [$s, ($decided | length), ($reds | length),
     (first(range($n | length) | select($n[.].o != "green")) // ($n | length)),
     ($done[0].date // ""), ($reds[0].date // ""), ($reds[0].id // ""),
     ([$decided[].m] | lower_median // "")]
  | map(tostring) | join("\u001f")'

main() {
  local out='' since='' cov_since=''
  while (($#)); do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      --since) since="${2:-}"; shift 2 ;;
      --coverage-since) cov_since="${2:-}"; shift 2 ;;
      *) misconfig "unknown argument: $1" ;;
    esac
  done
  [[ -n "${out}" ]] || misconfig '--out <file> is required; the section is never printed to stdout.'
  valid_instant "${since}" || misconfig '--since must be YYYY-MM-DDTHH:MM:SSZ.'
  valid_instant "${cov_since}" || misconfig '--coverage-since must be YYYY-MM-DDTHH:MM:SSZ.'
  local repo="${GITHUB_REPOSITORY:-}" server="${GITHUB_SERVER_URL:-https://github.com}"
  [[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || misconfig 'GITHUB_REPOSITORY is not owner/name.'
  [[ "${server}" =~ ^https://[A-Za-z0-9.-]+$ ]] || misconfig 'GITHUB_SERVER_URL is not an https origin.'
  command -v jq >/dev/null 2>&1 || misconfig 'jq is required.'
  command -v gh >/dev/null 2>&1 || misconfig 'gh is required.'
  [[ -f "${SEED_SCRIPT}" ]] || misconfig 'soak_seed.sh is missing; seeds cannot be derived.'
  load_slots

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: the trap must not depend on a live var
  trap "rm -rf '${work}'" EXIT

  # Every scheduled run, not only the window: the review counts all nights.
  # 500 is ~19 months of six-night weeks.
  gh run list --workflow="${NIGHTLY_WORKFLOW}" --event schedule --limit 500 \
    --json databaseId,createdAt,status >"${work}/runs.json" 2>/dev/null \
    || api_refused 'the Soak Nightly run list'
  jq -e 'type == "array" and all(.[]; (.databaseId | type) == "number"
           and (.createdAt | type) == "string" and (.createdAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
           and (.status | type) == "string")' "${work}/runs.json" >/dev/null \
    || misconfig 'the run list is not the shape gh run list --json returns.'

  local sec="${work}/section.md"
  {
    printf '## Soak Nightly\n\n'
    printf 'Scheduled nights only (a `workflow_dispatch` is a repro, not a night). A red slot is a schedule that found something or a rig that could not prove anything; the linked issue carries rc and rc_name. The nightly slots are not in the fail-rate table above: a find is not a wobble, and no rate is computed for it.\n\n'
  } >"${sec}"

  local done_total review_date
  done_total="$(jq '[.[] | select(.status == "completed")] | length' "${work}/runs.json")"
  review_date="$(jq -r --argjson k "${REVIEW_NIGHTS}" \
    '[.[] | select(.status == "completed")] | sort_by(.createdAt) | .[$k - 1].createdAt // "" | .[0:10]' \
    "${work}/runs.json")"
  local review
  if [[ -n "${review_date}" ]]; then
    review="30-night cost review: **due** — the ${REVIEW_NIGHTS}th scheduled night completed on ${review_date}. It reads this section's median minutes and coverage knee and commits one \`duration_secs\`/slot-count change (docs/SOAK_LANE.md, \"The monitor\")."
  else
    review="30-night cost review: due after ${REVIEW_NIGHTS} scheduled nights; ${done_total} completed so far. It will read this section's median minutes and coverage knee."
  fi

  jq --arg since "${since}" '[.[] | select(.createdAt > $since)] | sort_by(.createdAt) | reverse' \
    "${work}/runs.json" >"${work}/window.json"
  if [[ "$(jq 'length' "${work}/window.json")" == 0 ]]; then
    if [[ "$(jq 'length' "${work}/runs.json")" == 0 ]]; then
      printf '_No nights yet: the scheduler has not run._\n\n' >>"${sec}"
    else
      # Silence must read as silence: GitHub disables a schedule after 60 days
      # without repository activity.
      printf '_No scheduled night in the window. The schedule may have been disabled (60 days without repository activity) or the workflow renamed._\n\n' >>"${sec}"
    fi
    printf '%s\n' "${review}" >>"${sec}"
    cat "${sec}" >>"${out}"
    return 0
  fi

  local slots_json names s
  slots_json="$(printf '%s\n' "${SLOTS[@]}" | jq -Rn '[inputs]')"
  names="$(for s in "${SLOTS[@]}"; do jq -n --arg s "${s}" --arg n "$(job_name "${s}")" '{($s): $n}'; done \
    | jq -s 'add')"

  # A repeated key is a COMMENT on the open issue, so a night is linked by the
  # issue body OR any comment naming its run. gh returns an issue's first 100
  # comments and no more; an issue at that page could hide a later night's
  # comment, so it is refused rather than read as unlinked.
  gh issue list --label "${ISSUE_LABELS[0]}" --label "${ISSUE_LABELS[1]}" --state all --limit 500 \
    --json number,body,comments >"${work}/issues.json" 2>/dev/null \
    || api_refused 'the soak issue list'
  jq -e 'type == "array" and all(.[]; (.number | type) == "number" and (.comments | type) == "array")' \
    "${work}/issues.json" >/dev/null \
    || misconfig 'the issue list is not the shape gh issue list --json returns.'
  jq -e 'all(.[]; (.comments | length) < 100)' "${work}/issues.json" >/dev/null \
    || misconfig 'a soak issue carries a full page of comments; nights past it cannot be linked.'

  local id created status date cov url
  : >"${work}/nights.ndjson"
  : >"${work}/knees"
  while IFS=$'\t' read -r id created status; do
    date="${created:0:10}"
    cov=0
    [[ "${status}" == completed && "${created}" > "${cov_since}" ]] && cov=1
    gh run view "${id}" --json jobs >"${work}/jobs-${id}.json" 2>/dev/null \
      || api_refused 'a Soak Nightly job list'
    jq -e '(.jobs | type) == "array"' "${work}/jobs-${id}.json" >/dev/null \
      || misconfig 'a job list is not the shape gh run view --json jobs returns.'
    jq -c --argjson id "${id}" --arg date "${date}" --arg status "${status}" --arg cov "${cov}" \
      --argjson names "${names}" "${NIGHT_JQ}" "${work}/jobs-${id}.json" >>"${work}/nights.ndjson" \
      || misconfig 'a job list carries a job this script cannot read.'
    [[ "${cov}" == 1 ]] && collect_knees "${repo}" "${id}" "${work}"
  done < <(jq -r '.[] | [.databaseId, .createdAt, .status] | @tsv' "${work}/window.json")
  jq -s '.' "${work}/nights.ndjson" >"${work}/nights.json"

  local streak
  streak="$(jq --argjson slots "${slots_json}" '
    [.[] | select(.completed)] as $d
    | first(range($d | length) | select([$slots[] as $s | $d[.].slots[$s].o] | any(. != "green")))
      // ($d | length)' "${work}/nights.json")"
  printf 'consecutive all-slot-green nights: %s\n\n' "${streak}" >>"${sec}"
  printf 'A night is green only when every scheduled slot concluded success; a red, cancelled, skipped or absent slot ends the streak, which is read from the slot jobs and never from the run (`file-issue` can red a run on its own). Zero rc 3 is not a separate count: rc 3 reds its slot, so a green night already has none.\n\n' >>"${sec}"

  {
    printf '| Row | Nights | Red | Streak | Latest seed | Last red | Median minutes |\n'
    printf '|---|---|---|---|---|---|---|\n'
  } >>"${sec}"
  local slot nights reds sstreak latest rdate rid mins seed_latest last_red
  while IFS=$'\x1f' read -r slot nights reds sstreak latest rdate rid mins; do
    if [[ "${nights}" == 0 ]]; then
      printf '| `%s` | no decided night in the window | — | %s | — | — | — |\n' \
        "$(job_name "${slot}")" "${sstreak}" >>"${sec}"
      continue
    fi
    seed_latest="$(seed_for "${latest}" "${slot}")"
    last_red='none'
    if [[ -n "${rdate}" ]]; then
      last_red="${rdate} · \`$(seed_for "${rdate}" "${slot}")\` · [run](${server}/${repo}/actions/runs/${rid})"
    fi
    printf '| `%s` | %s | %s | %s | `%s` | %s | %s |\n' \
      "$(job_name "${slot}")" "${nights}" "${reds}" "${sstreak}" "${seed_latest}" "${last_red}" "${mins}" \
      >>"${sec}"
  done < <(jq -r --argjson slots "${slots_json}" "${ROWS_JQ}" \
             "${work}/nights.json")

  {
    printf '\n| Night | Run |'
    printf ' %s |' "${SLOTS[@]}"
    printf ' Issue |\n|---|---|'
    printf '%s' "$(printf -- '---|%.0s' "${SLOTS[@]}")"
    printf -- '---|\n'
  } >>"${sec}"
  local cells issue
  while IFS=$'\t' read -r id date cells; do
    url="${server}/${repo}/actions/runs/${id}"
    # Linked when the run URL occurs in the body or a comment with no digit
    # after it (run 123's URL is a prefix of run 1234's). Every such issue: two
    # keys red on one night are two issues.
    issue="$(jq -r --arg url "${url}" '
      def names_run: (. // "") | split($url) | .[1:] | any(test("^[0-9]") | not);
      [.[] | select((.body | names_run) or any(.comments[]; .body | names_run)) | .number]
      | sort | if length == 0 then "—" else map("#\(.)") | join(" ") end' "${work}/issues.json")"
    printf '| %s | [run](%s) | %s | %s |\n' "${date}" "${url}" "${cells//$'\t'/ | }" "${issue}" >>"${sec}"
  done < <(jq -r --argjson slots "${slots_json}" '
    .[] | [.id, .date] + [$slots[] as $s | .slots[$s].o] | map(tostring) | @tsv' "${work}/nights.json")

  local knee n_knees
  n_knees="$(wc -l <"${work}/knees" | tr -d ' ')"
  printf '\n' >>"${sec}"
  if [[ "${n_knees}" == 0 ]]; then
    printf 'Coverage knee (14-day window, the artifact retention): not computed — no `coverage.log` was downloadable for any completed night in the window.\n\n' >>"${sec}"
  else
    knee="$(sort -n "${work}/knees" | sed -n "$(( (n_knees - 1) / 2 + 1 ))p")"
    printf 'Coverage knee (14-day window, the artifact retention): median tick %s over %s slot-nights — the first probe after each night'"'"'s last new fault label (its last first-seen probe-round triple).\n\n' \
      "${knee}" "${n_knees}" >>"${sec}"
  fi
  printf '%s\n' "${review}" >>"${sec}"

  cat "${sec}" >>"${out}"
}

# collect_knees <repo> <run-id> <work> — one line per slot-night in
# <work>/knees: the largest first_tick among that slot's PROBE-round triples
# (scenario "nemesis") — the first probe after the last new fault label. Not
# the teardown round ("settled"), graded at the schedule's last tick every
# night, which would make the knee the schedule's length; not an arm, whose
# world carries its own tick (tooling/soak/src/coverage.rs). An artifact
# that was never uploaded or has expired contributes nothing; an API refusal is
# exit 3, and a coverage.log off its schema is exit 2, never a silent skip.
collect_knees() {
  local repo="$1" id="$2" work="$3" slot name dir k
  local -a found
  gh api "repos/${repo}/actions/runs/${id}/artifacts?per_page=100" >"${work}/art-${id}.json" 2>/dev/null \
    || api_refused 'an artifact list'
  jq -e '(.artifacts | type) == "array"' "${work}/art-${id}.json" >/dev/null \
    || misconfig 'an artifact list is not the shape the artifacts endpoint returns.'
  for slot in "${SLOTS[@]}"; do
    name="soak-core-${PROFILE}-${slot}-${id}"
    [[ "$(jq --arg n "${name}" '[.artifacts[] | select(.name == $n and .expired == false)] | length' \
          "${work}/art-${id}.json")" == 1 ]] || continue
    dir="${work}/cov/${id}-${slot}"
    mkdir -p "${dir}"
    gh run download "${id}" -n "${name}" -D "${dir}" >/dev/null 2>&1 \
      || api_refused 'an artifact download'
    mapfile -t found < <(find "${dir}" -type f -name coverage.log)
    ((${#found[@]} <= 1)) || misconfig 'an artifact holds more than one coverage.log.'
    ((${#found[@]} == 1)) || continue
    k="$(jq -e '
      if (.triples | type) != "array" then error("schema")
      elif any(.triples[]; (.scenario | type) != "string" or (.first_tick | type) != "number"
                           or (.first_tick | tostring | test("^[0-9]+$") | not)) then error("schema")
      else [.triples[] | select(.scenario == "nemesis") | .first_tick] | max end' "${found[0]}" 2>/dev/null)" \
      || { [[ "${k:-}" == null ]] || misconfig 'a coverage.log is off its schema.'; }
    [[ "${k}" == null ]] || printf '%s\n' "${k}" >>"${work}/knees"
  done
}

# ---------------------------------------------------------------------------
# --self-test — hermetic: `gh` is a stub on PATH; soak_seed.sh is the real one.
# ---------------------------------------------------------------------------

# Pinned by equality against the fixtures that actually ran, because a fixture
# that stops running is the one way a deleted fixture reports success.
readonly SELF_TEST_FIXTURES=39

# The shapes below are MEASURED, not sketched (2026-09-27, this repository, gh
# 2.97.0): `gh run list --json databaseId,createdAt,status` is a bare array;
# `gh run view <id> --json jobs` is `{"jobs":[…]}` whose jobs carry name,
# conclusion (null while running), status, startedAt, completedAt, databaseId,
# url and steps; the artifacts endpoint is `{"total_count","artifacts":[{name,
# expired,…}]}`; `gh run download <id> -n <name> -D <dir>` extracts that one
# artifact's files straight into <dir>; `gh issue list --label <absent label>`
# is `[]` with rc 0. A refused read exits 1 with `HTTP <code>: …` on stderr —
# `gh run list --workflow=soak-nightly.yml` answered exactly that, 404, while
# the workflow was not yet on the default branch.
_write_gh_stub() { # <bin-dir>
  cat >"$1/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_CALLS}"
refuse() { printf 'HTTP 404: Not Found (https://api.github.com/stub)\n' >&2; exit 1; }
case "$1 $2" in
  'run list')
    [[ "${STUB_REFUSE:-}" != list ]] || refuse
    # The event filter is the server's; the fixture's `event` is not a field
    # this call asks for, so it never reaches the caller.
    if [[ " $* " == *' --event schedule '* ]]; then
      jq -c '[.[] | select((.event // "schedule") == "schedule") | del(.event)]' "${STUB_FIX}/runs.json"
    else
      jq -c '[.[] | del(.event)]' "${STUB_FIX}/runs.json"
    fi
    ;;
  'run view')   [[ "${STUB_REFUSE:-}" != view ]] || refuse; cat "${STUB_FIX}/jobs-$3.json" ;;
  'issue list') [[ "${STUB_REFUSE:-}" != issues ]] || refuse; cat "${STUB_FIX}/issues.json" ;;
  'run download')
    [[ "${STUB_REFUSE:-}" != download ]] || refuse
    name=''; dir=''
    shift 3
    while (($#)); do
      case "$1" in -n) name="$2"; shift 2 ;; -D) dir="$2"; shift 2 ;; *) shift ;; esac
    done
    [[ -d "${STUB_FIX}/art/${name}" ]] || { printf 'no artifact matches any of the names or patterns provided\n' >&2; exit 1; }
    cp -R "${STUB_FIX}/art/${name}/." "${dir}/"
    ;;
  api\ *)
    [[ "${STUB_REFUSE:-}" != api ]] || refuse
    id="${2#*/actions/runs/}"; id="${id%%/*}"
    if [[ -f "${STUB_FIX}/art-${id}.json" ]]; then cat "${STUB_FIX}/art-${id}.json"
    else printf '{"total_count":0,"artifacts":[]}\n'; fi
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$1/gh"
}

# _jobs <run-id> <created-date> <o1> <o2> <o3> <o4> [red-minutes] — one run's
# job list: prepare, the four slot jobs (an outcome of `absent` omits the job),
# and file-issue. Every decided job runs 72 minutes except a red one, which
# runs [red-minutes]; a red job STARTS the day after its run was created, so a
# seed taken from the job's date instead of the run's is a different seed.
# Every job carries a planted step name no output may contain.
_jobs() {
  local id="$1" date="$2" red_m="${7:-20}" i=0 o conclusion status start end next
  next="$(date -u -d "${date} + 1 day" +%Y-%m-%d)"
  printf '{"jobs":['
  printf '{"databaseId":%s0,"name":"Derive the slot seeds","status":"completed","conclusion":"success","startedAt":"%sT00:23:10Z","completedAt":"%sT00:24:00Z","url":"u","steps":[{"name":"PLANTED-PROSE"}]}' \
    "${id}" "${date}" "${date}"
  for o in "$3" "$4" "$5" "$6"; do
    i=$((i + 1))
    [[ "${o}" != absent ]] || continue
    status=completed; start="${date}T00:25:00Z"; end="${date}T01:37:00Z"
    case "${o}" in
      green) conclusion='"success"' ;;
      red) conclusion='"failure"'; start="${next}T00:05:00Z"
           end="$(date -u -d "${next}T00:05:00Z + ${red_m} minutes" +%Y-%m-%dT%H:%M:%SZ)" ;;
      cancelled) conclusion='"cancelled"' ;;
      running) conclusion=null; status=in_progress ;;
    esac
    printf ',{"databaseId":%s%s,"name":"Soak Core (nightly, s%s) / e2e_soak_core_nightly","status":"%s","conclusion":%s,"startedAt":"%s","completedAt":"%s","url":"u","steps":[{"name":"PLANTED-PROSE"}]}' \
      "${id}" "${i}" "${i}" "${status}" "${conclusion}" "${start}" "${end}"
  done
  printf ',{"databaseId":%s9,"name":"file-issue","status":"completed","conclusion":"failure","startedAt":"%sT01:40:00Z","completedAt":"%sT01:41:00Z","url":"u","steps":[{"name":"PLANTED-PROSE"}]}' \
    "${id}" "${date}" "${date}"
  printf ']}\n'
}

# _coverage <dir> <first_tick>... — a coverage.log in the shape the rig
# really writes: one probe-round triple per tick, the teardown round's
# `settled` triples at the schedule's last tick, and an ARM triple — the last
# two both at ticks larger than any probe's, and the knee must read neither.
_coverage() {
  mkdir -p "$1"
  local dir="$1" t triples='{"scenario":"S04","nemesis":"down","invariant":"INV-O1","first_tick":5000}'
  shift
  for t in "$@"; do
    triples="${triples},{\"scenario\":\"nemesis\",\"nemesis\":\"swallow-ok\",\"invariant\":\"INV-O1\",\"first_tick\":${t}}"
  done
  triples="${triples},{\"scenario\":\"settled\",\"nemesis\":\"swallow-ok\",\"invariant\":\"INV-O6\",\"first_tick\":8000}"
  printf '{"triples":[%s],"profile":"nightly","seed":"0x0000000000000000"}\n' "${triples}" >"${dir}/coverage.log"
}

# Fixture set F: seven completed scheduled nights in the window, one still
# running, one outside it. Newest first:
#   10-08 running · 10-07 · 10-06 · 10-05 (Mon) · [10-04 a workflow_dispatch
#   repro, s2 red] · 10-03 (Sat) — no scheduled night on the Sunday —
#   10-02 s1 red (run created 23:50, job started 10-03) · 10-01 s3 cancelled ·
#   09-30 · 08-01 (outside the 30-day window).
_fixture_f() { # <dir>
  local d="$1"
  mkdir -p "${d}/art"
  cat >"${d}/runs.json" <<'JSON'
[{"databaseId":900000110,"createdAt":"2026-10-08T00:23:11Z","status":"in_progress"},
 {"databaseId":900000109,"createdAt":"2026-10-07T00:23:04Z","status":"completed"},
 {"databaseId":900000108,"createdAt":"2026-10-06T00:24:40Z","status":"completed"},
 {"databaseId":900000106,"createdAt":"2026-10-05T00:23:30Z","status":"completed"},
 {"databaseId":900000105,"createdAt":"2026-10-04T12:00:00Z","status":"completed","event":"workflow_dispatch"},
 {"databaseId":900000104,"createdAt":"2026-10-03T00:23:30Z","status":"completed"},
 {"databaseId":900000103,"createdAt":"2026-10-02T23:50:02Z","status":"completed"},
 {"databaseId":900000102,"createdAt":"2026-10-01T00:23:00Z","status":"completed"},
 {"databaseId":900000101,"createdAt":"2026-09-30T00:23:00Z","status":"completed"},
 {"databaseId":900000001,"createdAt":"2026-08-01T00:23:00Z","status":"completed"}]
JSON
  _jobs 900000110 2026-10-08 running running running running >"${d}/jobs-900000110.json"
  _jobs 900000109 2026-10-07 green green green green >"${d}/jobs-900000109.json"
  _jobs 900000108 2026-10-06 green green green green >"${d}/jobs-900000108.json"
  _jobs 900000106 2026-10-05 green green green green >"${d}/jobs-900000106.json"
  _jobs 900000105 2026-10-04 green red green green >"${d}/jobs-900000105.json"
  _jobs 900000104 2026-10-03 green green green green >"${d}/jobs-900000104.json"
  _jobs 900000103 2026-10-02 red green green green >"${d}/jobs-900000103.json"
  _jobs 900000102 2026-10-01 green green cancelled green >"${d}/jobs-900000102.json"
  _jobs 900000101 2026-09-30 green green green green >"${d}/jobs-900000101.json"
  # #7 is the red night's issue; #9 names a run whose id EXTENDS 10-07's.
  cat >"${d}/issues.json" <<'JSON'
[{"number":7,"body":"run_url: https://github.com/mehmetefeumit/Haven-App/actions/runs/900000103\nPLANTED-PROSE","comments":[]},
 {"number":9,"body":"run_url: https://github.com/mehmetefeumit/Haven-App/actions/runs/9000001095\nPLANTED-PROSE","comments":[{"body":"run_url: https://github.com/mehmetefeumit/Haven-App/actions/runs/9000001095"}]}]
JSON
  # Coverage window (created after 10-04): 10-07, 10-06, 10-05. Knees 40, 9,
  # 100, 50 → lower median 40 over 4 (the upper would be 50). s3 uploaded no
  # coverage.log, s4 has expired, 10-06's s2 covered no triple, and 10-02 sits
  # outside the window.
  cat >"${d}/art-900000109.json" <<'JSON'
{"total_count":4,"artifacts":[
 {"name":"soak-core-nightly-s1-900000109","expired":false},
 {"name":"soak-core-nightly-s2-900000109","expired":false},
 {"name":"soak-core-nightly-s3-900000109","expired":false},
 {"name":"soak-core-nightly-s4-900000109","expired":true}]}
JSON
  printf '{"total_count":2,"artifacts":[{"name":"soak-core-nightly-s1-900000108","expired":false},{"name":"soak-core-nightly-s2-900000108","expired":false}]}\n' \
    >"${d}/art-900000108.json"
  printf '{"total_count":1,"artifacts":[{"name":"soak-core-nightly-s1-900000106","expired":false}]}\n' \
    >"${d}/art-900000106.json"
  printf '{"total_count":1,"artifacts":[{"name":"soak-core-nightly-s1-900000103","expired":false}]}\n' \
    >"${d}/art-900000103.json"
  _coverage "${d}/art/soak-core-nightly-s1-900000109" 3 40 12
  _coverage "${d}/art/soak-core-nightly-s2-900000109" 5 9
  mkdir -p "${d}/art/soak-core-nightly-s3-900000109"
  printf 'banner\n' >"${d}/art/soak-core-nightly-s3-900000109/banner.log"
  _coverage "${d}/art/soak-core-nightly-s4-900000109" 999
  _coverage "${d}/art/soak-core-nightly-s1-900000108" 100
  _coverage "${d}/art/soak-core-nightly-s2-900000108"
  _coverage "${d}/art/soak-core-nightly-s1-900000106" 50
  _coverage "${d}/art/soak-core-nightly-s1-900000103" 7777
}

# Fixture set M: three nights, s4 ABSENT from every one (its job never ran),
# s2 cancelled on the middle night. No artifacts.
_fixture_m() { # <dir>
  local d="$1"
  mkdir -p "${d}"
  cat >"${d}/runs.json" <<'JSON'
[{"databaseId":800000003,"createdAt":"2026-10-07T00:23:00Z","status":"completed"},
 {"databaseId":800000002,"createdAt":"2026-10-06T00:23:00Z","status":"completed"},
 {"databaseId":800000001,"createdAt":"2026-10-05T00:23:00Z","status":"completed"}]
JSON
  _jobs 800000003 2026-10-07 green green green absent >"${d}/jobs-800000003.json"
  _jobs 800000002 2026-10-06 green cancelled green absent >"${d}/jobs-800000002.json"
  _jobs 800000001 2026-10-05 green green green absent >"${d}/jobs-800000001.json"
  printf '[]\n' >"${d}/issues.json"
}

# Fixture set C: s1 red on two nights under one key. Night one CREATED #7;
# night two COMMENTED on it (file_soak_issue.sh's repeated-key path) and also
# created #8 for a second key. No artifacts.
_fixture_c() { # <dir>
  local d="$1"
  mkdir -p "${d}"
  cat >"${d}/runs.json" <<'JSON'
[{"databaseId":700000002,"createdAt":"2026-10-07T00:23:00Z","status":"completed"},
 {"databaseId":700000001,"createdAt":"2026-10-06T00:23:00Z","status":"completed"}]
JSON
  _jobs 700000002 2026-10-07 red green green green >"${d}/jobs-700000002.json"
  _jobs 700000001 2026-10-06 red green green green >"${d}/jobs-700000001.json"
  cat >"${d}/issues.json" <<'JSON'
[{"number":7,"body":"run_url: https://github.com/mehmetefeumit/Haven-App/actions/runs/700000001","comments":[{"body":"PLANTED-PROSE"},{"body":"run_url: https://github.com/mehmetefeumit/Haven-App/actions/runs/700000002"}]},
 {"number":8,"body":"run_url: https://github.com/mehmetefeumit/Haven-App/actions/runs/700000002","comments":[]}]
JSON
}

self_test() {
  local tmp fails=0 n=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _ok() { # <0-if-passed> <label> [detail-file]
    n=$((n + 1))
    if [[ "$1" == 0 ]]; then
      printf '  PASS %s\n' "$2"
      return 0
    fi
    printf '  FAIL %s\n' "$2" >&2
    [[ -z "${3:-}" || ! -s "${3:-}" ]] || sed 's/^/        | /' "$3" >&2
    fails=1
  }
  _c() { if eval "$1"; then echo 0; else echo 1; fi; }

  local missing='' b
  for b in jq sha256sum date; do command -v "${b}" >/dev/null 2>&1 || missing="${missing} ${b}"; done
  if [[ -n "${missing}" ]]; then
    printf '%s --self-test: FAILED —%s absent; nothing was checked.\n' "${SCRIPT_NAME}" "${missing}" >&2
    return 1
  fi

  local bin="${tmp}/bin" calls="${tmp}/calls" out="${tmp}/section.md" std="${tmp}/stdout" err="${tmp}/stderr"
  mkdir -p "${bin}"
  _write_gh_stub "${bin}"
  local rc=0
  _drive() { # <fixture-dir> [NAME=VALUE ...] — main against the stub; rc in ${rc}
    local fix="$1" kv
    shift
    : >"${calls}"; : >"${std}"; : >"${err}"
    rc=0
    ( export PATH="${bin}:${PATH}" STUB_CALLS="${calls}" STUB_FIX="${fix}" \
             GITHUB_REPOSITORY='mehmetefeumit/Haven-App' GITHUB_SERVER_URL='https://github.com' \
             GH_TOKEN=stub
      for kv in "$@"; do export "${kv?}"; done
      main --out "${out}" --since 2026-09-10T00:00:00Z --coverage-since 2026-10-04T00:00:00Z
    ) >"${std}" 2>"${err}" || rc=$?
  }

  local run='https://github.com/mehmetefeumit/Haven-App/actions/runs'
  local s1_latest s2_latest s3_latest
  s1_latest="$(bash "${SEED_SCRIPT}" --seed nightly 2026-10-07 s1 2>/dev/null || true)"
  s2_latest="$(bash "${SEED_SCRIPT}" --seed nightly 2026-10-07 s2 2>/dev/null || true)"
  s3_latest="$(bash "${SEED_SCRIPT}" --seed nightly 2026-10-07 s3 2>/dev/null || true)"

  printf 'self-test: %s\n' "${SCRIPT_NAME}"
  printf -- '--- the seed: one definition, a fixed vector ---\n'
  # (V1) The vector was computed OUTSIDE this script and outside soak_seed.sh,
  #      by python3's hashlib over "nightly|2026-10-02|s1", so neither script
  #      can satisfy it with the bug that produced it. It is asserted against
  #      the REAL soak_seed.sh — the one CI calls — never a stand-in.
  _ok "$(_c '[[ "$(bash "${SEED_SCRIPT}" --seed nightly 2026-10-02 s1 2>/dev/null)" == 0x6bba5996881bf6df ]]')" \
      '(V1) the real soak_seed.sh derives the fixed vector 0x6bba5996881bf6df'
  # (V2) The slots this section expects are exactly the ones soak_seed.sh
  #      will derive: a fifth slot it refuses would be a row no night can fill.
  load_slots
  local vocab=0 s
  for s in "${SLOTS[@]}"; do bash "${SEED_SCRIPT}" --seed nightly 2026-10-02 "${s}" >/dev/null 2>&1 || vocab=1; done
  bash "${SEED_SCRIPT}" --seed nightly 2026-10-02 "s$(( ${#SLOTS[@]} + 1 ))" >/dev/null 2>&1 && vocab=1
  _ok "${vocab}" '(V2) soak_seed.sh derives every scheduled slot and refuses the next one'

  printf -- '--- fixture set F: seven nights, one red, one cancelled, one running ---\n'
  : >"${out}"
  _fixture_f "${tmp}/f"
  _drive "${tmp}/f"
  _ok "$(_c '[[ ${rc} == 0 ]]')" '(F1) the section is written, rc 0' "${err}"
  _ok "$(_c "grep -qxF '| \`Soak Core (nightly, s1) / e2e_soak_core_nightly\` | 7 | 1 | 4 | \`${s1_latest}\` | 2026-10-02 · \`0x6bba5996881bf6df\` · [run](${run}/900000103) | 72 |' '${out}'")" \
      '(F2) s1: seven nights, one red, streak four, the red night'"'"'s derived seed and link' "${out}"
  _ok "$(_c "grep -qxF '| \`Soak Core (nightly, s3) / e2e_soak_core_nightly\` | 6 | 0 | 5 | \`${s3_latest}\` | none | 72 |' '${out}'")" \
      '(F3) s3: a cancelled night is neither green nor red, and ends its streak' "${out}"
  _ok "$(_c "grep -qxF '| \`Soak Core (nightly, s2) / e2e_soak_core_nightly\` | 7 | 0 | 7 | \`${s2_latest}\` | none | 72 |' '${out}'")" \
      '(F4) s2: the running night and the out-of-window night are not counted' "${out}"
  _ok "$(_c "grep -qxF 'consecutive all-slot-green nights: 4' '${out}'")" \
      '(F5) the red slot ends the all-slot streak; the Sunday gap does not' "${out}"
  _ok "$(_c "grep -qxF '| 2026-10-02 | [run](${run}/900000103) | red | green | green | green | #7 |' '${out}'")" \
      '(F6) the red night links the issue whose body names its run' "${out}"
  _ok "$(_c "grep -qxF '| 2026-10-07 | [run](${run}/900000109) | green | green | green | green | — |' '${out}'")" \
      '(F7) a run URL that is a PREFIX of another run'"'"'s links nothing' "${out}"
  _ok "$(_c "grep -qxF '| 2026-10-08 | [run](${run}/900000110) | running | running | running | running | — |' '${out}'")" \
      '(F8) a night still running is listed and outside every count' "${out}"
  _ok "$(_c "! grep -q 'run view 900000001' '${calls}'")" \
      '(F9) a run outside the window is never read' "${calls}"
  # (F10) The red job started on 10-03; its run was created on 10-02. Only the
  #       run's date is what `prepare` derived from.
  _ok "$(_c "! grep -qF '$(bash "${SEED_SCRIPT}" --seed nightly 2026-10-03 s1 2>/dev/null || echo unreachable)' '${out}'")" \
      '(F10) the seed comes from the run'"'"'s created_at, never the job'"'"'s start' "${out}"
  _ok "$(_c "! grep -q 'attempts' '${calls}'")" \
      '(F11) no /attempts/ endpoint is ever read' "${calls}"
  _ok "$(_c "grep -qF 'median tick 40 over 4 slot-nights' '${out}'")" \
      '(F12) the knee is the lower median of each slot-night'"'"'s last probe-round tick, never the teardown round'"'"'s or an arm'"'"'s' "${out}"
  _ok "$(_c "! grep -qE 'run download (900000103|900000109 -n soak-core-nightly-s4)' '${calls}'")" \
      '(F13) nothing older than the 14-day window, and nothing expired, is downloaded' "${calls}"
  _ok "$(_c "! grep -qiE 'flake|%|target|PLANTED-PROSE|T[0-9]{2}:[0-9]{2}|${tmp}' '${out}'")" \
      '(F14) no rate, no goal, no remote text, no time of day, no path' "${out}"
  _ok "$(_c "[[ ! -s '${std}' ]]")" '(F15) nothing is printed to stdout' "${std}"
  _ok "$(_c "! grep -q 900000105 '${out}' '${calls}'")" \
      '(F17) a workflow_dispatch repro is not a night: never read, never counted' "${out}"
  _ok "$(_c "grep -qF 'due after 30 scheduled nights; 8 completed so far' '${out}'")" \
      '(F16) the 30-night review counts every completed night, the window aside' "${out}"

  printf -- '--- fixture set M: a slot that never ran ---\n'
  : >"${out}"
  _fixture_m "${tmp}/m"
  _drive "${tmp}/m"
  _ok "$(_c "[[ ${rc} == 0 ]] && grep -qxF 'consecutive all-slot-green nights: 0' '${out}'")" \
      '(M1) an absent slot is not green: three three-slot nights are a streak of 0' "${out}"
  _ok "$(_c "grep -qxF '| \`Soak Core (nightly, s4) / e2e_soak_core_nightly\` | no decided night in the window | — | 0 | — | — | — |' '${out}'")" \
      '(M2) a slot with no decided night says so, with no division' "${out}"
  _ok "$(_c "grep -qF '| \`Soak Core (nightly, s2) / e2e_soak_core_nightly\` | 2 | 0 | 1 |' '${out}'")" \
      '(M3) a cancelled slot ends that slot'"'"'s streak' "${out}"
  _ok "$(_c "grep -qF 'Coverage knee (14-day window, the artifact retention): not computed' '${out}'")" \
      '(M4) no coverage.log in the window reads "not computed"' "${out}"

  printf -- '--- fixture set C: a repeated key is a comment, and still linked ---\n'
  : >"${out}"
  _fixture_c "${tmp}/c"
  _drive "${tmp}/c"
  _ok "$(_c "[[ ${rc} == 0 ]] && grep -qxF '| 2026-10-06 | [run](${run}/700000001) | red | green | green | green | #7 |' '${out}'")" \
      '(C1) the first red night links the issue it created' "${out}"
  _ok "$(_c "grep -qxF '| 2026-10-07 | [run](${run}/700000002) | red | green | green | green | #7 #8 |' '${out}'")" \
      '(C2) the second night links the issue it COMMENTED on, and every other issue naming it' "${out}"
  jq '.[0].comments = [range(100) | {"body": "PLANTED-PROSE"}]' "${tmp}/c/issues.json" >"${tmp}/c/full.json"
  mv "${tmp}/c/full.json" "${tmp}/c/issues.json"
  printf 'prior report content\n' >"${out}"
  _drive "${tmp}/c"
  _ok "$(_c "[[ ${rc} == 2 && \"\$(cat '${out}')\" == 'prior report content' ]] && grep -qF 'full page of comments' '${err}'")" \
      '(C3) an issue at gh'"'"'s 100-comment page is refused: a night past it would read as unlinked' "${err}"

  printf -- '--- the scheduled slot count is soak_seed.sh'"'"'s ---\n'
  # (D1) The documented lever for a two-slot night is DEFAULT_SLOTS in
  #      soak_seed.sh. Against set M (s4 never ran, s2 cancelled on the middle
  #      night) a two-slot schedule has a streak of 1 and no s3/s4 row; a list
  #      kept in this script would still say 0.
  local two="${tmp}/two"
  mkdir -p "${two}"
  cp "${BASH_SOURCE[0]}" "${two}/soak_monitor_section.sh"
  sed 's/^readonly DEFAULT_SLOTS=.*/readonly DEFAULT_SLOTS=2/' "${SEED_SCRIPT}" >"${two}/soak_seed.sh"
  _drive_copy() { # <copy-dir> <fixture-dir>
    : >"${out}"; : >"${std}"; : >"${err}"
    rc=0
    ( export PATH="${bin}:${PATH}" STUB_CALLS="${calls}" STUB_FIX="$2" \
             GITHUB_REPOSITORY='mehmetefeumit/Haven-App' GH_TOKEN=stub
      bash "$1/soak_monitor_section.sh" --out "${out}" \
        --since 2026-09-10T00:00:00Z --coverage-since 2026-10-04T00:00:00Z
    ) >"${std}" 2>"${err}" || rc=$?
  }
  _drive_copy "${two}" "${tmp}/m"
  _ok "$(_c "[[ ${rc} == 0 ]] && grep -qxF 'consecutive all-slot-green nights: 1' '${out}' && ! grep -q 'nightly, s3' '${out}' && grep -qxF '| Night | Run | s1 | s2 | Issue |' '${out}'")" \
      '(D1) DEFAULT_SLOTS=2 in soak_seed.sh makes a night two slots here too' "${out}"
  # (D2) …and a soak_seed.sh that no longer declares it is refused, not
  #      guessed at.
  sed '/^readonly DEFAULT_SLOTS=/d' "${SEED_SCRIPT}" >"${two}/soak_seed.sh"
  _drive_copy "${two}" "${tmp}/m"
  _ok "$(_c "[[ ${rc} == 2 && ! -s '${out}' ]] && grep -qF 'DEFAULT_SLOTS' '${err}'")" \
      '(D2) no DEFAULT_SLOTS in soak_seed.sh is exit 2 and writes nothing' "${err}"
  # (D3) …and a list that is not s1..sN is refused too: the monitor asks
  #      soak_seed.sh, and a malformed answer is not a slot set.
  sed 's/^  --default-slots) .*$/  --default-slots) printf "s1\\ns1\\n" ;;/' "${SEED_SCRIPT}" >"${two}/soak_seed.sh"
  _drive_copy "${two}" "${tmp}/m"
  _ok "$(_c "[[ ${rc} == 2 && ! -s '${out}' ]] && grep -qF 'not a slot list' '${err}'")" \
      '(D3) a --default-slots answer naming a slot twice is exit 2 and writes nothing' "${err}"

  printf -- '--- empty windows ---\n'
  mkdir -p "${tmp}/none"
  printf '[]\n' >"${tmp}/none/runs.json"
  : >"${out}"
  _drive "${tmp}/none"
  _ok "$(_c "[[ ${rc} == 0 ]] && grep -qxF '## Soak Nightly' '${out}' && grep -qF '_No nights yet' '${out}' && ! grep -q '^| ' '${out}'")" \
      '(E1) no night yet: the section, the line that says so, rc 0, no row' "${out}"
  mkdir -p "${tmp}/old"
  local i
  { printf '['
    for i in $(seq 1 30); do
      printf '%s{"databaseId":%s,"createdAt":"2026-01-%02dT00:23:00Z","status":"completed"}' \
        "$([[ ${i} == 1 ]] || echo ,)" "$((700000000 + i))" "${i}"
    done
    printf ']\n'; } >"${tmp}/old/runs.json"
  : >"${out}"
  _drive "${tmp}/old"
  _ok "$(_c "[[ ${rc} == 0 ]] && grep -qF 'No scheduled night in the window' '${out}' && grep -qF 'review: **due** — the 30th scheduled night completed on 2026-01-30' '${out}'")" \
      '(E2) silence reads as silence, and the 30th night makes the review due' "${out}"

  printf -- '--- fail closed ---\n'
  local stale='prior report content'
  _refused() { # <STUB_REFUSE> <label> <stderr-substring>
    printf '%s\n' "${stale}" >"${out}"
    _drive "${tmp}/f" "STUB_REFUSE=$1"
    _ok "$(_c "[[ ${rc} == 3 && \"\$(cat '${out}')\" == '${stale}' ]] && grep -qF '$3' '${err}'")" "$2" "${err}"
  }
  _refused list '(G1) a refused run list is exit 3, and the report is untouched' 'the Soak Nightly run list'
  _refused view '(G2) a refused job list is exit 3 with no partial row' 'a Soak Nightly job list'
  _refused issues '(G3) a refused issue list is exit 3' 'the soak issue list'
  _refused download '(G4) a refused artifact download is exit 3, never a skipped night' 'an artifact download'
  _refused api '(G5) a refused artifact LIST is exit 3, never a night with no knee' 'an artifact list'

  printf -- '--- refused inputs ---\n'
  cp -R "${tmp}/f" "${tmp}/bad"
  printf '{"triples":[{"scenario":"s04","nemesis":"n","invariant":"INV-S1","first_tick":"12"}],"profile":"nightly","seed":"0x0000000000000000"}\n' \
    >"${tmp}/bad/art/soak-core-nightly-s1-900000109/coverage.log"
  printf '%s\n' "${stale}" >"${out}"
  _drive "${tmp}/bad"
  _ok "$(_c "[[ ${rc} == 2 && \"\$(cat '${out}')\" == '${stale}' ]] && grep -qF 'off its schema' '${err}'")" \
      '(R1) a quoted first_tick is off the schema: exit 2, never a quietly smaller knee' "${err}"
  printf '{"triples":[{"scenario":"s04","nemesis":"n","invariant":"INV-S1","first_tick":-3}],"profile":"nightly","seed":"0x0000000000000000"}\n' \
    >"${tmp}/bad/art/soak-core-nightly-s1-900000109/coverage.log"
  printf '%s\n' "${stale}" >"${out}"
  _drive "${tmp}/bad"
  _ok "$(_c "[[ ${rc} == 2 && \"\$(cat '${out}')\" == '${stale}' ]] && grep -qF 'off its schema' '${err}'")" \
      '(R1b) a negative first_tick is off the schema too: a tick is relative, never before the run' "${err}"
  rc=0
  ( main --since 2026-09-10T00:00:00Z --coverage-since 2026-10-04T00:00:00Z ) >"${std}" 2>"${err}" || rc=$?
  _ok "$(_c "[[ ${rc} == 2 && ! -s '${std}' ]]")" '(R2) without --out the section is refused, never printed' "${err}"

  printf '\n'
  if ((fails != 0)); then
    printf '%s --self-test: FAILED.\n' "${SCRIPT_NAME}" >&2
    return 1
  fi
  if ((n != SELF_TEST_FIXTURES)); then
    printf '%s --self-test: ran %d fixture(s), expected exactly %d. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success.\n' \
      "${SCRIPT_NAME}" "${n}" "${SELF_TEST_FIXTURES}" >&2
    return 1
  fi
  printf 'OK: %s --self-test passed (%d/%d fixtures).\n' "${SCRIPT_NAME}" "${n}" "${SELF_TEST_FIXTURES}"
}

case "${1:-}" in
  --self-test) self_test ;;
  -h|--help)   sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' ;;
  *)           main "$@" ;;
esac
