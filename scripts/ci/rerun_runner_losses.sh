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
#     line — not as a substring (fixtures 6 and 7), and not merely preceded by
#     some timestamp, which a step printing a captured log satisfies (7b).
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
# UNMEASURED, and left that way on purpose: what a SECOND `…/rerun` POST does
# once an earlier one in the same pass has already opened attempt 2. Either it
# opens a further attempt — still one re-run per qualifying job, every one of
# which the attempt gate then refuses — or it answers 403, which this script
# reports as its OWN failure and exits 2 on (fixture O4), never as a verdict.
# Both are loud and neither re-runs anything twice. Over the measured history of
# 74 failed jobs the signature qualified exactly one, so the case has not arisen.
#
# ## Usage
#
#   scripts/ci/rerun_runner_losses.sh              # driven by rerun-runner-losses.yml
#   scripts/ci/rerun_runner_losses.sh --classify <job-log>
#   scripts/ci/rerun_runner_losses.sh --self-test  # offline; loopback only
#
# `--self-test` drives the REAL `curl` against a 127.0.0.1 server it starts
# itself, so it needs curl, python3, jq and git. A missing one is reported as a
# named FAILED fixture — never as a skip, because a stub nobody checked is what
# this gate exists to stop reporting green.
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

# Both sinks, always. Measured 2026-09-21: the step of run 35541175084 judged
# thirteen failed jobs and wrote NOTHING between its `##[endgroup]` and `Post job
# cleanup` — every line had gone to the step summary, which no REST endpoint
# serves, so the record of what was judged existed only as a web page. The log is
# the copy `gh run view --log` and the log scanner can read.
summary() {
  printf '%s\n' "$*"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || printf '%s\n' "$*" >>"${GITHUB_STEP_SUMMARY}"
}

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
#
# Named so the C fixtures measure THESE flags against the real binary instead of
# a retyped approximation. The two bounds are not politeness: without them one
# stalled connection eats the whole 15-minute budget rerun-runner-losses.yml
# gives this job, the job is cancelled, and every judgement it had already made
# is lost along with the annotation. A log that has not arrived in 60 s is the
# fail-closed `not-proven` case, which leaves a job red — the safe direction.
readonly -a CURL_FETCH_FLAGS=(-fsSL --connect-timeout 15 --max-time 60)

fetch_job_log() {
  curl "${CURL_FETCH_FLAGS[@]}" \
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
# --self-test — offline. No gh, no runner, no packet past 127.0.0.1.
# ---------------------------------------------------------------------------

# Pinned by equality against the fixtures that actually ran, because a fixture
# that stops running is the one way a deleted fixture reports success.
readonly SELF_TEST_FIXTURES=39

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

  # The ONE counter every fixture goes through, so the pin above cannot drift
  # from the fixtures that ran. `<detail>` is a file printed only on failure:
  # the old harness swallowed the driven script's output, and a fixture that
  # fails without evidence cost an hour when `jq is required` was the whole
  # story.
  _ok() { # <0-if-passed> <label> [detail-file]
    n=$((n + 1))
    if [[ "$1" == 0 ]]; then
      printf '  PASS %s\n' "$2"
      return 0
    fi
    printf '  FAIL %s\n' "$2" >&2
    [[ -z "${3:-}" || ! -s "${3:-}" ]] || sed 's/^/        | /' "$3" >&2
    fails=1
    return 0
  }

  _expect() { # <want-rc> <label> <log>
    local want="$1" label="$2" log="$3" got=0
    classify_log "${log}" >/dev/null 2>&1 || got=$?
    if [[ "${got}" == "${want}" ]]; then
      _ok 0 "${label}"
    else
      _ok 1 "${label} (want rc=${want}, got rc=${got})"
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

  # (7b) A CAPTURED RUNNER LOG, PRINTED BY A STEP. The runner stamps the line it
  #      is given, and the line it is given is itself `<timestamp> ##[error]…` —
  #      the shape any step that cats a job log produces, this repository's own
  #      log scanners included. The timestamp requirement alone is SATISFIED
  #      here; only anchoring to the start of the line refuses it, and without
  #      this fixture that anchor could be dropped with every other one green.
  printf '%s\n' \
    "2026-09-20T22:16:47.1000000Z 2026-08-23T23:30:05.7050585Z ${RUNNER_SHUTDOWN_SIGNATURE}." \
    '2026-09-20T22:16:47.2000000Z ##[error]Process completed with exit code 1.' \
    >"${tmp}/echoed-runner-log.log"
  _expect 1 '(7b) a captured runner log printed by a step is left red' \
    "${tmp}/echoed-runner-log.log"

  # (8)/(9) FAIL CLOSED — no log at all, and a log that arrived empty.
  _expect 1 '(8) an unfetchable log is left red' "${tmp}/absent.log"
  : >"${tmp}/empty.log"
  _expect 1 '(9) an empty log is left red' "${tmp}/empty.log"

  # (10) …and the unreadable cases must SAY they were unreadable. The annotation
  #      is the only place a human learns a job was never judged, and "no
  #      runner-shutdown line" would be a lie about what was observed.
  _ok "$([[ "$(classify_log "${tmp}/absent.log" || true)" == *'could not be fetched'* ]] \
          && echo 0 || echo 1)" \
      '(10) an unfetchable log is reported as unread, not as judged'

  printf -- '--- the attempt gate ---\n'
  _attempt() { # <want-rc> <label> <attempt>
    local want="$1" label="$2" got=0
    rerun_attempt_allowed "${3-}" || got=$?
    if [[ "${got}" == "${want}" ]]; then
      _ok 0 "${label}"
    else
      _ok 1 "${label} (want rc=${want}, got rc=${got})"
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
  _ok "$(LC_ALL=C grep -qF -- "${RUNNER_SHUTDOWN_SIGNATURE}" <(_verbatim_runner_loss_log) \
          && echo 0 || echo 1)" \
      '(P1) the pinned literal still occurs in the real CI log'

  # (P2) …and occurs in no other file that could act on it or describe it. The
  #      header claims nothing in this REPOSITORY prints the phrase, so the scan
  #      is the whole tree — ~1280 files, 54 ms measured — and not the four
  #      directories it used to cover, which left a Dart or Rust fixture free to
  #      print the line into a CI log and nominate its own job. Untracked files
  #      count: a workflow added alongside this script is untracked until it is
  #      committed, and a scan blind to that would bless the drift it exists to
  #      catch. `scratchpad/` is the one exclusion, because a working note
  #      quoting this line neither ships nor runs, and a guard that reds on
  #      somebody's analysis of it is a guard nobody keeps.
  local -a others=()
  local repo_root f
  if repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)"; then
    while IFS= read -r f; do
      if [[ ! "${repo_root}/${f}" -ef "${BASH_SOURCE[0]}" ]] \
        && LC_ALL=C grep -qF -- "${RUNNER_SHUTDOWN_SIGNATURE}" "${repo_root}/${f}" 2>/dev/null; then
        others+=("${f}")
      fi
    done < <(git -C "${repo_root}" ls-files --cached --others --exclude-standard \
               -- . ':(exclude)scratchpad')
    if ((${#others[@]} == 0)); then
      _ok 0 '(P2) the signature is defined in exactly one file'
    else
      _ok 1 "(P2) the signature is duplicated in: ${others[*]}"
    fi
  else
    _ok 1 '(P2) not a git checkout — the single-definition scan could not run'
  fi

  printf -- '--- end to end, with gh and curl stubbed ---\n'
  _orchestrator_fixtures "${tmp}" || fails=1

  printf -- '--- the curl stub, measured against the real binary ---\n'
  _real_curl_fixtures "${tmp}" "${tmp}/bin" || fails=1

  printf '\n'
  if ((fails != 0)); then
    printf '%s --self-test: FAILED — the re-run gate cannot be trusted.\n' "${SCRIPT_NAME}" >&2
    return 1
  fi
  if ((n != SELF_TEST_FIXTURES)); then
    printf '%s --self-test: ran %d fixture(s), expected exactly %d. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success.\n' \
      "${SCRIPT_NAME}" "${n}" "${SELF_TEST_FIXTURES}" >&2
    return 1
  fi
  printf 'OK: %s --self-test passed (%d/%d fixtures).\n' \
    "${SCRIPT_NAME}" "${n}" "${SELF_TEST_FIXTURES}"
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
  #
  # Failure is MODELLED, not imagined. Measured 2026-09-21 against this
  # repository: `gh api --silent` on an HTTP error exits 1, prints nothing on
  # stdout and renders exactly `gh: <message> (HTTP <code>)` on stderr. The
  # re-run endpoint is documented 201/403 and is never called from a test, so
  # the 403 comes from the REST reference and its rendering from that
  # measurement. Without this the stub was a `gh` that could not fail, and the
  # two paths where the API refuses were the untested ones.
  cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_CALLS}"
_http_error() { printf 'gh: %s (HTTP %s)\n' "$2" "$1" >&2; exit 1; }
case "$*" in
  */rerun*)
    for a in "$@"; do
      case "${a}" in
        */rerun)
          a="${a##*/jobs/}"; a="${a%/rerun}"
          case " ${STUB_GH_RERUN_403:-} " in
            *" ${a} "*) _http_error 403 'Forbidden' ;;
          esac
          printf '%s\n' "${a}" >>"${STUB_RERUNS}"
          ;;
      esac
    done
    ;;
  *"/jobs?"*)
    [[ -z "${STUB_GH_JOBS_404:-}" ]] || _http_error 404 'Not Found'
    cat "${STUB_JOBS_JSON}"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB

  # `curl` stub: serves `${STUB_LOG_DIR}/<job-id>.log` when it exists. Its two
  # failure shapes are the ones fixtures C1-C6 re-measure against the real
  # binary in this same run, so this can no longer drift from the tool it
  # impersonates: a miss is `-f`'s HTTP error — rc 22, NO output file, one line
  # on stderr — and `<job-id>.partial` is a transfer that died mid-body, which
  # exits 18 leaving the bytes it did receive ON DISK. Nothing asserts the rc-18
  # wording (it carries a byte count a fixture has no declared length for), so
  # it is not invented here; the rc and the residue are what production meets.
  cat >"${bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
url=""; out=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*|http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
id="${url##*/jobs/}"; id="${id%/logs}"
if [[ -f "${STUB_LOG_DIR}/${id}.partial" ]]; then
  cp "${STUB_LOG_DIR}/${id}.partial" "${out}"
  exit 18
fi
if [[ ! -f "${STUB_LOG_DIR}/${id}.log" ]]; then
  printf 'curl: (22) The requested URL returned error: 404\n' >&2
  exit 22
fi
cp "${STUB_LOG_DIR}/${id}.log" "${out}"
STUB
  chmod +x "${bin}/gh" "${bin}/curl"

  local logs="${tmp}/stublogs"
  mkdir -p "${logs}"
  _verbatim_runner_loss_log >"${logs}/97275651481.log"
  cp "${tmp}/test-failure.log" "${logs}/97249491991.log"

  # The API's shape, not a sketch of it. Measured 2026-09-21 on run 35536892150:
  # `--paginate --slurp` yields an ARRAY OF PAGE OBJECTS, each `{"total_count",
  # "jobs"}`, and a job carries `status` alongside `conclusion`. The vocabulary
  # below is the one that repository's last 25 runs actually produced —
  # success, skipped, failure, cancelled, and `in_progress` with a NULL
  # conclusion (3 of 340 jobs) — so `select(.conclusion == "failure")` is
  # exercised against every value it can meet rather than against three.
  cat >"${tmp}/jobs.json" <<'JSON'
[{"total_count":6,"jobs":[
  {"id":97275651481,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"failure","name":"E2E Integration Tests (Android) / e2e_integration"},
  {"id":97249491991,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"failure","name":"E2E Permission Revocation (Android) / e2e_permission_revocation"},
  {"id":97275651000,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"success","name":"Rust Checks / haven-core"},
  {"id":97275651001,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"cancelled","name":"E2E Core Flow (Android) / e2e_android"},
  {"id":97275651002,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"skipped","name":"Build Verification / build_android_arm64"},
  {"id":97275651003,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"in_progress","conclusion":null,"name":"E2E Core Flow (iOS) / e2e_ios"}
]}]
JSON

  # The same run split the way the API really splits it once a run outgrows one
  # page, with the runner loss stranded on page 2.
  cat >"${tmp}/jobs-paged.json" <<'JSON'
[{"total_count":3,"jobs":[
  {"id":97249491991,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"failure","name":"E2E Permission Revocation (Android) / e2e_permission_revocation"},
  {"id":97275651000,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"success","name":"Rust Checks / haven-core"}
]},
{"total_count":3,"jobs":[
  {"id":97275651481,"run_id":32672237999,"run_attempt":1,"workflow_name":"CI","status":"completed","conclusion":"failure","name":"E2E Integration Tests (Android) / e2e_integration"}
]}]
JSON

  local calls="${tmp}/calls" reruns="${tmp}/reruns" sum="${tmp}/summary.md"
  local out="${tmp}/main.out"
  _drive() { # <attempt> <log-dir> [NAME=VALUE ...]
    : >"${calls}"; : >"${reruns}"; : >"${sum}"; : >"${out}"
    local attempt="$1" logdir="$2" kv
    shift 2
    ( export PATH="${bin}:${PATH}" \
             STUB_CALLS="${calls}" STUB_RERUNS="${reruns}" \
             STUB_JOBS_JSON="${tmp}/jobs.json" STUB_LOG_DIR="${logdir}" \
             GITHUB_STEP_SUMMARY="${sum}" GH_TOKEN=stub \
             GITHUB_REPOSITORY='mehmetefeumit/Haven-App' \
             HAVEN_RERUN_RUN_ID=32672237999 HAVEN_RERUN_RUN_ATTEMPT="${attempt}"
      for kv in "$@"; do export "${kv?}"; done
      main ) >"${out}" 2>&1
  }
  _check() { _ok "$1" "$2" "${out}"; }

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
  # …and only `failure` was ever a candidate. Without this the conclusion filter
  # could be relaxed to anything-but-success and every fixture above would stay
  # green, because a cancelled job has no log to fetch and is left red anyway.
  _check "$(grep -qxF '**Left red (1)**' "${sum}" && echo 0 || echo 1)" \
         '(O2) cancelled, skipped and in-progress jobs are not candidates at all'
  # `${out}` is main's own stdout and stderr. Run 35541175084 judged thirteen
  # jobs and left not one word in its log, because every line went to a step
  # summary no API serves; this is the fixture that reds if it goes back.
  _check "$(grep -q 'e2e_integration.*the runner was shut down' "${out}" && echo 0 || echo 1)" \
         '(O2) …and the decision reaches the job log, not only the step summary'

  # (O3) FAIL CLOSED, END TO END. Same run, but no log can be fetched for any
  #      job: nothing may be re-run, and the summary must say why.
  rc=0
  _drive 1 "${tmp}/no-logs-here" || rc=$?
  _check "$([[ "${rc}" == 0 && ! -s "${reruns}" ]] \
            && grep -q 'could not be fetched' "${sum}" && echo 0 || echo 1)" \
         '(O3) unreadable logs re-run nothing and say so'

  # (O4) THE API REFUSES A SANCTIONED RE-RUN. Judged actionable and not acted on
  #      is this script failing, not a verdict, so it must go RED rather than
  #      report a tidy nothing — the one path that makes this workflow visible.
  rc=0
  _drive 1 "${logs}" 'STUB_GH_RERUN_403=97275651481' || rc=$?
  # rc 2 alone would also be satisfied by a misconfigured run that never got as
  # far as judging anything, so each of these reads the reason too.
  _check "$([[ "${rc}" == 2 && ! -s "${reruns}" ]] \
            && grep -q 'a sanctioned re-run was refused' "${out}" && echo 0 || echo 1)" \
         '(O4) a re-run the API refuses exits 2, not 0'
  _check "$(grep -q 'the re-run was refused' "${sum}" && echo 0 || echo 1)" \
         '(O4) …and the annotation says so instead of claiming a re-run'

  # (O5) A FETCH THAT DIED MID-BODY. Fixture C5 measures that real curl leaves
  #      those bytes on disk; `|| rm -f` is what deletes them. The fragment here
  #      DOES carry the shutdown line, and the job is still left red: a
  #      truncated fetch is not evidence, because nothing says what the rest of
  #      the log held. Delete the `rm -f` and this fixture re-runs the job.
  local partial="${tmp}/partiallogs"
  mkdir -p "${partial}"
  cp "${tmp}/test-failure.log" "${partial}/97249491991.log"
  head -3 "${tmp}/runner-loss.log" >"${partial}/97275651481.partial"
  rc=0
  _drive 1 "${partial}" || rc=$?
  _check "$([[ "${rc}" == 0 && ! -s "${reruns}" ]] && echo 0 || echo 1)" \
         '(O5) a log whose fetch died mid-body is deleted, not judged'
  _check "$(grep -q 'e2e_integration.*could not be fetched' "${sum}" && echo 0 || echo 1)" \
         '(O5) …and is reported as unread, not as a failure of its own'

  # (O6) THE LISTING ITSELF REFUSED. "Nothing failed" is the one wrong answer
  #      this script must never give itself, so an unreadable listing is exit 2.
  rc=0
  _drive 1 "${logs}" 'STUB_GH_JOBS_404=1' || rc=$?
  _check "$([[ "${rc}" == 2 && ! -s "${reruns}" ]] \
            && grep -q 'could not list the jobs' "${out}" && echo 0 || echo 1)" \
         '(O6) a jobs listing the API refuses exits 2 and re-runs nothing'

  # (O7) MORE THAN ONE PAGE. `--paginate --slurp` returns an array of pages, and
  #      a run over 100 jobs really is several; a selector reading only the
  #      first would silently stop judging everything past it.
  rc=0
  _drive 1 "${logs}" "STUB_JOBS_JSON=${tmp}/jobs-paged.json" || rc=$?
  _check "$([[ "${rc}" == 0 && "$(cat "${reruns}")" == '97275651481' ]] && echo 0 || echo 1)" \
         '(O7) a runner loss on the second page is still judged and re-run'

  return "${fails}"
}

# The curl stub above STATES what `curl -f` does. This measures it, in the same
# run, against the real binary and a server on 127.0.0.1 — offline, on a port
# the kernel picks — so the fake and the tool cannot drift apart unnoticed. A
# missing binary is six named FAILED fixtures, never a skip: the count stays
# pinned, and "we could not check the stub" reads as what it is.
_real_curl_fixtures() { # <tmp> <stub-bin-dir>
  local tmp="$1" bin="$2" fails=0
  local -a labels=(
    '(C1) real curl -f on an HTTP error exits 22 and writes no file'
    '(C2) the curl stub fails exactly as real curl does'
    '(C3) real curl on a refused connection exits 7 and writes no file'
    '(C4) real curl past --max-time exits 28 and writes no file'
    '(C5) real curl leaves the bytes it got when a transfer dies mid-body'
    '(C6) the curl stub leaves them too, and exits as real curl did'
  )
  _cannot_run() { # <reason>
    local l
    for l in "${labels[@]}"; do _ok 1 "${l} — NOT RUN: $1"; done
  }

  # (C7) Needs no binary, so it is judged before the others can be skipped.
  #      Without both bounds one stalled fetch eats the workflow's whole budget
  #      and the job is cancelled with every judgement still unwritten — and no
  #      behavioural fixture can catch that without waiting out the timeout.
  local flags=" ${CURL_FETCH_FLAGS[*]} "
  _ok "$([[ "${flags}" == *' --connect-timeout '* && "${flags}" == *' --max-time '* ]] \
          && echo 0 || echo 1)" \
      '(C7) the production fetch is bounded by --connect-timeout and --max-time'

  local -a missing=()
  local b
  for b in curl python3; do
    command -v "${b}" >/dev/null 2>&1 || missing+=("${b}")
  done
  if ((${#missing[@]} > 0)); then
    _cannot_run "${missing[*]} absent"
    return 1
  fi

  local py="${tmp}/loopback.py"
  cat >"${py}" <<'PY'
import http.server, socket, socketserver, time

BODY = b"2026-08-23T23:30:05.7050585Z ##[error]The runner has received a shutdown signal.\n"


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/ok":
            self.send_response(200)
            self.send_header("Content-Length", str(len(BODY)))
            self.end_headers()
            self.wfile.write(BODY)
        elif self.path == "/stall":
            # Longer than any --max-time a fixture uses, so the abort is the
            # client's decision and never a race with this thread.
            time.sleep(15)
        elif self.path == "/truncated":
            self.send_response(200)
            self.send_header("Content-Length", str(len(BODY) * 4))
            self.end_headers()
            self.wfile.write(BODY)
            self.wfile.flush()
            self.close_connection = True
            self.connection.close()
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, *a):
        pass


srv = S(("127.0.0.1", 0), H)
shut = socket.socket()
shut.bind(("127.0.0.1", 0))
refused = shut.getsockname()[1]
shut.close()
# listen() already happened in the constructor, so a reader that has seen this
# line can connect without polling for readiness.
print(srv.server_address[1], refused, flush=True)
srv.serve_forever()
PY

  local pipe="${tmp}/port.fifo" srv_err="${tmp}/loopback.err" pfd srv_pid
  mkfifo "${pipe}"
  # O_RDWR on a fifo never blocks, so the bounded `read` below is the only wait
  # in this function: no sleep ever stands in for readiness.
  exec {pfd}<>"${pipe}"
  python3 "${py}" >"${pipe}" 2>"${srv_err}" &
  srv_pid=$!
  # shellcheck disable=SC2064  # expand now: the reap must not depend on a live var
  trap "kill ${srv_pid} 2>/dev/null; wait ${srv_pid} 2>/dev/null; exec ${pfd}>&-" EXIT

  local live='' refused=''
  if ! read -r -t 30 -u "${pfd}" live refused || [[ -z "${live}" || -z "${refused}" ]]; then
    _cannot_run 'the loopback server never reported a port'
    kill "${srv_pid}" 2>/dev/null || true
    wait "${srv_pid}" 2>/dev/null || true
    exec {pfd}>&-
    trap - EXIT
    return 1
  fi

  # Never the port, never the host: a FAIL line carries the exit codes and
  # nothing that identifies where it connected (Rule 15).
  local base="http://127.0.0.1:${live}" detail="${tmp}/curl.detail"
  local real_rc=0 real_err='' stub_rc=0 stub_err=''

  rm -f "${tmp}/c1.out"
  real_err="$( { curl "${CURL_FETCH_FLAGS[@]}" "${base}/missing" -o "${tmp}/c1.out"; } 2>&1 )" \
    || real_rc=$?
  printf 'real: rc=%s\n' "${real_rc}" >"${detail}"
  _ok "$([[ "${real_rc}" == 22 && ! -e "${tmp}/c1.out" ]] && echo 0 || echo 1)" \
      "${labels[0]}" "${detail}"

  # The stub is driven through the same argv production builds, so a flag change
  # in fetch_job_log is a flag change here.
  rm -f "${tmp}/c2.out"
  stub_err="$( { STUB_LOG_DIR="${tmp}/no-logs-here" "${bin}/curl" "${CURL_FETCH_FLAGS[@]}" \
                   'https://api.github.com/repos/o/r/actions/jobs/1/logs' \
                   -o "${tmp}/c2.out"; } 2>&1 )" || stub_rc=$?
  printf 'real: rc=%s err=%s\nstub: rc=%s err=%s\n' \
    "${real_rc}" "${real_err}" "${stub_rc}" "${stub_err}" >"${detail}"
  _ok "$([[ "${stub_rc}" == "${real_rc}" && ! -e "${tmp}/c2.out" \
            && "${stub_err}" == "${real_err}" ]] && echo 0 || echo 1)" \
      "${labels[1]}" "${detail}"

  rm -f "${tmp}/c3.out"
  real_rc=0
  curl "${CURL_FETCH_FLAGS[@]}" "http://127.0.0.1:${refused}/ok" -o "${tmp}/c3.out" \
    >/dev/null 2>&1 || real_rc=$?
  printf 'real: rc=%s\n' "${real_rc}" >"${detail}"
  _ok "$([[ "${real_rc}" == 7 && ! -e "${tmp}/c3.out" ]] && echo 0 || echo 1)" \
      "${labels[2]}" "${detail}"

  # The production flags with --max-time overridden, because a fixture cannot
  # wait out the 60 s the real fetch is allowed; the flag under test is the one
  # fetch_job_log passes.
  rm -f "${tmp}/c4.out"
  real_rc=0
  curl "${CURL_FETCH_FLAGS[@]}" --max-time 1 "${base}/stall" -o "${tmp}/c4.out" \
    >/dev/null 2>&1 || real_rc=$?
  printf 'real: rc=%s\n' "${real_rc}" >"${detail}"
  _ok "$([[ "${real_rc}" == 28 && ! -e "${tmp}/c4.out" ]] && echo 0 || echo 1)" \
      "${labels[3]}" "${detail}"

  # The measurement `|| rm -f` in fetch_job_log exists for: a failed transfer
  # CAN leave a half-log behind, and a half-log must never be classified.
  rm -f "${tmp}/c5.out"
  real_rc=0
  curl "${CURL_FETCH_FLAGS[@]}" "${base}/truncated" -o "${tmp}/c5.out" \
    >/dev/null 2>&1 || real_rc=$?
  printf 'real: rc=%s\n' "${real_rc}" >"${detail}"
  _ok "$([[ "${real_rc}" == 18 && -s "${tmp}/c5.out" ]] && echo 0 || echo 1)" \
      "${labels[4]}" "${detail}"

  mkdir -p "${tmp}/stubpartial"
  head -3 "${tmp}/runner-loss.log" >"${tmp}/stubpartial/1.partial"
  rm -f "${tmp}/c6.out"
  stub_rc=0
  STUB_LOG_DIR="${tmp}/stubpartial" "${bin}/curl" "${CURL_FETCH_FLAGS[@]}" \
    'https://api.github.com/repos/o/r/actions/jobs/1/logs' -o "${tmp}/c6.out" \
    >/dev/null 2>&1 || stub_rc=$?
  printf 'real: rc=%s\nstub: rc=%s\n' "${real_rc}" "${stub_rc}" >"${detail}"
  _ok "$([[ "${stub_rc}" == "${real_rc}" && -s "${tmp}/c6.out" ]] && echo 0 || echo 1)" \
      "${labels[5]}" "${detail}"

  kill "${srv_pid}" 2>/dev/null || true
  wait "${srv_pid}" 2>/dev/null || true
  exec {pfd}>&-
  trap - EXIT
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
