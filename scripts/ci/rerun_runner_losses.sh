#!/usr/bin/env bash
#
# Re-run the jobs a hosted-runner loss killed — and nothing else, ever.
#
# ## Why this exists
#
# CI run 32672237999 was 34 jobs green and one red, and the red one never
# reached a verdict. `E2E Integration Tests (Android) / e2e_integration` (job
# 97275651481) died nine seconds after `Phase 4/4 — Driving test` started, 23.5
# minutes into a 45-minute budget, on two runner-written lines: a shutdown
# signal and `The operation was canceled.` Every following step is `cancelled`
# or `skipped`; the suite reported nothing. There was no OOM, no disk pressure
# (103 GB free), no timeout and no concurrency cancellation, and the lane had
# passed in the four runs before it. The machine went away.
#
# Re-running exactly that job is the only honest response, and doing it by hand
# is what does not happen at 01:00.
#
# ## Why this is not a retry, and must never become one
#
# A retry re-rolls the dice on a failure. This re-runs a job that produced no
# result at all. That distinction is the entire safety argument, and it survives
# only while the admitted evidence stays the line the RUNNER writes as it is
# being taken down. tooling/e2e/ci/ios-flake-lib.sh states the same rule for the
# iOS lane and is worth re-reading before widening anything here: retrying
# anything else is how a reproducible failure becomes a green on the second
# attempt.
#
# So, four properties, each pinned by a `--self-test` fixture:
#
#   * ONE admitted signature, matched ANCHORED to the start of a runner log
#     line — not as a substring (fixtures 6 and 7).
#   * PER-JOB judgement. A run holding one genuine failure and one runner loss
#     re-runs the runner loss and leaves the genuine failure red (fixture O2).
#   * FAIL CLOSED. A log that cannot be fetched, or arrives empty, is never a
#     runner loss — absence of evidence is not evidence (fixtures 8, 9, O3).
#   * ONCE. Only the first attempt of a run is ever considered (A1-A5, O1).
#
# Measured, not assumed. Of the 74 failed jobs this repository produced between
# 2026-08-13 and 2026-08-23, 73 have a log the API still serves, and the
# anchored signature occurs in exactly ONE of them — the job above. (The
# seventy-fourth no longer returns a log at all, which is the fail-closed path
# rather than a verdict, and is why that path is not hypothetical.) Genuine
# failures end `##[error]Process completed with exit code N` or `##[error]The
# process '/usr/bin/sh' failed…`; a concurrency cancel ends `##[error]The
# operation was canceled.` alone.
#
# ## Loop safety
#
# A sanctioned re-run creates attempt 2 of the SAME workflow run, and that
# attempt's completion fires `workflow_run` again — GitHub suppresses only the
# `requested` activity type on a re-run, not `completed`
# (https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run).
# Refusing every attempt but the first is therefore what bounds this at one
# re-run per run; it is load-bearing, not belt-and-braces. `run_attempt` is a
# required property of the `workflow_run` payload, so an absent value means the
# caller is wrong about what it is passing — which is why the gate refuses it.
#
# ## Blast radius of one re-run
#
# `POST /repos/{owner}/{repo}/actions/jobs/{job_id}/rerun` is documented as
# "Re-run a job and its dependent jobs in a workflow run"
# (https://docs.github.com/en/rest/actions/workflow-runs). Dependents exist only
# for a job something `needs:` — in ci.yml that is `rust`, `coverage` and
# `guards`. Whatever needed them was skipped when they failed, so re-running
# those too is the correct result rather than collateral. Every E2E lane, this
# incident included, has no dependents at all.
#
# ## Usage
#
#   scripts/ci/rerun_runner_losses.sh              # driven by rerun-runner-losses.yml
#   scripts/ci/rerun_runner_losses.sh --classify <job-log>
#   scripts/ci/rerun_runner_losses.sh --self-test  # hermetic; no network, no gh
#
# Environment (the orchestrating run):
#   GH_TOKEN                  token carrying `actions: write`
#   GITHUB_REPOSITORY         owner/repo
#   HAVEN_RERUN_RUN_ID        github.event.workflow_run.id
#   HAVEN_RERUN_RUN_ATTEMPT   github.event.workflow_run.run_attempt
#
# Exit codes:
#   0  every failed job was judged and the decisions were reported
#   1  --classify only: this log is NOT a runner loss (leave the job red)
#   2  misconfiguration, or the API refused a request this script had to make

set -euo pipefail

SCRIPT_NAME="rerun_runner_losses"

misconfig() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# The one admitted signature
# ---------------------------------------------------------------------------

# Defined HERE and nowhere else in the repository — fixture P2 re-derives that
# by scanning the tree, and the workflow never names it because this script
# writes it into the annotation itself. A second copy is not a style problem: it
# is a copy that can be narrowed, widened or corrected on its own, and a
# classifier whose signature disagrees with the string its caller claims to look
# for is worse than no classifier.
#
# Only the runner writes this line, and only while being taken down. Rot
# direction, stated because nothing hermetic can pin a literal owned by the
# Actions runner: if GitHub changes the wording, nothing matches, nothing is
# re-run, and runner losses simply stay red — noisier, never quieter. The unsafe
# direction (a literal that starts matching genuine failures) is not reachable
# from a wording change, only from someone editing this line.
#
# A step CAN forge the line: `::error::…` emitted by a job renders in the log
# exactly like a runner-written `##[error]…`. The consequence is bounded and
# uninteresting — a job wins itself one re-run, which anyone able to push to the
# branch already has for free — and nothing in this repository prints the phrase
# (fixture P2), so no accident produces it.
readonly RUNNER_SHUTDOWN_SIGNATURE='##[error]The runner has received a shutdown signal'

# Every line of a job log fetched from the API is `<RFC3339 timestamp> <text>`.
# Requiring the timestamp is what turns "the log contains the signature" into
# "the runner emitted the signature": with no anchor, a step that merely PRINTS
# the string — a grep pattern echoed by `##[group]Run …`, a diagnostic, this
# file quoted into a log — satisfies a substring match, `##[error]` prefix and
# all. Fixture 7 is that exact line and must not qualify.
readonly LOG_TIMESTAMP_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z'

# ERE-escape, so the signature keeps exactly one definition: `##[error]` is a
# bracket expression to `grep -E`, and hand-writing an escaped second copy is
# precisely the drift the single definition exists to prevent.
_ere_escape() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'; }

runner_loss_line_re() {
  printf '^%s %s' "${LOG_TIMESTAMP_RE}" "$(_ere_escape "${RUNNER_SHUTDOWN_SIGNATURE}")"
}

# runner_loss_log_qualifies <log> — 0 (true) iff this log carries the admitted
# runner-shutdown line. An absent or empty log returns 1: it cannot show a
# runner loss it does not contain, and "we could not read it" must never be the
# benign case (the rule scan-logs-for-secrets.sh had to learn the hard way).
#
# Reads the file directly rather than through a pipe: under `pipefail` a
# `producer | grep -q` reports FAILURE on a SUCCESSFUL match once grep exits
# early and the producer takes SIGPIPE — a fault invisible on fixtures and
# visible only on a multi-megabyte CI log.
runner_loss_log_qualifies() {
  local log="${1:-}"
  [[ -s "${log}" ]] || return 1
  LC_ALL=C grep -aqE -- "$(runner_loss_line_re)" "${log}"
}

# classify_log <log> — prints `<verdict><TAB><reason>` and returns 0 only for a
# runner loss. The reason reaches the step summary, so each path says what was
# actually observed: "we never read the log" and "the log says this failed on
# its own" are different facts and must not share a sentence.
classify_log() {
  local log="${1:-}"
  if [[ ! -f "${log}" ]]; then
    printf 'not-proven\tits log could not be fetched, so nothing was judged\n'
    return 1
  fi
  if [[ ! -s "${log}" ]]; then
    printf 'not-proven\tits log arrived empty, so nothing was judged\n'
    return 1
  fi
  if runner_loss_log_qualifies "${log}"; then
    printf 'runner-loss\tthe runner was shut down mid-job; the job reached no verdict\n'
    return 0
  fi
  printf 'not-proven\tno runner-shutdown line — this failure is the job'\''s own\n'
  return 1
}

# rerun_attempt_allowed <attempt> — 0 (true) only for the very first attempt of
# a run. String equality on purpose: the payload carries an integer, so anything
# that is not exactly `1` is either a later attempt we must never chain from or
# a caller we cannot trust.
rerun_attempt_allowed() { [[ "${1:-}" == "1" ]]; }

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

summary() { printf '%s\n' "$*" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"; }

# failed_jobs_tsv <jobs-json> — `id<TAB>name` for every job the run reports as
# `failure`. `cancelled` is deliberately not a candidate: that is what GitHub
# records for a concurrency cancel and for a human pressing the button, and
# neither should be undone. The runner-loss job of run 32672237999 is reported
# as `failure` (its killed step is `failure`, the rest `cancelled`/`skipped`),
# so nothing is lost by that.
failed_jobs_tsv() {
  jq -r '.[].jobs[] | select(.conclusion == "failure") | [.id, .name] | @tsv' "$1"
}

# fetch_job_log <repo> <job-id> <dest> — the plain-text log of ONE job.
#
# curl, not `gh api`: log bodies carry terminal escape sequences, which gh
# refuses to emit without `--allow-escape-sequences` — a flag whose presence
# depends on the runner image's gh version, so a version skew would silently
# switch this whole feature off. `-L` follows the documented 302 to the
# short-lived signed URL; `-f` turns an HTTP error into a non-zero exit and
# leaves no file, which is exactly the fail-closed input classify_log expects.
fetch_job_log() {
  curl -fsSL \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${1}/actions/jobs/${2}/logs" -o "${3}"
}

request_rerun() {
  gh api --method POST "repos/${1}/actions/jobs/${2}/rerun" --silent
}

main() {
  local repo="${GITHUB_REPOSITORY:-}" run_id="${HAVEN_RERUN_RUN_ID:-}"
  local attempt="${HAVEN_RERUN_RUN_ATTEMPT:-}"
  [[ -n "${repo}" && -n "${run_id}" ]] \
    || misconfig 'GITHUB_REPOSITORY and HAVEN_RERUN_RUN_ID are required'
  command -v jq >/dev/null 2>&1 || misconfig 'jq is required'

  summary "### Runner-loss re-runs — run ${run_id}, attempt ${attempt:-<unset>}"
  summary ''

  if ! rerun_attempt_allowed "${attempt}"; then
    summary 'Nothing considered: only the first attempt of a run may be re-run,' \
            'and a sanctioned re-run reports itself here as a later attempt.'
    return 0
  fi

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: the trap must not depend on a live var
  trap "rm -rf '${work}'" EXIT

  # `filter=latest` is redundant while the attempt gate above holds — attempt 1
  # IS the latest — and is sent anyway so the query never depends on that.
  gh api --paginate --slurp \
    "repos/${repo}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" \
    >"${work}/jobs.json" \
    || misconfig "could not list the jobs of run ${run_id}"

  # Materialised rather than streamed from a process substitution, because a jq
  # that fails there is indistinguishable from a run with no failed jobs — and
  # "nothing failed" is the one wrong answer this script must never give itself.
  failed_jobs_tsv "${work}/jobs.json" >"${work}/failed.tsv" \
    || misconfig "could not read the job list of run ${run_id}"

  local -a rerun=() left=()
  local id name verdict log refused=0
  while IFS=$'\t' read -r id name; do
    [[ -n "${id}" ]] || continue
    log="${work}/${id}.log"
    fetch_job_log "${repo}" "${id}" "${log}" || rm -f "${log}"
    if verdict="$(classify_log "${log}")"; then
      if request_rerun "${repo}" "${id}"; then
        rerun+=("${name} — ${verdict#*$'\t'}")
      else
        # Judged actionable and the API would not act: that is this script
        # failing, not a verdict, so it is reported AND made red below.
        left+=("${name} — classified as a runner loss, but the re-run was refused")
        refused=1
      fi
    else
      left+=("${name} — ${verdict#*$'\t'}")
    fi
  done <"${work}/failed.tsv"

  summary "Signature looked for: \`${RUNNER_SHUTDOWN_SIGNATURE}\`"
  summary ''
  if ((${#rerun[@]} == 0 && ${#left[@]} == 0)); then
    summary 'No failed jobs in this run.'
  fi
  if ((${#rerun[@]} > 0)); then
    summary "**Re-run (${#rerun[@]})**"
    for id in "${rerun[@]}"; do summary "- ${id}"; done
    summary ''
  fi
  if ((${#left[@]} > 0)); then
    summary "**Left red (${#left[@]})**"
    for id in "${left[@]}"; do summary "- ${id}"; done
    summary ''
  fi

  ((refused == 0)) || misconfig 'a sanctioned re-run was refused by the API'
}

# ---------------------------------------------------------------------------
# --self-test — hermetic. No network, no gh, no runner.
# ---------------------------------------------------------------------------

# The shutdown line below is the ONLY re-typed copy of the signature in this
# repository, and it is re-typed on purpose: these are the bytes CI run
# 32672237999 actually produced for job 97275651481, copied from
# `GET /actions/jobs/97275651481/logs`. Fixture P1 asserts the pinned constant
# is still a substring of them, so a constant edited on its own fails here
# instead of quietly matching nothing for the rest of the repository's life.
_verbatim_runner_loss_log() {
  cat <<'EOF'
2026-08-23T23:29:56.1158980Z Phase 4/4 — Driving test on emulator-5554 (timeout 10m, connect-watchdog 120s, up to 3 attempt(s))...
2026-08-23T23:30:05.6454212Z ##[group]Run docker logs strfry > /tmp/strfry.log 2>&1 || true
2026-08-23T23:30:05.7050585Z ##[error]The runner has received a shutdown signal. This can happen when the runner service is stopped, or a manually started runner is canceled.
2026-08-23T23:30:07.8622575Z ##[error]The operation was canceled.
2026-08-23T23:30:07.9918865Z Cleaning up orphan processes
EOF
}

self_test() {
  local tmp fails=0 n=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _expect() { # <want-rc> <label> <log>
    local want="$1" label="$2" log="$3" got=0
    n=$((n + 1))
    classify_log "${log}" >/dev/null 2>&1 || got=$?
    if [[ "${got}" == "${want}" ]]; then
      printf '  PASS %s\n' "${label}"
    else
      printf '  FAIL %s (want rc=%s, got rc=%s)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  printf 'self-test: %s\n' "${SCRIPT_NAME}"
  printf -- '--- classification ---\n'

  # (1) THE CASE THIS EXISTS FOR. Verbatim bytes from job 97275651481.
  _verbatim_runner_loss_log >"${tmp}/runner-loss.log"
  _expect 0 '(1) the CI run 32672237999 runner loss is re-run' "${tmp}/runner-loss.log"

  # (2) A GENUINE TEST FAILURE — the shape every red E2E lane has: the step
  #     exits non-zero and the runner reports the process, never itself.
  printf '%s\n' \
    '2026-08-23T20:06:30.1000000Z 00:41 +7 -1: e2e_permission_revocation [E]' \
    '2026-08-23T20:06:30.2000000Z   Expected: <2>  Actual: <1>' \
    "2026-08-23T20:06:34.7277270Z ##[error]The process '/usr/bin/sh' failed with exit code 1" \
    >"${tmp}/test-failure.log"
  _expect 1 '(2) a genuine test failure is left red' "${tmp}/test-failure.log"

  # (3) A JOB-LEVEL TIMEOUT. `timeout-minutes` elapsed, so the runner cancels
  #     the job and the tail reads like a runner loss to a careless eye — same
  #     `The operation was canceled.`, same cancelled/skipped steps — and is
  #     nothing of the sort. A lane that cannot finish inside its budget has
  #     produced a result; re-running it hides that for another 45 minutes.
  printf '%s\n' \
    '2026-08-23T23:50:00.1000000Z Phase 4/4 — Driving test on emulator-5554' \
    '2026-08-23T23:51:00.2000000Z ##[error]The job running on runner GitHub Actions 5 has exceeded the maximum execution time of 45 minutes.' \
    '2026-08-23T23:51:00.3000000Z ##[error]The operation was canceled.' \
    >"${tmp}/job-timeout.log"
  _expect 1 '(3) a job-level timeout is left red' "${tmp}/job-timeout.log"

  # (4) A STEP-LEVEL TIMEOUT. Different literal, same rule.
  printf '%s\n' \
    '2026-08-23T23:40:00.1000000Z Phase 4/4 — Driving test on emulator-5554' \
    "2026-08-23T23:50:00.2000000Z ##[error]The action 'Run integration tests on the emulator' has timed out after 10 minutes." \
    '2026-08-23T23:50:00.3000000Z ##[error]The operation was canceled.' \
    >"${tmp}/step-timeout.log"
  _expect 1 '(4) a step-level timeout is left red' "${tmp}/step-timeout.log"

  # (5) CANCELLED BY CONCURRENCY. Verbatim tail of job 94011693726, which
  #     `cancel-in-progress` killed when the branch was pushed again. GitHub
  #     records such a job as `cancelled`, so failed_jobs_tsv never offers it —
  #     but the classifier must refuse it on its own, so the guarantee does not
  #     rest on a conclusion string alone.
  printf '%s\n' \
    '2026-08-12T04:52:02.9773954Z ##[error]The operation was canceled.' \
    '2026-08-12T04:52:06.9310972Z Terminate orphan process: pid (27971) (sh)' \
    >"${tmp}/concurrency-cancel.log"
  _expect 1 '(5) a concurrency cancellation is left red' "${tmp}/concurrency-cancel.log"

  # (6) THE PHRASE WITHOUT THE `##[error]` PREFIX. A step that talks ABOUT the
  #     signature must not be able to nominate its own job for a re-run. The
  #     phrase is taken from the constant with the prefix stripped rather than
  #     re-typed, so this fixture cannot decay into passing on a casing
  #     difference instead of on the missing prefix.
  printf '%s\n' \
    "2026-08-23T23:30:05.1000000Z diagnostics: no line matching \"${RUNNER_SHUTDOWN_SIGNATURE#*]}\" in /tmp/job.log" \
    '2026-08-23T23:30:06.2000000Z ##[error]Process completed with exit code 1.' \
    >"${tmp}/echoed-phrase.log"
  _expect 1 '(6) a log that merely mentions the phrase is left red' "${tmp}/echoed-phrase.log"

  # (7) THE PREFIX, EMBEDDED. Exactly what `##[group]Run …` echoes when a step
  #     greps for this signature: prefix and all, mid-line. This is the fixture
  #     that makes "require the `##[error]` prefix" mean something — a substring
  #     match accepts this line, prefix included, and would re-run the job.
  printf '%s\n' \
    "2026-08-23T23:30:05.1000000Z ##[group]Run grep -c '${RUNNER_SHUTDOWN_SIGNATURE}' /tmp/job.log" \
    '2026-08-23T23:30:06.2000000Z ##[error]Process completed with exit code 1.' \
    >"${tmp}/embedded-prefix.log"
  _expect 1 '(7) the signature quoted mid-line is left red' "${tmp}/embedded-prefix.log"

  # (8)/(9) FAIL CLOSED — no log at all, and a log that arrived empty.
  _expect 1 '(8) an unfetchable log is left red' "${tmp}/absent.log"
  : >"${tmp}/empty.log"
  _expect 1 '(9) an empty log is left red' "${tmp}/empty.log"

  # (10) …and the unreadable cases must SAY they were unreadable. The annotation
  #      is the only place a human learns a job was never judged, and "no
  #      runner-shutdown line" would be a lie about what was observed.
  n=$((n + 1))
  if [[ "$(classify_log "${tmp}/absent.log" || true)" == *'could not be fetched'* ]]; then
    printf '  PASS (10) an unfetchable log is reported as unread, not as judged\n'
  else
    printf '  FAIL (10) an unfetchable log is not reported as unread\n' >&2
    fails=1
  fi

  printf -- '--- the attempt gate ---\n'
  _attempt() { # <want-rc> <label> <attempt>
    local want="$1" label="$2" got=0
    n=$((n + 1))
    rerun_attempt_allowed "${3-}" || got=$?
    if [[ "${got}" == "${want}" ]]; then
      printf '  PASS %s\n' "${label}"
    else
      printf '  FAIL %s (want rc=%s, got rc=%s)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }
  _attempt 0 '(A1) attempt 1 is considered'                1
  _attempt 1 '(A2) attempt 2 — the re-run itself — is not' 2
  _attempt 1 '(A3) attempt 3 is not'                       3
  _attempt 1 '(A4) an absent attempt is not'               ''
  _attempt 1 '(A5) a non-numeric attempt is not'           'latest'

  printf -- '--- the signature is pinned in one place ---\n'
  # (P1) The constant must still match the bytes GitHub emitted. This guards the
  #      direction fixture 1 cannot: fixture 1 keeps passing if the constant and
  #      the verbatim log are edited together, but a constant narrowed on its
  #      own stops being a substring of the real line here.
  n=$((n + 1))
  if LC_ALL=C grep -qF -- "${RUNNER_SHUTDOWN_SIGNATURE}" <(_verbatim_runner_loss_log); then
    printf '  PASS (P1) the pinned literal still occurs in the real CI log\n'
  else
    printf '  FAIL (P1) the pinned literal no longer matches the bytes of job 97275651481\n' >&2
    fails=1
  fi

  # (P2) …and occurs in no other file that could act on it or describe it.
  #      Scoped to the trees where a second copy becomes behaviour or
  #      documentation, and reading UNTRACKED files too: a workflow added
  #      alongside this script is untracked until it is committed, and a scan
  #      blind to that would bless the very drift it exists to catch.
  n=$((n + 1))
  local -a others=()
  local repo_root f
  if repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)"; then
    while IFS= read -r f; do
      if [[ ! "${repo_root}/${f}" -ef "${BASH_SOURCE[0]}" ]] \
        && LC_ALL=C grep -qF -- "${RUNNER_SHUTDOWN_SIGNATURE}" "${repo_root}/${f}" 2>/dev/null; then
        others+=("${f}")
      fi
    done < <(git -C "${repo_root}" ls-files --cached --others --exclude-standard \
               -- .github scripts tooling docs)
    if ((${#others[@]} == 0)); then
      printf '  PASS (P2) the signature is defined in exactly one file\n'
    else
      printf '  FAIL (P2) the signature is duplicated in: %s\n' "${others[*]}" >&2
      fails=1
    fi
  else
    printf '  FAIL (P2) not a git checkout — the single-definition scan could not run\n' >&2
    fails=1
  fi

  printf -- '--- end to end, with gh and curl stubbed ---\n'
  _orchestrator_fixtures "${tmp}" || fails=1
  n=$((n + 6))

  printf '\n'
  if ((fails != 0)); then
    printf '%s --self-test: FAILED — the re-run gate cannot be trusted.\n' "${SCRIPT_NAME}" >&2
    return 1
  fi
  printf 'OK: %s --self-test passed (%d fixtures).\n' "${SCRIPT_NAME}" "${n}"
  return 0
}

# The orchestrator fixtures drive `main` itself with `gh` and `curl` replaced by
# stubs on PATH. They exist because every predicate above can be correct while
# `main` consults none of them — the failure mode the iOS lane hit when a sound
# classifier sat behind a retry action that decided on its own.
_orchestrator_fixtures() { # <tmp>
  local tmp="$1" fails=0 bin="$1/bin"
  mkdir -p "${bin}"

  # `gh` stub: serves the jobs listing from a fixture and records each re-run
  # request. Records EVERY call, so a fixture can assert the attempt gate
  # stopped the run before the network was touched at all.
  cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_CALLS}"
case "$*" in
  */rerun*)
    for a in "$@"; do
      case "${a}" in
        */rerun) a="${a##*/jobs/}"; printf '%s\n' "${a%/rerun}" >>"${STUB_RERUNS}" ;;
      esac
    done
    ;;
  *"/jobs?"*) cat "${STUB_JOBS_JSON}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB

  # `curl` stub: serves `${STUB_LOG_DIR}/<job-id>.log` when it exists, otherwise
  # exits 22 writing nothing — what real `curl -f` does on an HTTP error, and
  # the fail-closed input the classifier must be handed.
  cat >"${bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
url=""; out=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
id="${url##*/jobs/}"; id="${id%/logs}"
[[ -f "${STUB_LOG_DIR}/${id}.log" ]] || exit 22
cp "${STUB_LOG_DIR}/${id}.log" "${out}"
STUB
  chmod +x "${bin}/gh" "${bin}/curl"

  local logs="${tmp}/stublogs"
  mkdir -p "${logs}"
  _verbatim_runner_loss_log >"${logs}/97275651481.log"
  cp "${tmp}/test-failure.log" "${logs}/97249491991.log"

  cat >"${tmp}/jobs.json" <<'JSON'
[{"jobs":[
  {"id":97275651481,"name":"E2E Integration Tests (Android) / e2e_integration","conclusion":"failure"},
  {"id":97249491991,"name":"E2E Permission Revocation (Android) / e2e_permission_revocation","conclusion":"failure"},
  {"id":97275651000,"name":"Rust Checks / haven-core","conclusion":"success"},
  {"id":97275651001,"name":"E2E Core Flow (Android) / e2e_android","conclusion":"cancelled"}
]}]
JSON

  local calls="${tmp}/calls" reruns="${tmp}/reruns" sum="${tmp}/summary.md"
  _drive() { # <attempt> <log-dir>
    : >"${calls}"; : >"${reruns}"; : >"${sum}"
    ( export PATH="${bin}:${PATH}" \
             STUB_CALLS="${calls}" STUB_RERUNS="${reruns}" \
             STUB_JOBS_JSON="${tmp}/jobs.json" STUB_LOG_DIR="$2" \
             GITHUB_STEP_SUMMARY="${sum}" GH_TOKEN=stub \
             GITHUB_REPOSITORY='mehmetefeumit/Haven-App' \
             HAVEN_RERUN_RUN_ID=32672237999 HAVEN_RERUN_RUN_ATTEMPT="$1"
      main >/dev/null 2>&1 )
  }
  _check() { # <rc> <label>
    if [[ "$1" == 0 ]]; then printf '  PASS %s\n' "$2"; else printf '  FAIL %s\n' "$2" >&2; fails=1; fi
  }

  # (O1) LOOP SAFETY, END TO END. Attempt 2 is what a sanctioned re-run reports
  #      back, and it must cost nothing: no listing, no log fetch, no re-run.
  local rc=0
  _drive 2 "${logs}" || rc=$?
  _check "$([[ "${rc}" == 0 ]] && echo 0 || echo 1)" '(O1) attempt 2 exits cleanly'
  _check "$([[ ! -s "${calls}" ]] && echo 0 || echo 1)" '(O1) attempt 2 makes no API call at all'

  # (O2) PER-JOB, NOT PER-RUN. One runner loss and one genuine failure in the
  #      same run: exactly one re-run, and it is the runner loss.
  rc=0
  _drive 1 "${logs}" || rc=$?
  _check "$([[ "${rc}" == 0 ]] && echo 0 || echo 1)" '(O2) a mixed run exits cleanly'
  _check "$([[ "$(cat "${reruns}")" == '97275651481' ]] && echo 0 || echo 1)" \
         '(O2) exactly the runner-loss job is re-run; the genuine failure stays red'
  _check "$(grep -q "e2e_permission_revocation.*this failure is the job" "${sum}" && echo 0 || echo 1)" \
         '(O2) the annotation names the failure it deliberately left alone'

  # (O3) FAIL CLOSED, END TO END. Same run, but no log can be fetched for any
  #      job: nothing may be re-run, and the summary must say why.
  rc=0
  _drive 1 "${tmp}/no-logs-here" || rc=$?
  _check "$([[ "${rc}" == 0 && ! -s "${reruns}" ]] \
            && grep -q 'could not be fetched' "${sum}" && echo 0 || echo 1)" \
         '(O3) unreadable logs re-run nothing and say so'

  return "${fails}"
}

case "${1:-}" in
  '')          main ;;
  --self-test) self_test ;;
  --classify)
    [[ -n "${2:-}" ]] || misconfig 'usage: --classify <job-log>'
    classify_log "$2"
    ;;
  -h|--help)   sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d' ;;
  *)           misconfig "unknown argument: $1" ;;
esac
