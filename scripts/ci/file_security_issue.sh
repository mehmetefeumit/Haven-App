#!/usr/bin/env bash
# The nightly dependency scan's issues: one open issue per finding, closed when
# the finding is gone — and never closed on the word of a scan that did not
# finish.
#
# security-nightly.yml scans main (audit.yml, `full`) and the latest release
# tag's lockfiles. Each scan job uploads an artifact holding `findings.tsv` —
# the `<key>\t<summary>` lines every gate appends to SECURITY_FINDINGS_OUT — and
# `steps.json`, the job's `toJSON(steps)`. A finding's issue is titled
# `[dependency-security] <key> (<ref>)`: the key names the advisory, package
# and version, the ref names main or the tag, and nothing that changes from
# night to night (a run id, a summary) is in it, so the exact title is the
# de-duplication and no comment is ever needed to keep an issue open.
#
# Closing is where a wrong answer costs: an issue closed because a scanner
# crashed tells the owner an advisory is fixed when it is not. So a run closes
# issues only when every scan reached a verdict, which this reads from the
# step outcomes, not from the job's colour (a gate that found something fails
# exactly as one that crashed does):
#   - a scan with no artifact did not finish;
#   - a gate step that failed must have filed a finding of its own kind
#     (GATE_PREFIXES; cargo-audit's RustSec findings are osv-scanner's too,
#     since osv-scanner reads RustSec), or it failed for another reason —
#     exit 2, a tool that did not install;
#   - any other step that failed, any step that was skipped or cancelled, and
#     a failed job none of whose steps failed (audit.yml's cargo-audit job is
#     not in the artifact) all mean the same.
# Such a run files, or keeps open, one `[dependency-security] nightly run
# failed` issue instead, and still files every finding it did read. A run that
# reached every verdict closes the issue of each finding it no longer reports
# (a release tag's issues close when a newer release no longer carries the
# finding) and the run-failed issue. Only titles of this shape are touched; a
# person's issue under the same label is left alone.
#
# Every value that reaches an issue is a key off its shape refusal-checked
# here, a ref or step id checked the same way, or an advisory summary from
# public advisory data, which goes in a fenced block with its backticks
# replaced, so it can neither mention anyone nor break out of the block.
#
# It also prepares the release scan, because that is where "the tag's
# lockfiles" is defined: --latest-release prints the latest published
# non-prerelease release's tag (nothing when the repository has none), and
# --materialise copies exactly the tag's committed Cargo.lock, pubspec.lock and
# Gemfile.lock files out of its checkout, so the scanners read the lockfiles
# the release was built from and nothing else in its tree.
#
# Usage:
#   file_security_issue.sh [--file] --scan <ref> <artifact dir> <job result> [--scan ...]
#       <ref> empty means the release scan found no release (only valid with
#       result success). Without --file it prints what it would do and makes no
#       `gh` call; security-nightly.yml passes --file on main only.
#   file_security_issue.sh --latest-release        # GH_TOKEN, GH_REPO
#   file_security_issue.sh --materialise <tag checkout> <empty dest dir>
#   file_security_issue.sh --self-test             # stubbed gh, temporary repos
#
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID — the run the issues
#   link to, as every Actions step already has them.
#
# The label `dependency-security` must exist: `gh` refuses to create an issue
# carrying a label it cannot resolve, and that refusal is an exit 2 naming it.
#
# Exit codes:
#   0  every scan reached a verdict, and its issues are filed (or, without
#      --file, planned); a finding is not a failure here, its gate already
#      failed the run
#   1  a scan did not reach a verdict; the run-failed issue is filed (or
#      planned); nothing was closed
#   2  refused: a bad argument, a `gh` call that failed, an issue listing that
#      is malformed, fills its page or holds one title twice

# Backticks in single quotes here are Markdown, never an expansion.
# shellcheck disable=SC2016
set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly LABEL='dependency-security'
readonly RUN_FAILED_TITLE="[${LABEL}] nightly run failed"
readonly LIST_LIMIT=200
readonly LOCKFILE_NAMES='Cargo.lock pubspec.lock Gemfile.lock'

# Which finding a failed gate step must have filed, by step id (audit.yml's
# `advisories` job and security-nightly.yml's release-tag-scan job).
declare -rA GATE_PREFIXES=(
  [osv]='osv:'
  [pub]='retracted:'
  [watcher]='watcher:'
  [ledger]='ledger-'
  [cargo-audit]='osv:RUSTSEC-'
)

readonly RE_ID='[A-Za-z0-9][A-Za-z0-9-]*'
readonly RE_PKG='[A-Za-z0-9][A-Za-z0-9._+-]*'
readonly RE_VER='[0-9A-Za-z][0-9A-Za-z.+~-]*'
readonly RE_KEY="^((osv|watcher):${RE_ID}:${RE_PKG}@${RE_VER}|retracted:${RE_PKG}@${RE_VER}|ledger-(expiring|expired|stale):${RE_ID})$"
readonly RE_REF='^[A-Za-z0-9][A-Za-z0-9._+/-]{0,99}$'
readonly RE_TAG='^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$'
readonly RE_STEP='^[A-Za-z_][A-Za-z0-9_-]{0,99}$'
readonly RE_MANAGED='^\[dependency-security\] [^ ()]+ \([^ ()]+\)$'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=29

# stdout is --latest-release's answer, so everything else goes to stderr.
log() {
  printf '\033[1;34m[file_security_issue]\033[0m %s\n' "$*" >&2
}

refuse() {
  printf '\033[1;31m[file_security_issue] REFUSED:\033[0m %s\n' "$*" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Reading the scans.
# ---------------------------------------------------------------------------
declare -a INCOMPLETE=() TITLES=()
declare -A KEY_OF=() REF_OF=() SUMMARY_OF=()

incomplete() { INCOMPLETE+=("$*"); }

record() { # <key> <ref> <summary>
  local title="[${LABEL}] $1 ($2)"
  [[ -n "${KEY_OF[${title}]+x}" ]] && return 0
  TITLES+=("${title}")
  KEY_OF["${title}"]="$1"; REF_OF["${title}"]="$2"; SUMMARY_OF["${title}"]="$3"
}

classify() { # <ref> <artifact dir> <job result>
  local ref="$1" dir="$2" result="$3"
  if [[ -z "${ref}" ]]; then
    [[ "${result}" == success ]] \
      || incomplete "the release-tag scan ended \`${result}\` before it named a release"
    return 0
  fi
  if [[ ! -f "${dir}/steps.json" || ! -f "${dir}/findings.tsv" ]]; then
    incomplete "\`${ref}\`: the scan job (\`${result}\`) left no findings artifact"
    return 0
  fi
  local rows
  if ! rows="$(jq -r 'if type == "object" then to_entries[] | [.key, (.value.outcome | if type == "string" then . else "" end)] | @tsv else error end' \
      "${dir}/steps.json" 2>/dev/null)"; then
    incomplete "\`${ref}\`: the step outcomes are unreadable"
    return 0
  fi

  local line key summary
  local -a keys=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    key="${line%%$'\t'*}"
    summary=''
    [[ "${line}" != *$'\t'* ]] || summary="${line#*$'\t'}"
    if [[ ! "${key}" =~ ${RE_KEY} ]]; then
      incomplete "\`${ref}\`: a finding whose key is off its shape"
      continue
    fi
    keys+=("${key}")
    record "${key}" "${ref}" "${summary}"
  done <"${dir}/findings.tsv"

  local id outcome prefix k failed=0 explained
  while IFS=$'\t' read -r id outcome; do
    [[ -n "${id}" ]] || continue
    [[ "${id}" =~ ${RE_STEP} ]] || { incomplete "\`${ref}\`: a step id off its shape"; continue; }
    case "${outcome}" in
      success) ;;
      failure)
        failed=1
        prefix="${GATE_PREFIXES[${id}]:-}"
        explained=0
        if [[ -n "${prefix}" ]]; then
          for k in "${keys[@]}"; do [[ "${k}" == "${prefix}"* ]] && { explained=1; break; }; done
        fi
        (( explained )) || incomplete "\`${ref}\`: step \`${id}\` failed without filing a finding"
        ;;
      *) incomplete "\`${ref}\`: step \`${id}\` did not run (\`${outcome:-no outcome}\`)" ;;
    esac
  done <<<"${rows}"

  [[ "${result}" == success || "${failed}" == 1 ]] \
    || incomplete "\`${ref}\`: the scan job ended \`${result}\` with no gate step failing (a job or step outside its gates failed)"
}

# ---------------------------------------------------------------------------
# Composing.
# ---------------------------------------------------------------------------
remedy() { # <key>
  case "$1" in
    osv:*|watcher:*)
      printf '%s\n' "Update the lockfile to a version outside the advisory's range; a release tag's finding is fixed on main and shipped by the next release." \
        "If no fixed version exists, acknowledge it in \`osv-scanner.toml\`: a \`reason\` carrying \`owner-decision: YYYY-MM-DD\`, why it is acceptable and what lifts it, and an \`effectiveUntil\` at most 90 days out (\`scripts/ci/check_ledger.sh\` holds the rules)." ;;
    retracted:*)
      printf '%s\n' "Re-lock to a version that is not retracted. A retraction is never acknowledgeable: a non-retracted version always exists." ;;
    ledger-stale:*)
      printf '%s\n' "Remove the entry from \`osv-scanner.toml\` (and its mirror in \`haven-core/.cargo/audit.toml\`): it matches nothing the scanners report, and would silence the advisory if it came back." ;;
    ledger-*)
      printf '%s\n' "Re-decide the acknowledgement in \`osv-scanner.toml\`: lift it by updating the lockfile, or renew it with a new \`owner-decision\` date and an \`effectiveUntil\` at most 90 days out." ;;
  esac
}

compose() { # <title> <body file>
  local title="$1" key="${KEY_OF[$1]}" ref="${REF_OF[$1]}" summary="${SUMMARY_OF[$1]}"
  local kind="${key%%:*}" rest="${key#*:}" advisory='' package=''
  case "${kind}" in
    osv|watcher) advisory="${rest%%:*}"; package="${rest#*:}" ;;
    retracted) package="${rest}" ;;
    *) advisory="${rest}" ;;
  esac
  summary="$(LC_ALL=C tr -d '\000-\010\013-\037\177' <<<"${summary//\`/\'}")"
  {
    printf 'Reported by the nightly dependency scan of `%s`.\n\n' "${ref}"
    printf -- '- Finding: `%s`\n' "${key}"
    [[ -z "${advisory}" ]] || printf -- '- Advisory: `%s`\n' "${advisory}"
    [[ -z "${package}" ]] || printf -- '- Package: `%s` version `%s`\n' "${package%@*}" "${package##*@}"
    printf -- '- Ref: `%s`\n' "${ref}"
    printf -- '- Run: %s\n\n' "${RUN_URL}"
    printf 'Scanner summary:\n\n```text\n%s\n```\n\n' "${summary:0:400}"
    remedy "${key}"
    printf '\nThis issue closes itself on the first complete nightly run that no longer reports the finding.\n'
  } >"$2"
}

compose_run_failed() { # <body file>
  {
    printf 'The nightly dependency scan did not reach a verdict for every scanner, so no finding issue was closed.\n\n'
    printf -- '- Run: %s\n\n' "${RUN_URL}"
    printf -- '- %s\n' "${INCOMPLETE[@]}"
    printf '\nThis issue closes itself on the first nightly run in which every scanner reaches a verdict.\n'
  } >"$1"
}

# ---------------------------------------------------------------------------
# Filing.
# ---------------------------------------------------------------------------
file_all() { # <file 0|1> <work dir>
  local file="$1" work="$2" open="$2/open.json" n title i
  local -A wanted=()
  local -a want=("${TITLES[@]}")
  (( ${#INCOMPLETE[@]} == 0 )) || want+=("${RUN_FAILED_TITLE}")
  for title in "${want[@]}"; do wanted["${title}"]=1; done

  if (( ! file )); then
    for title in "${want[@]}"; do log "would file or keep open: ${title}"; done
    (( ${#INCOMPLETE[@]} )) || log "would close every other open ${LABEL} issue of this shape, and the run-failed issue"
    return 0
  fi

  gh issue list --label "${LABEL}" --state open --limit "${LIST_LIMIT}" --json number,title >"${open}" \
    || refuse "the open-issue listing failed"
  n="$(jq 'if type == "array" and all(.[]; (.number | type) == "number" and (.title | type) == "string") then length else error end' "${open}" 2>/dev/null)" \
    || refuse "the open-issue listing is not a list of issues"
  (( n < LIST_LIMIT )) || refuse "the open-issue listing filled its page, which is not a de-duplication"

  i=0
  for title in "${want[@]}"; do
    i=$(( i + 1 ))
    local -a numbers=()
    mapfile -t numbers < <(jq -r --arg t "${title}" '.[] | select(.title == $t) | .number' "${open}")
    case "${#numbers[@]}" in
      0)
        if [[ "${title}" == "${RUN_FAILED_TITLE}" ]]; then compose_run_failed "${work}/body.${i}"; else compose "${title}" "${work}/body.${i}"; fi
        gh issue create --title "${title}" --body-file "${work}/body.${i}" --label "${LABEL}" >/dev/null \
          || refuse "creating '${title}' failed — does the label '${LABEL}' exist? The owner creates it once (Issues → Labels)."
        log "filed: ${title}" ;;
      1) log "still open, kept: ${title} (#${numbers[0]})" ;;
      *) refuse "more than one open issue is titled '${title}' — a broken de-duplication, never another issue" ;;
    esac
  done

  if (( ${#INCOMPLETE[@]} )); then
    log "not closing anything: a scan did not reach a verdict"
    return 0
  fi
  local number
  while IFS=$'\t' read -r number title; do
    [[ -n "${number}" ]] || continue
    [[ "${title}" =~ ${RE_MANAGED} || "${title}" == "${RUN_FAILED_TITLE}" ]] || continue
    [[ -z "${wanted[${title}]+x}" ]] || continue
    gh issue close "${number}" --comment "Not reported by the complete nightly run ${RUN_URL}; closing. A recurrence opens a new issue." >/dev/null \
      || refuse "closing #${number} failed"
    log "closed: ${title} (#${number})"
  done < <(jq -r '.[] | [.number, .title] | @tsv' "${open}")
}

run() {
  local file=0 ref dir result work
  (( $# )) || refuse "usage: --scan <ref> <dir> <result> [--scan ...] [--file]"
  while (( $# )); do
    case "$1" in
      --file) file=1; shift ;;
      --scan)
        (( $# >= 4 )) || refuse "--scan needs <ref> <dir> <result>"
        ref="$2" dir="$3" result="$4"; shift 4
        [[ -z "${ref}" || "${ref}" =~ ${RE_REF} ]] || refuse "a --scan ref is off its shape"
        [[ "${result}" =~ ^(success|failure|cancelled|skipped)$ ]] || refuse "a --scan job result is not success, failure, cancelled or skipped"
        classify "${ref}" "${dir}" "${result}" ;;
      *) refuse "unknown argument (see the header)" ;;
    esac
  done
  [[ "${GITHUB_SERVER_URL:-}" =~ ^https://[A-Za-z0-9.-]+$ && "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
     && "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]{0,19}$ ]] || refuse "GITHUB_SERVER_URL, GITHUB_REPOSITORY and GITHUB_RUN_ID do not name a run"
  RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" EXIT
  file_all "${file}" "${work}"
  if (( ${#INCOMPLETE[@]} )); then
    printf '  %s\n' "${INCOMPLETE[@]}" >&2
    log "the run did not reach a verdict for every scan; ${#TITLES[@]} finding(s) read"
    return 1
  fi
  log "OK: every scan reached a verdict; ${#TITLES[@]} finding(s)"
}

# ---------------------------------------------------------------------------
# Preparing the release scan.
# ---------------------------------------------------------------------------
latest_release() {
  local err tag
  [[ "${GH_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse "GH_REPO does not name a repository"
  err="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${err}'" RETURN
  # /releases/latest is GitHub's latest release: published, never a draft or a
  # pre-release. It answers 404 when there is none.
  if tag="$(gh api "repos/${GH_REPO}/releases/latest" --jq '.tag_name' 2>"${err}")"; then
    [[ "${tag}" =~ ${RE_TAG} ]] || refuse "the latest release's tag is off its shape"
    log "latest release: ${tag}"
    printf '%s\n' "${tag}"
  elif grep -qF 'HTTP 404' "${err}"; then
    log "no published release: nothing to scan"
  else
    sed 's/^/  /' "${err}" >&2
    refuse "GitHub did not answer for the latest release"
  fi
}

materialise() { # <tag checkout> <empty dest dir>
  local src="$1" dest="$2" mode type rel n=0
  [[ -d "${dest}" && -z "$(ls -A "${dest}")" ]] || refuse "--materialise needs an empty destination directory"
  git -C "${src}" rev-parse -q --verify 'HEAD^{commit}' >/dev/null || refuse "--materialise: ${src} is not a checkout"
  # Regular blobs only, read from the commit: a symlink's blob is its target's
  # path, and the working tree is not what the tag committed.
  while IFS=$' \t' read -r -d '' mode type _ rel; do
    [[ "${type}" == blob && ( "${mode}" == 100644 || "${mode}" == 100755 ) ]] || continue
    [[ " ${LOCKFILE_NAMES} " == *" ${rel##*/} "* ]] || continue
    mkdir -p "${dest}/$(dirname "${rel}")"
    git -C "${src}" show "HEAD:${rel}" >"${dest}/${rel}"
    n=$(( n + 1 ))
  done < <(git -C "${src}" ls-tree -r -z HEAD)
  (( n > 0 )) || refuse "--materialise: the tag commits no lockfile"
  log "materialised ${n} committed lockfile(s)"
}

# ---------------------------------------------------------------------------
# Self-test. steps.*.json are in the shape of the `toJSON(steps)` the two scan
# jobs save; findings.tsv holds one line of each kind the gates write.
# ---------------------------------------------------------------------------
self_test() {
  local fx="${REPO_ROOT}/scripts/ci/fixtures/dependency-security/issues" tmp checked=0 fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local self="${BASH_SOURCE[0]}" bin="${tmp}/bin" calls="${tmp}/calls" openf="${tmp}/open.json"
  mkdir -p "${bin}" "${tmp}/bodies"
  # A stateful gh: a create adds to the list the next listing serves, a close
  # removes from it, so "the second night keeps the issue" is driven, not
  # asserted.
  cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_CALLS}"
case "$1 $2" in
  "issue list") jq -c . "${STUB_OPEN}" ;;
  "issue create")
    [[ -z "${STUB_CREATE_FAIL:-}" ]] || { echo "could not add label: 'dependency-security' not found" >&2; exit 1; }
    title='' body=''
    while (( $# )); do case "$1" in --title) title="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;; *) shift ;; esac; done
    n=$(( $(jq '[.[].number] | max // 0' "${STUB_OPEN}") + 1 ))
    cp "${body}" "${STUB_BODIES}/${n}"
    jq --arg t "${title}" --argjson n "${n}" '. + [{number: $n, title: $t}]' "${STUB_OPEN}" >"${STUB_OPEN}.next"
    mv "${STUB_OPEN}.next" "${STUB_OPEN}" ;;
  "issue close")
    jq --argjson n "$3" 'map(select(.number != $n))' "${STUB_OPEN}" >"${STUB_OPEN}.next"
    mv "${STUB_OPEN}.next" "${STUB_OPEN}" ;;
  "api repos/o/r/releases/latest")
    case "${STUB_RELEASE}" in
      none) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      down) echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1 ;;
      *) printf '%s\n' "${STUB_RELEASE}" ;;
    esac ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "${bin}/gh"

  _pass() { checked=$(( checked + 1 )); printf '  \033[1;32mPASS\033[0m %s\n' "$1"; }
  _fail() { checked=$(( checked + 1 )); printf '  \033[1;31mFAIL\033[0m %s\n' "$1" >&2; sed 's/^/      /' "${tmp}/out" >&2; fails=1; }
  # _check <label> <cmd...>: passes when the command succeeds and every _run
  # since the previous check exited as it was told to.
  local run_bad=0
  _check() {
    local label="$1"; shift
    if "$@" && (( ! run_bad )); then _pass "${label}"; else _fail "${label}"; fi
    run_bad=0
  }
  # _run <rc> <args...>: the script as the nightly runs it, gh stubbed. stdout
  # is kept apart too, since it is --latest-release's answer. A wrong exit code
  # fails the next check rather than aborting the self-test under `set -e`.
  _run() {
    local expect="$1" got=0; shift
    ( export PATH="${bin}:${PATH}" STUB_CALLS="${calls}" STUB_OPEN="${openf}" STUB_BODIES="${tmp}/bodies" \
        GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 GH_REPO=o/r
      bash "${self}" "$@" ) >"${tmp}/stdout" 2>"${tmp}/out" || got=$?
    cat "${tmp}/stdout" >>"${tmp}/out"
    [[ "${got}" == "${expect}" ]] || { echo "rc ${got}, want ${expect}" >>"${tmp}/out"; run_bad=1; }
  }
  _night() { : >"${calls}"; printf '%s\n' "${1:-[]}" >"${openf}"; rm -f "${tmp}/bodies/"*; }
  _scan() { # <dir> <steps fixture> <jq edit of the steps> [findings file]: one artifact
    mkdir -p "$1"
    jq "$3" "${fx}/$2" >"$1/steps.json"
    if [[ -n "${4:-}" ]]; then cp "$4" "$1/findings.tsv"; else : >"$1/findings.tsv"; fi
  }
  _titles() { jq -r '.[].title' "${openf}" | sort; }
  _count() { grep -c -- "$1" "${calls}" || true; }
  _body_of() { grep -lF -- "$1" "${tmp}/bodies/"* | head -1; }
  _contains() { [[ "$(cat "$1")" == *"$2"* ]]; }

  local T='[dependency-security]' main="${tmp}/main" rel="${tmp}/rel" clean="${tmp}/clean" want_n
  local osv_title="${T} osv:RUSTSEC-2026-0459:libsqlite3-sys@0.38.1 (main)"
  local tag_title="${T} osv:RUSTSEC-2026-0459:libsqlite3-sys@0.38.1 (v0.1.13)"
  want_n="$(grep -c . "${fx}/expected-titles.txt")"
  grep '^osv:' "${fx}/findings.tsv" | head -1 >"${tmp}/osv.tsv"
  _scan "${main}" steps.main.json '.osv.outcome = "failure" | .pub.outcome = "failure" | .watcher.outcome = "failure"' "${fx}/findings.tsv"
  _scan "${rel}" steps.release-tag.json '.osv.outcome = "failure"' "${tmp}/osv.tsv"
  _scan "${clean}" steps.main.json .

  echo "file_security_issue.sh --self-test"
  echo "--- filing ---"
  _night
  _run 0 --file --scan main "${main}" failure --scan v0.1.13 "${rel}" failure
  _check "each finding is filed once, per ref, under its exact title" \
    test "$(_titles)" == "$(sort "${fx}/expected-titles.txt")"
  _check "...labelled dependency-security, closing nothing" \
    test "$(_count ' --label dependency-security$')-$(_count '^issue close')" == "${want_n}-0"
  local body
  body="$(grep -lF -- '- Advisory: `RUSTSEC-2026-0459`' "${tmp}/bodies/"* | xargs grep -lF -- '- Ref: `main`')"
  _check "the body names advisory, package, version, ref and run" \
    _contains "${body}" "$(printf -- '- Advisory: `RUSTSEC-2026-0459`\n- Package: `libsqlite3-sys` version `0.38.1`\n- Ref: `main`\n- Run: https://github.com/o/r/actions/runs/42')"
  _check "...and the remedy: update, or an owner-decided acknowledgement of at most 90 days" \
    _contains "${body}" 'a `reason` carrying `owner-decision: YYYY-MM-DD`, why it is acceptable and what lifts it, and an `effectiveUntil` at most 90 days out'
  _fenced() { [[ "$(grep -c '^```' "$1")" == 2 ]] && _contains "$1" "x ''' @someone '''"; }
  _check "a summary's backticks cannot leave its fenced block" _fenced "$(_body_of GHSA-gc79-23g3-8g52)"

  sed 's/\t.*/\tanother summary, another night/' "${fx}/findings.tsv" >"${main}/findings.tsv"
  : >"${calls}"
  _run 0 --file --scan main "${main}" failure --scan v0.1.13 "${rel}" failure
  _check "a second night, summaries changed, files nothing more and comments nowhere" \
    test "$(_count '^issue create')-$(_count '^issue comment')-$(_titles | wc -l)" == "0-0-${want_n}"

  jq '. + [{number: 77, title: "Dependabot setup"}]' "${openf}" >"${tmp}/next"; mv "${tmp}/next" "${openf}"
  : >"${calls}"
  _scan "${main}" steps.main.json '.osv.outcome = "failure"' "${tmp}/osv.tsv"
  _run 0 --file --scan main "${main}" failure --scan v0.1.13 "${clean}" success
  _check "a complete run closes the issue of every finding it no longer reports" \
    test "$(_titles | tr '\n' '|')" == "Dependabot setup|${osv_title}|"
  _check "...and never a person's issue under the label" test "$(_count '^issue close 77 ')" == 0

  _run 0 --file --scan main "${clean}" success --scan '' "${tmp}/absent" success
  _check "with no release the run is complete, and main's fixed finding closes" \
    test "$(_titles)" == "Dependabot setup"

  echo "--- a run that did not reach every verdict ---"
  _night "[{\"number\": 3, \"title\": \"${osv_title}\"}]"
  _scan "${tmp}/crash" steps.main.json '.osv.outcome = "failure"'
  _run 1 --file --scan main "${tmp}/crash" failure --scan v0.1.13 "${rel}" failure
  _check "a gate that failed without a finding closes nothing, files the run-failed issue and still files what was found" \
    test "$(_count '^issue close')-$(_titles | tr '\n' '|')" == "0-${RUN_FAILED_TITLE}|${osv_title}|${tag_title}|"
  _check "...whose body names the scan, the step and the run" \
    _contains "$(_body_of 'did not reach a verdict')" "$(printf -- '- Run: https://github.com/o/r/actions/runs/42\n\n- `main`: step `osv` failed without filing a finding')"

  : >"${calls}"
  _run 1 --file --scan main "${tmp}/crash" failure --scan v0.1.13 "${rel}" failure
  _check "a second such night keeps the run-failed issue open, once" test "$(_count '^issue create')" == 0

  _run 0 --file --scan main "${clean}" success --scan v0.1.13 "${clean}" success
  _check "the first complete night closes the run-failed issue" test -z "$(_titles)"

  _night "[{\"number\": 3, \"title\": \"${osv_title}\"}]"
  mkdir -p "${tmp}/partial"; cp "${fx}/steps.release-tag.json" "${tmp}/partial/steps.json"
  _run 1 --file --scan main "${main}" failure --scan v0.1.13 "${tmp}/partial" failure
  _check "a scan whose artifact lacks its findings did not finish: nothing closes" \
    test "$(_count '^issue close')-$(_count '^issue create')" == 0-1

  _scan "${tmp}/audit-only" steps.main.json .
  _run 1 --scan main "${tmp}/audit-only" failure
  _check "a failed job none of whose steps failed (audit.yml's cargo-audit job) did not reach a verdict" \
    grep -qF '`main`: the scan job ended `failure` with no gate step failing' "${tmp}/out"

  _scan "${tmp}/skipped" steps.main.json '.pub.outcome = "skipped"'
  _run 1 --scan main "${tmp}/skipped" success
  _check "a gate step that did not run did not reach a verdict" grep -qF 'step `pub` did not run (`skipped`)' "${tmp}/out"

  _scan "${tmp}/install" steps.release-tag.json '."install-osv".outcome = "failure" | .osv.outcome = "failure"' "${tmp}/osv.tsv"
  _run 1 --scan v0.1.13 "${tmp}/install" failure
  _check "a failed step outside the gates did not reach a verdict, whatever was found" \
    grep -qF 'step `install-osv` failed without filing a finding' "${tmp}/out"

  printf 'osv:RUSTSEC-1:x@1 (main)\tsummary\n' >"${tmp}/bad.tsv"
  _scan "${tmp}/badkey" steps.main.json . "${tmp}/bad.tsv"
  _run 1 --scan main "${tmp}/badkey" success
  _check "a finding whose key is off its shape did not reach a verdict" grep -qF 'a finding whose key is off its shape' "${tmp}/out"

  _run 1 --scan '' "${tmp}/absent" failure
  _check "a release scan that failed before naming its tag did not reach a verdict" grep -qF 'before it named a release' "${tmp}/out"

  echo "--- reading verdicts ---"
  _scan "${tmp}/tag" steps.release-tag.json '."cargo-audit".outcome = "failure" | .osv.outcome = "failure"' "${tmp}/osv.tsv"
  _run 0 --scan v0.1.13 "${tmp}/tag" failure
  _check "cargo-audit's failure is explained by osv-scanner's RustSec finding" grep -qF 'every scan reached a verdict; 1 finding' "${tmp}/out"

  _night
  _run 0 --scan main "${main}" failure
  _check "without --file nothing reaches gh" test ! -s "${calls}"

  echo "--- refusals ---"
  _night
  _label() { STUB_CREATE_FAIL=1 _run 2 --file --scan main "${main}" failure; grep -qF "does the label 'dependency-security' exist?" "${tmp}/out"; }
  _check "a label that does not exist refuses, naming it" _label
  _night "$(jq -nc '[range(200) | {number: (. + 1), title: "x"}]')"
  _run 2 --file --scan main "${clean}" success
  _check "an open-issue listing that fills its page refuses" grep -qF 'filled its page' "${tmp}/out"
  _night "[{\"number\": 3, \"title\": \"${osv_title}\"}, {\"number\": 4, \"title\": \"${osv_title}\"}]"
  _run 2 --file --scan main "${main}" failure
  _check "one title open twice refuses rather than filing a third" grep -qF 'broken de-duplication' "${tmp}/out"

  echo "--- preparing the release scan ---"
  _release() { STUB_RELEASE="$1" _run "$2" --latest-release; [[ "$(cat "${tmp}/stdout")" == "$3" ]]; }
  _check "the latest release's tag is the answer" _release v0.1.13 0 v0.1.13
  _check "no release is an empty answer, not a failure" _release none 0 ''
  _check "GitHub not answering is a refusal, never \"no release\"" _release down 2 ''
  _check "a tag off its shape is refused" _release 'v1;rm' 2 ''

  local repo="${tmp}/repo" dest="${tmp}/dest"
  git init -q "${repo}"
  mkdir -p "${repo}/a/b" "${repo}/c" "${dest}"
  printf 'cargo\n' >"${repo}/a/Cargo.lock"; printf 'pub\n' >"${repo}/a/b/pubspec.lock"; printf 'gem\n' >"${repo}/c/Gemfile.lock"
  printf 'decoy\n' >"${repo}/c/build_tool_runner.lock"; printf 'decoy\n' >"${repo}/Cargo.lock.txt"
  ln -s ../a/Cargo.lock "${repo}/c/Cargo.lock"
  git -C "${repo}" add -A
  git -C "${repo}" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm fixture
  printf 'edited\n' >"${repo}/a/Cargo.lock"; printf 'untracked\n' >"${repo}/pubspec.lock"
  _materialised() {
    _run 0 --materialise "${repo}" "${dest}"
    [[ "$(cd "${dest}" && find . -type f | sort | tr '\n' ' ')" == './a/Cargo.lock ./a/b/pubspec.lock ./c/Gemfile.lock ' ]] \
      && [[ "$(cat "${dest}/a/Cargo.lock")" == cargo ]]
  }
  _check "exactly the commit's lockfiles, as committed: no decoy, symlink, edit or untracked file" _materialised

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  --latest-release) latest_release ;;
  --materialise) (( $# == 3 )) || refuse "usage: --materialise <tag checkout> <empty dest dir>"; materialise "$2" "$3" ;;
  *) run "$@" ;;
esac
