#!/usr/bin/env bash
#
# CI guard: every lane that captures a log runs the log-privacy wrapper over
# it, before anything echoes or uploads it — and nothing a lane captures can
# slip past the wrapper by being named somewhere the wrapper is not.
#
# ## Why this exists
#
# The wrapper (`tooling/e2e/ci/scan-logs.sh`: the key-material floor AND the
# runtime identifier scanner, delete-on-leak, fail-closed) is only a guarantee
# where it RUNS. Until Phase 0c it ran in one lane; the other sixteen scanned
# with the bare floor, and two uploaded files no scanner had read
# (`e2e-ios.yml`'s proxy log and wire summary — `logs=(…)` and `path:` were two
# hand-kept lists that had already drifted by two entries). Nothing owned the
# question "does every capture reach the wrapper?", so the answer decayed
# silently. This guard owns it. The runtime scanner's own contract is the
# crate's tests; the wrapper's is its `--self-test`; the runners' gate wiring
# is each runner's `--self-test`. What is left, and what this checks, is the
# WORKFLOW half: which jobs capture, which files they upload, and whether the
# wrapper stands between the two.
#
# ## What is checked, per job, derived from the workflow text
#
#   (a) WIRED. A job that captures a device, simulator or test log — an
#       `adb logcat`, `log show` or `flutter drive` command, a `cargo test` or
#       `flutter test` tee'd to a file, a lane runner (`bash …/run-*.sh` other
#       than the deadline wrapper, and never a `--self-test`), or an
#       upload-artifact `path:` naming a `.log` — invokes scan-logs.sh at a
#       command position, or invokes a runner from RUNNER_PINS: the checked-in
#       list of `run-*.sh` scripts that source logscan-gate.sh, each paired
#       with the label of the fixture in its own `--self-test` that pins the
#       gate ahead of every echo. The list is reconciled against the harness
#       both ways (a runner that sources the gate must be listed; a listed
#       runner must still source it, call it at a command position, and carry
#       its pin), so the list cannot rot in either direction.
#   (b) UPLOADED ⇒ SCANNED. Every non-wildcard `.log` an upload-artifact step
#       names is a `--sink` member earlier in the same job — a literal, a
#       member of an array literal the `--sink` expands, or a token on a line
#       that assigns the variable the `--sink` expands — or is handed to the
#       gate by a listed runner the job invoked earlier, or is in
#       UPLOAD_ALLOWLIST with the reason it is scanned elsewhere.
#   (c) SCAN BEFORE ECHO. No `cat`/`tail`/`head`/`less`/`more` of a `.log` at a
#       command position precedes the job's first wrapper or runner invocation.
#       Inside the runners the same ordering is each runner's own pin fixture,
#       which (a) requires by name.
#   (d) NO TRACE. No `set -x`, `set -o xtrace` or `bash -x` in
#       `tooling/e2e/ci/*.sh`: a traced runner prints every argument — the
#       host declarations and the manifest path among them — into the job log.
#   (e) NO UNSCANNABLE UPLOAD. No upload names a `.logarchive` (a binary
#       full-device capture nothing here can read) or a `.txt` (the wrapper's
#       directory walk types `*.log` only, so a `.txt` diag leaves the runner
#       unscanned) unless UPLOAD_ALLOWLIST says why. The `.ndjson`, needle and
#       bare-wildcard bans stay in check_wire_proxy_test_only.sh.
#   (f) TEE'D ⇒ SCANNED. Every `| tee <file>.log` capture of a test run is a
#       `--sink` member later in the same job — the four `cargo test`
#       transcripts in rust-check.yml and the two `flutter test` transcripts in
#       coverage.yml — with a floor on how many such captures exist.
#   (g) RULES-ONLY IS FOR TRANSCRIPTS. `--rules-only` (no manifest: the rules
#       ran, nothing declared was searched) appears in rust-check.yml and
#       coverage.yml only, and in no lane runner. The `rust-test` SINK CLASS is
#       confined the same way, to rust-check.yml alone, because that class is
#       the one that exempts cargo's crate-build line from S2 and S6
#       (`cargo_status = "exempt"` in tooling/logscan/policy.toml). Typing any
#       other capture as `rust-test` would carry the exemption to a log cargo
#       never wrote — and a device log CAN hold a line of that shape, since the
#       app is free to print anything.
#   (h) A RECORDING LANE DECLARES, ACCOUNTS AND DISCARDS. Every job that
#       starts the wire proxy declares `HAVEN_LOGSCAN_PROFILE: proxy` at job
#       level (the runners infer `proxy` from the recorder's exports when it
#       is unset, but the stated line is what a reader and the iOS pre-build
#       refusal check, and a job that dropped it once sealed the weaker
#       `host` profile by default), runs check-proxy-sidecar-summary.sh after
#       the proxy start and ends with an `if: always()` step removing all
#       three needle shapes, after every upload.
#   (i) A SCANNING LANE BUILDS AND ROTATES. Every job declaring
#       `HAVEN_LOGSCAN: "true"` at job level builds the scanner before its
#       first capture, rotates the needle directory (the inline
#       `mkdir -m 0700 -p` plus the three `rm -f` shapes, or
#       rotate-needle-dir.sh) before its first capture, and discards as in (h).
#
#   (h) and (i) are asked by what a job STARTS or DECLARES, not by what it
#   captures: a proxy-starting or flag-on job whose capture this guard does
#   not recognise still owes its profile, build, rotation and discard.
#
# Plus: NO_CAPTURE_WORKFLOWS records the workflows that run tests-shaped steps
# without capturing anything (flutter-check.yml runs `flutter analyze` only);
# an entry whose workflow starts capturing is stale and reds, so the record
# is re-decided rather than silently outgrown. A floor on the number of
# capturing jobs found, a floor on the tee'd transcripts, and a raw-grep
# cross-check that the extractor attributed every wrapper invocation to a job,
# keep the guard from decaying into a rubber stamp when a workflow convention
# changes under it.
#
# ## How the workflow text is read
#
# A `run:`, `command:` (nick-fields/retry) or `script:` (the emulator runner)
# value, with `\` continuations joined, is one LINE; a line split at `||`,
# `&&`, `|`, `;` and the `(`/`{` that open a subshell or group is a FRAGMENT.
# `${` and `$(` never split, so a `${RUNNER_TEMP}/x.log` survives whole.
# Fragments answer "what command runs here" (captures, runners, reads); lines
# answer "what does this `--sink` name". A pipe inside a quoted regex still
# splits — the cost of not parsing shell — and yields fragments no rule reads
# as a command word.
#
# Every grep whose verdict matters reads its input to the end: `… | grep -q`
# under `pipefail` is a race in which the producer takes SIGPIPE and the
# pipeline reports failure for a file that DID match, so a large runner
# vanished from the gated list on some runs and not others.
#
# ## What is deliberately NOT here
#
#   * "a recording lane declares HAVEN_LOGSCAN" — check_wire_oracle_lane_reachable.sh
#     link 5, keyed on the runner regex it widens per runner.
#   * upload bans on `.ndjson`, needle files, `/tmp/**` — check_wire_proxy_test_only.sh.
#   * `HAVEN_LOGSCAN_BIN`, `--disclose-values` — the same guard.
#   * the wrapper's fold/containment, the runners' gate argv — their own self-tests.
#   * step/job timeout ordering and lane budgets — their own guards.
#
# Usage:
#   check_logscan_wired_everywhere.sh              # enforce over the repo
#   check_logscan_wired_everywhere.sh --self-test  # hermetic fixtures, count pinned
#
# Exit codes:
#   0  every rule holds
#   1  a violation was found
#   2  the guard could not see the repository (extractor mismatch, floor, self-test failure)

set -euo pipefail

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SELF_NAME
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

readonly WRAPPER_RE='tooling/e2e/ci/scan-logs[.]sh'
# A runner is INVOKED when `bash` runs it; `test -f …/run-x.sh` names one.
readonly RUNNER_INVOKE_RE='(^|[[:space:]])bash[[:space:]]+[^[:space:]]*tooling/e2e/ci/run-[A-Za-z0-9._-]+[.]sh'
readonly RUNNER_NAME_RE='run-[A-Za-z0-9._-]+[.]sh'
readonly DEADLINE_RUNNER='run-with-deadline.sh'
readonly CAPTURE_CMD_RE='(^|[[:space:]])(adb[[:space:]]+logcat|log[[:space:]]+show|flutter[[:space:]]+drive)([[:space:]]|$)'
readonly TEST_TEE_RE='(^|[[:space:]])(cargo|flutter)[[:space:]]+test([[:space:]]|$)'
readonly READ_CMD_RE='^(cat|tail|head|less|more)([[:space:]]|$)'
readonly LOG_TOKEN_RE='[^[:space:]"'"'"'=,()]+[.]log'
readonly PROXY_START_RE='tooling/e2e/ci/start-wire-proxy[.]sh'
readonly SIDECAR_SUMMARY_RE='tooling/e2e/ci/check-proxy-sidecar-summary[.]sh'
readonly SCANNER_BUILD_RE='cargo[[:space:]]+build[[:space:]]+--release[[:space:]]+--manifest-path[[:space:]]+tooling/logscan/Cargo[.]toml'
readonly NEEDLE_DIR='/tmp/haven-soak/needles'
readonly ROTATE_SCRIPT_RE='tooling/e2e/ci/rotate-needle-dir[.]sh'
readonly GATE_CALL_RE='^[[:space:]]*(if[[:space:]]+(![[:space:]]*)?)?(logscan_gate|logscan_gate_dir|logscan_seal)([[:space:]]|$)'
readonly GATE_SOURCE_RE='^[[:space:]]*(source|[.])[[:space:]].*logscan-gate[.]sh'
readonly RULES_ONLY_RE='--rules-only|logscan_gate[[:space:]]+rules([[:space:]]|$)'
readonly XTRACE_RE='(^|[[:space:];&|(])(set[[:space:]]+(-[a-zA-Z]*x[a-zA-Z]*|[+]x|-o[[:space:]]+xtrace)|bash[[:space:]]+-x)([[:space:]]|$)'
readonly RULES_ONLY_WORKFLOWS=('rust-check.yml' 'coverage.yml')
# The `rust-test` sink class carries the cargo-status exemption, so it belongs to
# the workflow that scans cargo transcripts and nowhere else. coverage.yml's
# `flutter test` logs are `drive`, which has no exemption of any kind.
readonly RUST_TEST_SINK_RE='--sink[[:space:]]+rust-test='
readonly RUST_TEST_SINK_WORKFLOWS=('rust-check.yml')

# Measured 2026-09-16: 18 e2e jobs + rust-check's four + coverage's flutter
# job = 23 capturing jobs; the floor is 80 % of that. Six tee'd transcripts —
# one fewer is a scan that stopped, which is a decision to record here.
readonly MIN_CAPTURING_JOBS=18
readonly MIN_TEE_CAPTURES=6

# The gated runners: every `run-*.sh` that sources logscan-gate.sh, paired
# with the label of the fixture in its own --self-test that pins the gate
# ahead of every echo of a captured log. A runner joins this list in the
# commit that gives it the arm; the reconciliation below refuses one without
# the other. The self-test overrides this table with its own fake runner.
declare -A RUNNER_PINS=(
  ['run-single-avd-scenario.sh']='SELF-TEST FAIL (9b): the drive log is echoed at line'
  ['run-ios-sim-scenario.sh']='SELF-TEST FAIL (S2): the transcript is echoed at top level'
  ['run-ios-bg-publish.sh']='G4 the real run gates the preserved log between the copy and the drive'
  ['run-integration-tests.sh']='SELF-TEST FAIL (wiring): this runner echoes a captured log itself; only the AVD runner may, after its gate'
  ['run-relay-customization.sh']='SELF-TEST FAIL (wiring): this runner echoes a captured log itself; only the AVD runner may, after its gate'
  ['run-flake-stress.sh']='SELF-TEST FAIL (wiring): this runner echoes a captured log itself; only the AVD runner may, after its gate'
  ['run-m7-background-catchup.sh']='SELF-TEST FAIL (wiring): a captured log is echoed outside echo_log_tail/drive_target, i.e. before any gate'
  ['run-b1-fgs-publish.sh']='SELF-TEST FAIL (67): the drive log must be echoed exactly once, after the'
  ['run-b3-real-gps.sh']='_case "the drive log is echoed only after the log-privacy gate"'
  ['run-b5-permission-revocation.sh']='_case "the drive log is echoed only after the log-privacy gate"'
  ['run-b6-location-provider-toggle.sh']='_case "the drive log is echoed only after the log-privacy gate"'
  ['run-b8-clock-skew.sh']='SELF-TEST FAIL (19): the drive log must be echoed exactly once, after the'
  ['run-b9-network-reconnect.sh']='_case "the drive log is echoed only after the log-privacy gate"'
  ['run-kp-rotation.sh']='_case "the drive log is echoed only after the log-privacy gate"'
)

# Uploaded paths that are scanned by their producer rather than by a `--sink`
# in the job. Each entry carries where the scan is.
declare -A UPLOAD_ALLOWLIST=(
  ['/tmp/haven-egress/egress-raw.log']='written and passed through the key-material floor by setup-network-guard.sh (report) before it returns; the egress capture holds kernel connection lines, no app output'
  ['/tmp/haven-egress/egress-summary.txt']='the PROTO/DST/PORT/UID digest setup-network-guard.sh derives from the raw capture and scans with it in the same call'
)

# Workflows with test-shaped steps that capture nothing. Pinned so that the
# day one of them starts capturing, the record is re-decided in the diff.
declare -A NO_CAPTURE_WORKFLOWS=(
  ['flutter-check.yml']='its only job, analyze, runs `flutter analyze` and nothing else — no `flutter test`, no tee, no `.log`, no upload'
)

VIOLATIONS=0
BROKEN=0
violation() { printf 'FAIL: %s\n' "$*" >&2; VIOLATIONS=$((VIOLATIONS + 1)); }
broken()    { printf 'BROKEN: %s\n' "$*" >&2; BROKEN=$((BROKEN + 1)); }
log()       { printf '[%s] %s\n' "${SELF_NAME}" "$*"; }

# ---------------------------------------------------------------------------
# Extractor. Flattens a workflow into TAB-separated records:
#
#   <basename>\t<job-id>\t<step-index>\t<line-no>\t<kind>\t<text>
#
# Step index 0 is the job-level block above `steps:` (where `env:` lives).
# `kind` is `cmd` for shell text (a `run:`/`command:`/`script:` value and the
# lines of its block scalar), `path` for an upload `path:` value and its block,
# `other` for everything else. Full-line comments are dropped — inside a
# `run: |` they are shell comments, inside a `path: |` upload-artifact ignores
# them — so a commented-out wrapper call is neither counted nor credited.
# ---------------------------------------------------------------------------
emit_records() { # emit_records <workflow-file>
  awk -v base="${1##*/}" '
    function emit(kind, text) { printf "%s\t%s\t%d\t%d\t%s\t%s\n", base, job, stepidx, NR, kind, text }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[^[:space:]]/ {
      injobs = ($0 ~ /^jobs:[[:space:]]*(#.*)?$/) ? 1 : 0
      job = ""; insteps = 0; stepindent = -1; stepidx = 0; blk = ""; blkind = -1
      next
    }
    !injobs { next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*(#.*)?$/ {
      job = $0
      sub(/^  /, "", job)
      sub(/:[[:space:]]*(#.*)?$/, "", job)
      insteps = 0; stepindent = -1; stepidx = 0; blk = ""; blkind = -1
      next
    }
    job == "" { next }
    /^[[:space:]]*steps:[[:space:]]*(#.*)?$/ {
      insteps = 1; stepindent = -1; stepidx = 0; blk = ""; blkind = -1
      next
    }
    {
      ind = match($0, /[^ ]/) - 1
      text = $0; sub(/^[[:space:]]+/, "", text)
      if (insteps && text ~ /^-[[:space:]]/) {
        if (stepindent < 0) stepindent = ind
        if (ind == stepindent) stepidx++
      }
      # A line deeper than an open block key is that block'"'"'s body.
      if (blk != "" && ind > blkind) { emit(blk, text); next }
      blk = ""; blkind = -1
      key = text; sub(/^-[[:space:]]+/, "", key)
      if (match(key, /^[A-Za-z_-]+:([[:space:]]|$)/)) {
        k = substr(key, 1, RLENGTH); sub(/:.*/, "", k)
        v = substr(key, RLENGTH + 1); sub(/^[[:space:]]+/, "", v)
        if (k == "run" || k == "command" || k == "script") {
          if (v ~ /^[|>]/) { blk = "cmd"; blkind = ind } else emit("cmd", v)
          next
        }
        if (k == "path") {
          if (v ~ /^[|>]/) { blk = "path"; blkind = ind } else emit("path", v)
          next
        }
      }
      emit("other", text)
    }
  ' "$1"
}

job_records()  { awk -F'\t' -v f="$2" -v j="$3" '$1 == f && $2 == j' <<<"$1"; }
step_records() { awk -F'\t' -v f="$2" -v j="$3" -v s="$4" '$1 == f && $2 == j && $3 == s' <<<"$1"; }
text_of()      { cut -f6-; }

# Shell LINES as `<step>\t<line>\t<text>`: `\` continuations joined (the joined
# line keeps its first line's number).
job_lines() { # job_lines <job-records>
  awk -F'\t' '$5 == "cmd" { print $3 "\t" $4 "\t" $6 }' <<<"$1" | awk -F'\t' '
    {
      if (buf == "") { step = $1; line = $2; buf = $3 } else buf = buf " " $3
      if (buf ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", buf); next }
      printf "%s\t%s\t%s\n", step, line, buf
      buf = ""
    }
    END { if (buf != "") printf "%s\t%s\t%s\n", step, line, buf }'
}

# Shell FRAGMENTS, one command per line, as `<step>\t<line>\t<command>`: each
# line split at `|`, `&&`, `||`, `;`, `(`, `{` — never inside `${…}`/`$(…)` —
# with the `if`/`then`/`do`/`else`/`!` words that open a command stripped.
job_cmds() { # job_cmds <job-records>
  job_lines "$1" | awk -F'\t' '
    {
      s = $3
      gsub(/\$\{/, "\001", s); gsub(/\$\(/, "\002", s)
      n = split(s, parts, /\|\||&&|[|;({]/)
      for (i = 1; i <= n; i++) {
        c = parts[i]
        gsub("\001", "${", c); gsub("\002", "$(", c)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
        while (c ~ /^(if|elif|while|then|do|else|!)([[:space:]]|$)/) { sub(/^[a-z!]+[[:space:]]*/, "", c) }
        if (c != "") printf "%s\t%s\t%s\n", $1, $2, c
      }
    }'
}

# `<step>\t<line>\t<path>` for every path an upload-artifact step names.
job_upload_paths() { # job_upload_paths <job-records>
  local recs="$1" steps s
  steps="$(awk -F'\t' '$5 == "other" && $6 ~ /^-?[[:space:]]*uses:[[:space:]]*actions\/upload-artifact/ { print $3 }' <<<"${recs}" | sort -un)"
  for s in ${steps}; do
    awk -F'\t' -v s="${s}" '$3 == s && $5 == "path" { p = $6; sub(/^-[[:space:]]+/, "", p); gsub(/^[[:space:]]+|[[:space:]]+$/, "", p); if (p != "") print $3 "\t" $4 "\t" p }' <<<"${recs}"
  done
}

step_if() { # step_if <job-records> <step>  → the step'"'"'s if: value, or ""
  awk -F'\t' -v s="$2" '$3 == s && $5 == "other" && $6 ~ /^-?[[:space:]]*if:/ { v = $6; sub(/^-?[[:space:]]*if:[[:space:]]*/, "", v); print v; exit }' <<<"$1"
}

# Every `.log` token a `--sink` line names, one per line as `<line>\t<path>`:
# the tokens from the first `--sink` onward, and — when the `--sink` expands a
# variable (`${arr[*]}`, `${arr[@]}`, `${joined}`) — the tokens on every line
# of the job that assigns it. A `[[ -f x.log ]]` existence test names a file
# without handing it to anything, so test clauses are dropped first.
credit_text() { sed -E 's/\[\[[^]]*\]\]//g; s/(^|[[:space:]])\[[[:space:]][^]]*\]//g' <<<"$1"; }
sink_paths() { # sink_paths <lines>
  local lines="$1" line text var
  while IFS=$'\t' read -r _ line text; do
    [[ "${text}" == *'--sink'* ]] || continue
    text="$(credit_text "${text}")"
    grep -oE -- "${LOG_TOKEN_RE}" <<<"${text#*--sink}" | sed "s/^/${line}\t/" || true
    for var in $(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*(\[[*@]\])?\}?' <<<"${text}" | sed -E 's/^\$\{?([A-Za-z0-9_]+).*/\1/' | sort -u); do
      awk -F'\t' -v v="${var}" '$3 ~ ("(^|[[:space:];&|(])" v "\\+?=")' <<<"${lines}" \
        | while IFS=$'\t' read -r _ aline atext; do
            grep -oE -- "${LOG_TOKEN_RE}" <<<"$(credit_text "${atext}")" | sed "s/^/${aline}\t/" || true
          done
    done
  done <<<"${lines}"
}

# The `.log` paths a listed runner hands to the gate, from its gate-call
# lines with continuations joined.
runner_gate_paths() { # runner_gate_paths <runner-file>
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0; sub(/^[[:space:]]+/, " ", line); buf = buf line
      if (buf ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", buf); next }
      print buf; buf = ""
    } END { if (buf != "") print buf }' "$1" \
    | awk '/^ ?(if[[:space:]]+(![[:space:]]*)?)?(logscan_gate|logscan_gate_dir|log_privacy_gate|scan_log_or_contain|bgp_scan_or_contain|scan_logs_or_contain)[[:space:]]/' \
    | grep -oE -- "${LOG_TOKEN_RE}" || true
}

strip_redirects() { sed -E 's/[0-9]*>>?[[:space:]]*[^[:space:]]+//g; s/[0-9]*>&[0-9]//g' <<<"$1"; }

# ---------------------------------------------------------------------------
# The gated runner list, reconciled against the harness both ways.
# ---------------------------------------------------------------------------
GATED_RUNNERS=""
reconcile_gated_runners() { # reconcile_gated_runners <harness-dir>
  local f base sourced calls rules
  GATED_RUNNERS=""
  for f in "$1"/run-*.sh; do
    [[ -f "${f}" ]] || continue
    base="${f##*/}"
    sourced="$(grep -cE -- "${GATE_SOURCE_RE}" "${f}" || true)"
    if (( sourced == 0 )); then
      if [[ -n "${RUNNER_PINS[${base}]+x}" ]]; then
        violation "tooling/e2e/ci/${base} is in RUNNER_PINS but no longer sources logscan-gate.sh. Either it lost the arm — restore it — or the arm moved elsewhere, in which case the entry is a stale claim; delete it in the same change."
      fi
      continue
    fi
    GATED_RUNNERS+="${base}"$'\n'
    if [[ -z "${RUNNER_PINS[${base}]+x}" ]]; then
      violation "tooling/e2e/ci/${base} sources logscan-gate.sh but is not in RUNNER_PINS. A runner joins the list in the commit that gives it the arm, paired with the label of the fixture in its --self-test that pins the gate ahead of every echo of a captured log; without that pin a moved or deleted gate call reds nothing."
      continue
    fi
    calls="$(grep -cE -- "${GATE_CALL_RE}" "${f}" || true)"
    if (( calls == 0 )); then
      violation "tooling/e2e/ci/${base} sources logscan-gate.sh but never calls logscan_gate, logscan_gate_dir or logscan_seal at a command position — a sourced gate nobody calls scans nothing."
    fi
    if ! grep -qF -- '--self-test' "${f}"; then
      violation "tooling/e2e/ci/${base} has no --self-test, so nothing pins its gate wiring; every gated runner carries a source-pin fixture (the gate stands before every echo of a captured log)."
    elif ! grep -qF -- "${RUNNER_PINS[${base}]}" "${f}"; then
      violation "tooling/e2e/ci/${base} no longer carries its wiring-pin fixture (RUNNER_PINS names \`${RUNNER_PINS[${base}]}\`). That fixture is what reds the runner's own self-test when its gate call moves below an echo; if the label changed, re-pin it here in the same change."
    fi
    rules="$(grep -E -- "${RULES_ONLY_RE}" "${f}" | grep -vcE '^[[:space:]]*#' || true)"
    if (( rules > 0 )); then
      violation "tooling/e2e/ci/${base} uses --rules-only (or the rules profile): a lane runner scans a capture from a run that minted real values, so the manifest is available and the needle search is the point. --rules-only is for the unit-test transcripts in rust-check.yml and coverage.yml only."
    fi
  done
  local listed
  for listed in "${!RUNNER_PINS[@]}"; do
    [[ -f "$1/${listed}" ]] || violation "RUNNER_PINS names tooling/e2e/ci/${listed}, which does not exist. A pin for a runner that is gone is a claim nobody can check; delete the entry."
  done
  GATED_RUNNERS="$(grep -v '^$' <<<"${GATED_RUNNERS}" || true)"
}

# ---------------------------------------------------------------------------
# Per-job rules.
# ---------------------------------------------------------------------------
CAPTURING_JOBS=0
TEE_CAPTURES=0

check_job() { # check_job <records> <file> <job> <harness-dir>
  local records="$1" file="$2" job="$3" harness="$4"
  local recs lines cmds uploads where="${file}:${job}"
  recs="$(job_records "${records}" "${file}" "${job}")"
  lines="$(job_lines "${recs}")"
  cmds="$(job_cmds "${recs}")"
  uploads="$(job_upload_paths "${recs}")"

  # --- what this job captures ------------------------------------------------
  local capture_line="" line cmd step
  local tee_targets="" runner_lines="" gated_runner_lines="" wrapper_lines=""
  while IFS=$'\t' read -r step line cmd; do
    [[ -n "${cmd}" ]] || continue
    if [[ "${cmd}" =~ ${CAPTURE_CMD_RE} ]]; then
      [[ -n "${capture_line}" ]] || capture_line="${line}"
    fi
    if [[ "${cmd}" =~ ${TEST_TEE_RE} ]]; then
      # The transcript is on disk only when tee'd; a test run that streams
      # into the job log alone leaves nothing a wrapper could read.
      local nxt
      nxt="$(awk -F'\t' -v l="${line}" '$2 == l && $3 ~ /^tee[[:space:]]/ { print $3; exit }' <<<"${cmds}")"
      if [[ -n "${nxt}" ]]; then
        [[ -n "${capture_line}" ]] || capture_line="${line}"
        local t
        t="$(grep -oE -- "${LOG_TOKEN_RE}" <<<"${nxt}" | awk 'NR == 1' || true)"
        [[ -z "${t}" ]] || tee_targets+="${line}"$'\t'"${t}"$'\n'
      fi
    fi
    if [[ "${cmd}" =~ ${RUNNER_INVOKE_RE} && "${cmd}" != *'--self-test'* ]]; then
      local r
      for r in $(grep -oE -- "${RUNNER_NAME_RE}" <<<"${cmd}" | sort -u); do
        [[ "${r}" != "${DEADLINE_RUNNER}" ]] || continue
        [[ -n "${capture_line}" ]] || capture_line="${line}"
        runner_lines+="${line}"$'\t'"${r}"$'\n'
        if grep -qxF -- "${r}" <<<"${GATED_RUNNERS}"; then gated_runner_lines+="${line}"$'\t'"${r}"$'\n'; fi
      done
    fi
    [[ "${cmd}" =~ ${WRAPPER_RE} ]] && wrapper_lines+="${line}"$'\n'
  done <<<"${cmds}"
  local uploads_logs
  uploads_logs="$(awk -F'\t' '$3 ~ /[.]log$/' <<<"${uploads}" || true)"
  if [[ -z "${capture_line}" && -n "${uploads_logs}" ]]; then
    capture_line="$(awk -F'\t' 'NR == 1 { print $2 }' <<<"${uploads_logs}")"
  fi
  # --- (h)/(i) accounting, rotation, build, discard --------------------------------------
  local proxy_line logscan_decl
  proxy_line="$(awk -F'\t' -v re="${PROXY_START_RE}" '$3 ~ re { print $2; exit }' <<<"${cmds}")"
  logscan_decl="$(step_records "${records}" "${file}" "${job}" 0 | text_of | awk '/^HAVEN_LOGSCAN[[:space:]]*:/ { print; exit }')"
  local flag_on=0
  if [[ -n "${logscan_decl}" ]]; then
    local v="${logscan_decl%%#*}"; v="${v#*:}"; v="${v//[[:space:]\"\']/}"
    [[ "${v}" == "true" ]] && flag_on=1
  fi
  if [[ -n "${proxy_line}" || "${flag_on}" == 1 ]]; then
    # The discard: an `if: always()` step after every upload whose command
    # removes all three shapes.
    local last_upload discard_ok=0 dstep dline dcmd dif
    last_upload="$(cut -f2 <<<"${uploads}" | sort -n | tail -n 1)"
    while IFS=$'\t' read -r dstep dline dcmd; do
      [[ -n "${dcmd}" ]] || continue
      [[ "${dcmd}" =~ ^rm[[:space:]]+-f[[:space:]] ]] || continue
      [[ "${dcmd}" == *"${NEEDLE_DIR}/*.needles.decl"* && "${dcmd}" == *"${NEEDLE_DIR}/*.needles.json"* && "${dcmd}" == *"${NEEDLE_DIR}/*.canaries.json"* ]] || continue
      dif="$(step_if "${recs}" "${dstep}")"
      [[ "${dif//[[:space:]]/}" =~ ^(\$\{\{)?always\(\)(\}\})?$ ]] || continue
      (( dline > ${last_upload:-0} )) || continue
      discard_ok=1
    done <<<"${cmds}"
    if (( ! discard_ok )); then
      violation "${where}: this job $( [[ -n "${proxy_line}" ]] && echo 'starts the recording proxy' || echo 'runs the identifier scanner (HAVEN_LOGSCAN: \"true\")' ) but has no final \`if: always()\` step, after every upload-artifact step, that removes ${NEEDLE_DIR}/*.needles.decl, *.needles.json and *.canaries.json. Those files hold the run's identifiers verbatim; a reused runner must not start the next run holding them."
    fi
  fi
  if [[ -n "${proxy_line}" ]]; then
    local profile_decl pv=""
    profile_decl="$(step_records "${records}" "${file}" "${job}" 0 | text_of | awk '/^HAVEN_LOGSCAN_PROFILE[[:space:]]*:/ { print; exit }')"
    if [[ -n "${profile_decl}" ]]; then
      pv="${profile_decl%%#*}"; pv="${pv#*:}"; pv="${pv//[[:space:]\"\']/}"
    fi
    if [[ "${pv}" != proxy ]]; then
      violation "${where}: this job starts the recording proxy (line ${proxy_line}) but does not declare HAVEN_LOGSCAN_PROFILE: proxy at job level$( [[ -z "${pv}" ]] || printf ' (it declares %s)' "${pv}"). The runners infer \`proxy\` from the recorder's exports when the variable is unset, but the stated line is what a reader and the iOS pre-build refusal check; declare it beside HAVEN_LOGSCAN in the job's env block."
    fi
    if ! awk -F'\t' -v re="${SIDECAR_SUMMARY_RE}" -v l="${proxy_line}" '$3 ~ re && $2 + 0 > l + 0 { f = 1 } END { exit !f }' <<<"${cmds}"; then
      violation "${where}: this job starts the recording proxy (line ${proxy_line}) but never runs tooling/e2e/ci/check-proxy-sidecar-summary.sh after it. The recorder's shutdown summary is the only place a run says whether its declaration channel recorded, refused or lost a declaration or found a STALE sidecar; without reading it, a manifest sealed from a partial sidecar reads as complete."
    fi
  fi
  if (( flag_on )); then
    # No recognised capture: the build and the rotation are required anywhere
    # in the job rather than before a line that does not exist.
    local cap_ref="${capture_line:-999999999}" cap_desc="${capture_line:-none recognised}"
    if ! awk -F'\t' -v re="${SCANNER_BUILD_RE}" -v l="${cap_ref}" '$3 ~ re && $2 + 0 < l + 0 { f = 1 } END { exit !f }' <<<"${cmds}"; then
      violation "${where}: HAVEN_LOGSCAN is \"true\" but no step before the first capture (line ${cap_desc}) builds the scanner (\`cargo build --release --manifest-path tooling/logscan/Cargo.toml\`). The gate treats an absent binary as a broken guard (rc 2), so this lane would be red on every run — build it before the capture, under the job's rust-cache."
    fi
    local rotate_ok=0 mk_line rm_line
    mk_line="$(awk -F'\t' -v d="${NEEDLE_DIR}" -v l="${cap_ref}" '$3 ~ ("^mkdir[[:space:]]+-m[[:space:]]+0700[[:space:]]+-p[[:space:]]+" d "([[:space:]]|$)") && $2 + 0 <= l + 0 { print $2; exit }' <<<"${cmds}")"
    rm_line="$(awk -F'\t' -v d="${NEEDLE_DIR}" -v l="${cap_ref}" '$3 ~ /^rm[[:space:]]+-f[[:space:]]/ && index($3, d "/*.needles.decl") && index($3, d "/*.needles.json") && index($3, d "/*.canaries.json") && $2 + 0 <= l + 0 { print $2; exit }' <<<"${cmds}")"
    [[ -n "${mk_line}" && -n "${rm_line}" ]] && rotate_ok=1
    awk -F'\t' -v re="${ROTATE_SCRIPT_RE}" -v l="${cap_ref}" '$3 ~ re && $2 + 0 <= l + 0 { f = 1 } END { exit !f }' <<<"${cmds}" && rotate_ok=1
    if (( ! rotate_ok )); then
      violation "${where}: HAVEN_LOGSCAN is \"true\" but the needle directory is not rotated before the first capture (line ${cap_desc}): neither \`mkdir -m 0700 -p ${NEEDLE_DIR}\` plus an \`rm -f\` of all three shapes (*.needles.decl, *.needles.json, *.canaries.json), nor tooling/e2e/ci/rotate-needle-dir.sh. A sidecar or manifest left by a previous run on a reused runner would be sealed into — or reused as — this run's."
    fi
  fi

  [[ -n "${capture_line}" ]] || return 0
  CAPTURING_JOBS=$((CAPTURING_JOBS + 1))

  local first_scan=""
  first_scan="$(printf '%s\n%s' "${wrapper_lines}" "$(cut -f1 <<<"${gated_runner_lines}")" | grep -E '^[0-9]+$' | sort -n | awk 'NR == 1' || true)"

  # --- (a) wired ---------------------------------------------------------------
  if [[ -z "${first_scan}" ]]; then
    violation "${where}: this job captures a log (first capture at line ${capture_line}) but never invokes tooling/e2e/ci/scan-logs.sh at a command position and never invokes a runner from RUNNER_PINS$( [[ -z "${runner_lines}" ]] || printf ' (it runs %s, which does not source logscan-gate.sh)' "$(cut -f2 <<<"${runner_lines}" | sort -u | tr '\n' ' ' | sed 's/ $//')"). Every captured log goes through the wrapper — the key-material floor AND the identifier scanner — before it is echoed or uploaded; the bare floor is not a substitute."
  fi

  # --- (b) uploaded ⇒ scanned ----------------------------------------------------
  local sinks runner_paths="" gl gr
  sinks="$(sink_paths "${lines}")"
  while IFS=$'\t' read -r gl gr; do
    [[ -n "${gr}" ]] || continue
    runner_paths+="$(runner_gate_paths "${harness}/${gr}" | sed "s/^/${gl}\t/")"$'\n'
  done <<<"${gated_runner_lines}"
  local uline upath
  while IFS=$'\t' read -r step uline upath; do
    [[ -n "${upath}" ]] || continue
    [[ "${upath}" == *.log ]] || continue
    [[ "${upath}" == *'*'* ]] && continue
    if [[ -n "${UPLOAD_ALLOWLIST[${upath}]+x}" ]]; then continue; fi
    if awk -F'\t' -v p="${upath}" -v l="${uline}" '$2 == p && $1 + 0 < l + 0 { f = 1 } END { exit !f }' <<<"${sinks}"; then continue; fi
    if awk -F'\t' -v p="${upath}" -v l="${uline}" '$2 == p && $1 + 0 < l + 0 { f = 1 } END { exit !f }' <<<"${runner_paths}"; then continue; fi
    violation "${where}: the upload-artifact step at line ${uline} names ${upath}, which no --sink of scan-logs.sh earlier in this job lists and no gated runner this job ran hands to the gate. A file the wrapper never read is uploaded unscanned; name it in the scan step's sinks (typed by class) or, if its producer scans it, add it to UPLOAD_ALLOWLIST with that reason."
  done <<<"${uploads}"

  # --- (c) scan before echo --------------------------------------------------------
  if [[ -n "${first_scan}" ]]; then
    while IFS=$'\t' read -r step line cmd; do
      [[ -n "${cmd}" ]] || continue
      (( line < first_scan )) || continue
      [[ "${cmd}" =~ ${READ_CMD_RE} ]] || continue
      local args
      args="$(strip_redirects "${cmd}")"
      if grep -qE -- "${LOG_TOKEN_RE}" <<<"${args}"; then
        violation "${where}: line ${line} reads a captured log into the job log (\`${cmd}\`) before the first log-privacy scan of this job (line ${first_scan}). The job log is public and cannot be retracted; the gate runs first, and only then is a log echoed."
      fi
    done <<<"${cmds}"
  fi

  # --- (e) no unscannable upload --------------------------------------------------
  while IFS=$'\t' read -r step uline upath; do
    [[ -n "${upath}" ]] || continue
    case "${upath}" in
      *.logarchive|*.logarchive/)
        violation "${where}: the upload-artifact step at line ${uline} names ${upath}, a binary full-device capture no scanner here can read. Export what is needed with \`log show\` into a .log the scan step names, and delete the archive." ;;
      *.txt)
        if [[ -z "${UPLOAD_ALLOWLIST[${upath}]+x}" ]]; then
          violation "${where}: the upload-artifact step at line ${uline} names ${upath}. The wrapper's directory walk and every scan step type \`.log\` files; a \`.txt\` diagnostic leaves the runner unscanned. Write it as a .log the scan step names, or add it to UPLOAD_ALLOWLIST with where it is scanned."
        fi ;;
    esac
  done <<<"${uploads}"

  # --- (f) tee'd ⇒ scanned -----------------------------------------------------------
  local tline ttarget
  while IFS=$'\t' read -r tline ttarget; do
    [[ -n "${ttarget}" ]] || continue
    TEE_CAPTURES=$((TEE_CAPTURES + 1))
    if ! awk -F'\t' -v p="${ttarget}" -v l="${tline}" '$2 == p && $1 + 0 > l + 0 { f = 1 } END { exit !f }' <<<"${sinks}"; then
      violation "${where}: the test transcript tee'd to ${ttarget} at line ${tline} is never named by a --sink of scan-logs.sh later in this job. A transcript on disk that nothing scans is exactly where a stray println! of an identifier goes unread; scan it (\`--rules-only --sink rust-test=…\` or \`drive=…\`)."
    fi
  done <<<"${tee_targets}"

  # --- (g) rules-only is for transcripts ------------------------------------------------
  local rules_ok=0 w
  for w in "${RULES_ONLY_WORKFLOWS[@]}"; do [[ "${file}" == "${w}" ]] && rules_ok=1; done
  if (( ! rules_ok )) && [[ "${cmds}" == *'--rules-only'* ]]; then
    violation "${where}: --rules-only appears in a lane. A rules-only scan has no manifest: it certifies that the structural rules ran, NOT that any value the run minted is absent from the capture. A device, simulator or drive log comes from a run whose identifiers are declarable, so it is scanned against the sealed manifest; --rules-only is for the unit-test transcripts in ${RULES_ONLY_WORKFLOWS[*]} only."
  fi

}

# ---------------------------------------------------------------------------
# Harness-wide rules: (d), and the raw cross-check for the extractor.
# ---------------------------------------------------------------------------
check_harness() { # check_harness <harness-dir>
  local f hit
  for f in "$1"/*.sh; do
    [[ -f "${f}" ]] || continue
    hit="$(grep -nE -- "${XTRACE_RE}" "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' | awk 'NR == 1' || true)"
    [[ -z "${hit}" ]] || violation "tooling/e2e/ci/${f##*/}: shell tracing is enabled (\`${hit#*:}\`). A traced runner prints every expanded argument — the host declarations, the manifest path, the seal argv — into the public job log."
  done
}

check_extractor_sees_the_tree() { # <records> <workflow-dir>
  local records="$1" wf="$2" f base raw att
  for f in "${wf}"/*.yml "${wf}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    base="${f##*/}"
    raw="$(grep -E -- "${WRAPPER_RE}" "${f}" | grep -vcE '^[[:space:]]*#' || true)"
    att="$(awk -F'\t' -v b="${base}" -v re="${WRAPPER_RE}" '$1 == b && $5 == "cmd" && $6 ~ re' <<<"${records}" | wc -l)"
    raw="${raw//[[:space:]]/}"; att="${att//[[:space:]]/}"
    if (( raw != att )); then
      broken "${base}: the raw file names scan-logs.sh on ${raw} uncommented line(s) but the extractor attributed ${att} to a job's command text. It has stopped parsing this workflow, so every rule above is silently skipped for it."
    fi
  done
}

check_tree() { # check_tree <workflow-dir> <harness-dir> <min-jobs> <min-tees>
  local wf="$1" harness="$2" min_jobs="$3" min_tees="$4"
  local records="" f base jobs job
  CAPTURING_JOBS=0; TEE_CAPTURES=0
  [[ -d "${wf}" ]] || { broken "${wf} not found"; return; }
  [[ -d "${harness}" ]] || { broken "${harness} not found"; return; }

  reconcile_gated_runners "${harness}"
  check_harness "${harness}"

  for f in "${wf}"/*.yml "${wf}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    records+="$(emit_records "${f}")"$'\n'
  done
  records="$(grep -v '^$' <<<"${records}" || true)"
  if [[ -z "${records}" ]]; then
    broken "${wf}: the extractor produced no records at all."
    return
  fi
  check_extractor_sees_the_tree "${records}" "${wf}"

  # (g) over every workflow, including ones with no capturing job.
  local ok w hits
  for f in "${wf}"/*.yml "${wf}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    base="${f##*/}"
    ok=0
    for w in "${RULES_ONLY_WORKFLOWS[@]}"; do [[ "${base}" == "${w}" ]] && ok=1; done
    (( ok )) && continue
    hits="$(grep -F -- '--rules-only' "${f}" | grep -vcE '^[[:space:]]*#' || true)"
    if (( hits > 0 )); then
      violation "${base}: --rules-only appears outside ${RULES_ONLY_WORKFLOWS[*]}. It certifies that the rules ran and nothing more; every lane scans against a sealed manifest."
    fi
  done

  # (g) the `rust-test` SINK CLASS, confined the same way and for a sharper
  # reason: it is the class that skips S2 and S6 on cargo's crate-build line.
  for f in "${wf}"/*.yml "${wf}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    base="${f##*/}"
    ok=0
    for w in "${RUST_TEST_SINK_WORKFLOWS[@]}"; do [[ "${base}" == "${w}" ]] && ok=1; done
    (( ok )) && continue
    hits="$(grep -E -- "${RUST_TEST_SINK_RE}" "${f}" | grep -vcE '^[[:space:]]*#' || true)"
    if (( hits > 0 )); then
      violation "${base}: a --sink rust-test= appears outside ${RUST_TEST_SINK_WORKFLOWS[*]}. That class exempts cargo's crate-build line from S2 and S6 (tooling/logscan/policy.toml), which is only true of a capture cargo wrote; type a test transcript that is not cargo's as \`drive\`."
    fi
  done
  for f in "${harness}"/*.sh; do
    [[ -f "${f}" ]] || continue
    base="${f##*/}"
    [[ "${base}" == 'scan-logs.sh' ]] && continue
    hits="$(grep -E -- "${RUST_TEST_SINK_RE}" "${f}" | grep -vcE '^[[:space:]]*#' || true)"
    if (( hits > 0 )); then
      violation "tooling/e2e/ci/${base}: a --sink rust-test= appears in a lane runner. A lane captures device and drive logs, never a cargo transcript, and that class carries the cargo-status exemption."
    fi
  done

  local before
  jobs="$(awk -F'\t' '{ print $1 "\t" $2 }' <<<"${records}" | awk '!seen[$0]++')"
  while IFS=$'\t' read -r base job; do
    [[ -n "${job}" ]] || continue
    before="${CAPTURING_JOBS}"
    check_job "${records}" "${base}" "${job}" "${harness}"
    if [[ -n "${NO_CAPTURE_WORKFLOWS[${base}]+x}" ]] && (( CAPTURING_JOBS > before )); then
      violation "${base}:${job}: NO_CAPTURE_WORKFLOWS records this workflow as capturing nothing (${NO_CAPTURE_WORKFLOWS[${base}]}), but this job captures a log now. Re-decide the record: wire the scan and delete the entry."
    fi
  done <<<"${jobs}"

  for base in "${!NO_CAPTURE_WORKFLOWS[@]}"; do
    [[ -f "${wf}/${base}" ]] || violation "NO_CAPTURE_WORKFLOWS names ${base}, which does not exist under ${wf#"${REPO_ROOT}"/}. A record of a workflow that is gone is a record nobody can re-derive; delete the entry."
  done

  if (( CAPTURING_JOBS < min_jobs )); then
    broken "only ${CAPTURING_JOBS} capturing job(s) found, expected at least ${min_jobs}. Either lanes were removed (re-pin MIN_CAPTURING_JOBS in the same change) or the capture detector stopped matching, in which case every verdict above is vacuous."
  fi
  if (( TEE_CAPTURES < min_tees )); then
    broken "only ${TEE_CAPTURES} tee'd test transcript(s) found, expected ${min_tees} (rust-check.yml's four cargo jobs and coverage.yml's two flutter runs). A tee that stopped is a scan that stopped; re-pin MIN_TEE_CAPTURES with the job that stopped capturing."
  fi

  if (( VIOLATIONS == 0 && BROKEN == 0 )); then
    log "${CAPTURING_JOBS} capturing job(s), ${TEE_CAPTURES} tee'd transcript(s), $(grep -c . <<<"${GATED_RUNNERS}") gated runner(s) — every capture reaches scan-logs.sh before it is echoed or uploaded"
  fi
}

# ---------------------------------------------------------------------------
# Self-test. A synthetic tree: workflows + a harness with fake runners. Every
# rule has a fixture in both directions, and the count is pinned by equality.
# ---------------------------------------------------------------------------
readonly FAKE_PIN='SELF-TEST FAIL (1): the drive log is echoed only after the log-privacy gate'

write_runner() { # write_runner <harness-dir> <name> [pinned|unpinned|unsourced|uncalled|traced|rules]
  local dir="$1" name="$2" shape="${3:-pinned}"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    [[ "${shape}" == traced ]] && echo 'set -x'
    [[ "${shape}" == unsourced ]] || echo 'source "$(dirname "${BASH_SOURCE[0]}")/logscan-gate.sh"'
    echo 'adb logcat -v threadtime > /tmp/adb-logcat.log &'
    echo 'flutter drive > /tmp/flutter-drive.log 2>&1 || true'
    if [[ "${shape}" == rules ]]; then
      echo 'logscan_gate rules /tmp/haven-soak/needles -- --sink drive=/tmp/flutter-drive.log'
    elif [[ "${shape}" != uncalled ]]; then
      echo 'if ! logscan_gate host /tmp/haven-soak/needles -- --sink logcat=/tmp/adb-logcat.log \'
      echo '  --sink drive=/tmp/flutter-drive.log --report /tmp/x-logscan/r.ndjson; then exit 1; fi'
    fi
    echo 'cat /tmp/flutter-drive.log'
    echo 'if [[ "${1:-}" == "--self-test" ]]; then'
    [[ "${shape}" == unpinned ]] || echo "  echo \"${FAKE_PIN}\" >&2"
    echo '  exit 0'
    echo 'fi'
  } > "${dir}/${name}"
}

write_lane() { # write_lane <wf-dir> <name> <job> — a complete Android-shaped lane
  cat > "$1/$2" <<YAML
name: $2
on:
  workflow_call:
jobs:
  $3:
    runs-on: ubuntu-latest
    env:
      HAVEN_LOGSCAN: "true"
      HAVEN_LOGSCAN_PROFILE: proxy
    steps:
      - name: Checkout
        id: checkout
        uses: actions/checkout@v6
      - name: Build the runtime log scanner
        run: cargo build --release --manifest-path tooling/logscan/Cargo.toml
      - name: Start recording wire proxy
        run: |
          mkdir -m 0700 -p /tmp/haven-soak/needles
          rm -f /tmp/haven-soak/needles/*.needles.decl /tmp/haven-soak/needles/*.needles.json /tmp/haven-soak/needles/*.canaries.json
          bash tooling/e2e/ci/start-wire-proxy.sh 7788 ws://127.0.0.1:7777
      - name: Drive
        uses: reactivecircus/android-emulator-runner@v2
        with:
          script: bash tooling/e2e/ci/run-with-deadline.sh 20m "drive" -- bash -c 'bash tooling/e2e/ci/setup-network-guard.sh install && HAVEN_X=\${{ env.X }} bash tooling/e2e/ci/run-good.sh x.dart'
      - name: Stop recording wire proxy
        if: always()
        run: bash tooling/e2e/ci/stop-wire-proxy.sh
      - name: Proxy declaration channel stayed healthy
        run: bash tooling/e2e/ci/check-proxy-sidecar-summary.sh /tmp/haven-wire-proxy.log
      - name: Evidence
        run: |
          conn="\$(grep -aoE 'acked conn=[a-z]+' /tmp/flutter-drive.log | tail -n 1 || true)"
          docker logs strfry > /tmp/strfry.log 2>&1 || true
          { echo diag; } > /tmp/diag.log 2>&1
      - name: Scan captured logs for secrets before upload
        if: \${{ !cancelled() && steps.checkout.outcome == 'success' }}
        run: |
          summary=()
          if [[ -f /tmp/wire-summary.log ]]; then summary=(--sink diag=/tmp/wire-summary.log); fi
          relays=(/tmp/strfry.log /tmp/strfry-profile-*.log)
          rc=0
          bash tooling/e2e/ci/scan-logs.sh \\
            --manifest /tmp/haven-soak/needles/*.needles.json \\
            --sink "relay=\$(IFS=,; echo "\${relays[*]}")" \\
            --sink diag=/tmp/diag.log \\
            \${summary[@]+"\${summary[@]}"} \\
            --report /tmp/logscan-report-upload.ndjson || rc=\$?
          exit "\${rc}"
      - name: Upload failure artifacts
        if: failure()
        uses: actions/upload-artifact@v6
        with:
          name: x
          path: |
            /tmp/adb-logcat.log
            /tmp/flutter-drive.log
            /tmp/strfry.log
            /tmp/strfry-profile-*.log
            /tmp/diag.log
            /tmp/wire-summary.log
            /tmp/haven-egress/egress-raw.log
          retention-days: 14
      - name: Discard needle manifests
        if: always()
        run: rm -f /tmp/haven-soak/needles/*.needles.decl /tmp/haven-soak/needles/*.needles.json /tmp/haven-soak/needles/*.canaries.json
YAML
}

write_transcript_lane() { # write_transcript_lane <wf-dir> <name> — rust-check-shaped
  cat > "$1/$2" <<'YAML'
name: rust
on:
  push:
jobs:
  core:
    runs-on: ubuntu-latest
    steps:
      - name: Build the runtime log scanner
        id: build-scanner
        run: cargo build --release --manifest-path tooling/logscan/Cargo.toml
      - name: Run tests
        run: |
          set -o pipefail
          cargo test 2>&1 | tee "${RUNNER_TEMP}/core-cargo-test.log"
      - name: Scan the test transcript for identifiers
        if: ${{ !cancelled() && steps.build-scanner.outcome == 'success' }}
        run: bash tooling/e2e/ci/scan-logs.sh --rules-only --exempt-endpoint 127.0.0.1 --sink rust-test="${RUNNER_TEMP}/core-cargo-test.log"
YAML
}

write_ios_lane() { # write_ios_lane <wf-dir> — a retry-command lane rotating through the script, joining a scalar sink
  cat > "$1/e2e-ios.yml" <<'YAML'
name: ios
on:
  workflow_call:
jobs:
  e2e_ios:
    runs-on: macos-latest
    env:
      HAVEN_LOGSCAN: "true"
      HAVEN_LOGSCAN_PROFILE: proxy
    steps:
      - name: Checkout
        id: checkout
        uses: actions/checkout@v6
      - name: Build the runtime log scanner
        run: cargo build --release --manifest-path tooling/logscan/Cargo.toml
      - name: Run e2e_combined on the simulator
        uses: nick-fields/retry@v3
        with:
          timeout_minutes: 30
          max_attempts: 2
          command: >-
            bash tooling/e2e/ci/rotate-needle-dir.sh &&
            bash tooling/e2e/ci/start-wire-proxy.sh 7788 ws://127.0.0.1:7777 &&
            test -f tooling/e2e/ci/run-other.sh &&
            bash tooling/e2e/ci/run-good.sh
            integration_test/e2e/e2e_combined.dart
      - name: Stop recording wire proxy
        if: always()
        run: bash tooling/e2e/ci/stop-wire-proxy.sh
      - name: Proxy declaration channel stayed healthy
        run: bash tooling/e2e/ci/check-proxy-sidecar-summary.sh /tmp/haven-wire-proxy.log
      - name: Collect simulator diagnostics
        if: always()
        run: |
          log show --archive /tmp/sim.logarchive --style syslog 2>/dev/null \
            | head -c "${CAP}" > /tmp/sim-unified-full.log || true
          rm -rf /tmp/sim.logarchive
          cp /tmp/haven-local-relay.log /tmp/relay.log
      - name: Scan captured logs for secrets before upload
        if: ${{ !cancelled() && steps.checkout.outcome == 'success' }}
        run: |
          relays=/tmp/relay.log
          for f in /tmp/relay-profile-*.log /tmp/blossom.log; do relays="${relays},${f}"; done
          rc=0
          bash tooling/e2e/ci/scan-logs.sh \
            --manifest /tmp/haven-soak/needles/*.needles.json \
            --sink ios=/tmp/sim-unified-full.log \
            --sink drive=/tmp/flutter-ios-test.log \
            --sink "relay=${relays}" \
            --report /tmp/logscan-report-upload.ndjson || rc=$?
          exit "${rc}"
      - name: Upload failure artifacts
        if: failure()
        uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/flutter-ios-test.log
            /tmp/sim-unified-full.log
            /tmp/relay.log
            /tmp/blossom.log
      - name: Discard needle manifests
        if: always()
        run: rm -f /tmp/haven-soak/needles/*.needles.decl /tmp/haven-soak/needles/*.needles.json /tmp/haven-soak/needles/*.canaries.json
YAML
}

write_proxy_only_lane() { # write_proxy_only_lane <wf-dir> — starts the proxy, captures nothing this guard recognises, never discards
  cat > "$1/e2e-proxy-only.yml" <<'YAML'
name: proxy-only
on:
  workflow_call:
jobs:
  proxy_only:
    runs-on: ubuntu-latest
    env:
      HAVEN_LOGSCAN_PROFILE: proxy
    steps:
      - name: Start recording wire proxy
        run: bash tooling/e2e/ci/start-wire-proxy.sh 7788 ws://127.0.0.1:7777
      - name: Exercise the channel
        run: bash tooling/e2e/ci/some-probe.sh
      - name: Proxy declaration channel stayed healthy
        run: bash tooling/e2e/ci/check-proxy-sidecar-summary.sh /tmp/haven-wire-proxy.log
YAML
}

write_plain_workflow() { # write_plain_workflow <wf-dir> <name> — captures nothing
  cat > "$1/$2" <<'YAML'
name: analyze
on:
  workflow_call:
jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - name: Analyze
        run: flutter analyze --no-fatal-infos
YAML
}

write_guards_workflow() { # write_guards_workflow <wf-dir> — runs a runner's --self-test and the wrapper's, captures nothing
  cat > "$1/repo-guards.yml" <<'YAML'
name: guards
on:
  push:
jobs:
  guards:
    runs-on: ubuntu-latest
    steps:
      - name: Runner self-test
        run: bash tooling/e2e/ci/run-good.sh --self-test
      - name: Wrapper self-test
        run: bash tooling/e2e/ci/scan-logs.sh --self-test
YAML
}

self_test() {
  local -r SELF_TEST_CASES=57
  local tmp cases=0 failures=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  RUNNER_PINS=( ['run-good.sh']="${FAKE_PIN}" )

  # A base tree that must pass: one proxy lane (emulator `script:`), one iOS
  # retry lane (`command:`, scalar sink join), one transcript workflow
  # (`${RUNNER_TEMP}` tee), one no-capture workflow, one guards workflow that
  # runs self-tests only, one gated runner.
  base_tree() { # base_tree <dir>
    mkdir -p "$1/wf" "$1/harness"
    write_lane "$1/wf" 'e2e-android.yml' 'e2e_android'
    write_ios_lane "$1/wf"
    write_transcript_lane "$1/wf" 'rust-check.yml'
    write_plain_workflow "$1/wf" 'flutter-check.yml'
    write_guards_workflow "$1/wf"
    write_runner "$1/harness" 'run-good.sh'
    printf '#!/usr/bin/env bash\nset -euo pipefail\nexec "$@"\n' > "$1/harness/run-with-deadline.sh"
  }

  _expect() { # _expect <desc> <dir> <want-rc> [want-substring] [min-jobs] [min-tees]
    local desc="$1" dir="$2" want="$3" want_grep="${4:-}" mj="${5:-1}" mt="${6:-1}"
    local out rc=0
    cases=$(( cases + 1 ))
    VIOLATIONS=0; BROKEN=0
    check_tree "${dir}/wf" "${dir}/harness" "${mj}" "${mt}" >"${tmp}/out.txt" 2>"${tmp}/err.txt"
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
  mut() { # mut <src-dir> <dst-dir> <file> <sed-expr>...
    local src="$1" dst="$2" file="$3"; shift 3
    rm -rf "${dst}"; cp -r "${src}" "${dst}"
    local e; for e in "$@"; do sed -i -E "${e}" "${dst}/${file}"; done
  }

  local b="${tmp}/base"; base_tree "${b}"
  _expect "the base tree passes" "${b}" 0 "3 capturing job(s)"
  _expect "the base tree is silent about no-capture flutter-check.yml and the self-test-only guards workflow" "${b}" 0 "1 gated runner(s)"

  # (a)
  local d="${tmp}/a1"; mut "${b}" "${d}" 'wf/e2e-android.yml' \
    's|run-good.sh|run-other.sh|; /scan-logs.sh/d; /--manifest/d; /--sink/d; /--report/d; /summary=/d; /relays=/d; /rc=0/d; /exit "\$\{rc\}"/d; /if \[\[ -f/d'
  _expect "(a) a capturing job with neither the wrapper nor a gated runner fails" "${d}" 1 "never invokes tooling/e2e/ci/scan-logs.sh"
  d="${tmp}/a2"; mut "${b}" "${d}" 'wf/e2e-android.yml' \
    's|run-good.sh|run-plain.sh|; /scan-logs.sh/d; /--manifest/d; /--sink/d; /--report/d; /summary=/d; /relays=/d; /rc=0/d; /exit "\$\{rc\}"/d; /if \[\[ -f/d'
  write_runner "${d}/harness" 'run-plain.sh' unsourced
  _expect "(a) an ungated runner does not count as the wrapper" "${d}" 1 "does not source logscan-gate.sh"
  d="${tmp}/a3"; rm -rf "${d}"; cp -r "${b}" "${d}"; write_runner "${d}/harness" 'run-good.sh' unpinned
  _expect "(a) a listed runner without its wiring-pin fixture fails" "${d}" 1 "no longer carries its wiring-pin fixture"
  d="${tmp}/a4"; rm -rf "${d}"; cp -r "${b}" "${d}"; write_runner "${d}/harness" 'run-good.sh' uncalled
  _expect "(a) a runner that sources the gate but never calls it fails" "${d}" 1 "never calls logscan_gate"
  d="${tmp}/a5"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)bash tooling/e2e/ci/scan-logs.sh|\1# bash tooling/e2e/ci/scan-logs.sh|; s|run-good.sh|run-other.sh|'
  _expect "(a) a commented-out wrapper call is not a wrapper call" "${d}" 1 "never invokes tooling/e2e/ci/scan-logs.sh"
  d="${tmp}/a6"; rm -rf "${d}"; cp -r "${b}" "${d}"; write_runner "${d}/harness" 'run-good.sh' unsourced
  _expect "(a) a listed runner that no longer sources the gate is a stale entry" "${d}" 1 "no longer sources logscan-gate.sh"
  d="${tmp}/a7"; rm -rf "${d}"; cp -r "${b}" "${d}"; write_runner "${d}/harness" 'run-extra.sh'
  _expect "(a) a runner that sources the gate but is not listed fails" "${d}" 1 "is not in RUNNER_PINS"
  d="${tmp}/a8"; rm -rf "${d}"; cp -r "${b}" "${d}"; rm "${d}/harness/run-good.sh"
  sed -i 's|run-good.sh|run-other.sh|' "${d}/wf/e2e-android.yml" "${d}/wf/e2e-ios.yml" "${d}/wf/repo-guards.yml"
  _expect "(a) a pin for a runner that is gone is stale" "${d}" 1 "which does not exist"
  d="${tmp}/a9"; mut "${b}" "${d}" 'wf/repo-guards.yml' 's|run-good.sh --self-test|run-good.sh x.dart|'
  _expect "(a) a runner invocation that is not a --self-test IS a capture (a fourth capturing job appears, wired by its gated runner)" "${d}" 0 "4 capturing job(s)"
  d="${tmp}/a10"; mut "${b}" "${d}" 'wf/e2e-ios.yml' 's|bash tooling/e2e/ci/run-good.sh|bash tooling/e2e/ci/run-other.sh|'
  _expect "(a) \`test -f …/run-x.sh\` is not an invocation (the iOS lane still has its wrapper step, so it passes)" "${d}" 0

  # (b)
  d="${tmp}/b1"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|--sink diag=/tmp/diag.log|--sink diag=/tmp/other.log|'
  _expect "(b) an uploaded .log no --sink names fails" "${d}" 1 "names /tmp/diag.log, which no --sink"
  d="${tmp}/b2"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|/tmp/adb-logcat.log|/tmp/logcat-other.log|'
  _expect "(b) an uploaded .log the gated runner does not hand to the gate fails" "${d}" 1 "names /tmp/logcat-other.log"
  _expect "(b) an array-expanded --sink credits its members, a wildcard upload is skipped, an allowlisted egress log passes (base)" "${b}" 0
  d="${tmp}/b3"; mut "${b}" "${d}" 'wf/e2e-android.yml' \
    's|^(\s+)- name: Scan captured logs for secrets before upload|\1- name: Scan captured logs for secrets AFTER upload|'
  swap_scan_below_upload() { # swap the scan and upload blocks' order
    local f="$1"
    awk '
      /- name: Scan captured logs/ { inscan = 1 }
      /- name: Upload failure artifacts/ { inscan = 0; inup = 1 }
      /- name: Discard needle manifests/ { inup = 0 }
      inscan { scan = scan $0 "\n"; next }
      inup { up = up $0 "\n"; next }
      /- name: Discard needle manifests/ { printf "%s%s", up, scan }
      { print }
    ' "${f}" > "${f}.new" && mv "${f}.new" "${f}"
  }
  swap_scan_below_upload "${d}/wf/e2e-android.yml"
  _expect "(b) a --sink that comes AFTER the upload does not count" "${d}" 1 "which no --sink of scan-logs.sh earlier"
  _expect "(b) a scalar-joined --sink credits the assigning lines (iOS lane, base)" "${b}" 0
  d="${tmp}/b4"; mut "${b}" "${d}" 'wf/e2e-ios.yml' '/^\s+relays=\/tmp\/relay.log$/d; s|relays="\$\{relays\},\$\{f\}"|relays="${relays:-}${relays:+,}${f}"|'
  _expect "(b) a scalar-joined --sink does not credit a path no assigning line names" "${d}" 1 "names /tmp/relay.log"
  d="${tmp}/b5"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|summary=\(--sink diag=/tmp/wire-summary.log\)|summary=(--sink diag=/tmp/wire-digest.log)|'
  _expect "(b) an optional-sink array names the wrong file: the uploaded one is unscanned" "${d}" 1 "names /tmp/wire-summary.log"

  # (c)
  d="${tmp}/c1"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)docker logs strfry > /tmp/strfry.log.*|\1cat /tmp/strfry.log\n&|'
  _expect "(c) a read after the first gate (the runner) passes" "${d}" 0
  d="${tmp}/c2"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)- name: Drive|\1- name: Peek\n\1  run: tail -n 20 /tmp/adb-logcat.log \|\| true\n\1- name: Drive|'
  _expect "(c) a tail of a captured log before the first gate fails" "${d}" 1 "reads a captured log into the job log"
  d="${tmp}/c3"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)- name: Drive|\1- name: Peek\n\1  run: grep -c ready /tmp/adb-logcat.log \| tail -n 1 \|\| true\n\1- name: Drive|'
  _expect "(c) a tail reading a pipe, not a file, passes" "${d}" 0
  _expect "(c) head -c redirected INTO a .log passes (iOS export, base)" "${b}" 0
  d="${tmp}/c4"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)- name: Drive|\1- name: Peek\n\1  run: head -n 5 /tmp/adb-logcat.log > /tmp/peek.txt\n\1- name: Drive|'
  _expect "(c) a head of a captured log before the gate fails even when redirected" "${d}" 1 "reads a captured log"
  d="${tmp}/c5"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)- name: Drive|\1- name: Peek\n\1  run: if cat /tmp/adb-logcat.log; then echo ok; fi\n\1- name: Drive|'
  _expect "(c) a cat behind an \`if\` is still a read" "${d}" 1 "reads a captured log"

  # (d)
  d="${tmp}/d1"; rm -rf "${d}"; cp -r "${b}" "${d}"; write_runner "${d}/harness" 'run-good.sh' traced
  _expect "(d) set -x in a harness script fails" "${d}" 1 "shell tracing is enabled"
  d="${tmp}/d2"; rm -rf "${d}"; cp -r "${b}" "${d}"; sed -i 's|^set -euo pipefail|set -euo pipefail\n# set -x is documented here only|' "${d}/harness/run-good.sh"
  _expect "(d) set -x in a comment passes" "${d}" 0

  # (e)
  d="${tmp}/e1"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)/tmp/diag.log$|\1/tmp/diag.log\n\1/tmp/sim.logarchive|'
  _expect "(e) a .logarchive upload fails" "${d}" 1 ".logarchive"
  d="${tmp}/e2"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)/tmp/diag.log$|\1/tmp/diag.log\n\1/tmp/DIAG.txt|'
  _expect "(e) a .txt upload fails" "${d}" 1 "leaves the runner unscanned"
  d="${tmp}/e3"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^(\s+)/tmp/diag.log$|\1/tmp/diag.log\n\1/tmp/haven-egress/egress-summary.txt|'
  _expect "(e) the allowlisted egress summary passes" "${d}" 0

  # (f)
  d="${tmp}/f1"; mut "${b}" "${d}" 'wf/rust-check.yml' 's|--sink rust-test="\$\{RUNNER_TEMP\}/core-cargo-test.log"|--sink rust-test="${RUNNER_TEMP}/other.log"|'
  _expect "(f) a tee'd transcript no later --sink names fails" "${d}" 1 "is never named by a --sink"
  d="${tmp}/f2"; mut "${b}" "${d}" 'wf/rust-check.yml' 's/^(\s+)cargo test 2>&1 \| tee .*/\1cargo test/; /scan-logs.sh/d'
  _expect "(f) a test run that is not tee'd captures nothing (no floor breach at 0 tees)" "${d}" 0 "" 1 0
  _expect "(f) a \${RUNNER_TEMP} tee target survives the fragment split (base names 1 tee'd transcript)" "${b}" 0 "1 tee'd transcript(s)"
  _expect "floor: fewer tee'd transcripts than pinned is BROKEN" "${b}" 2 "tee'd test transcript(s) found" 1 2
  _expect "floor: fewer capturing jobs than pinned is BROKEN" "${b}" 2 "capturing job(s) found" 4 1

  # (g)
  d="${tmp}/g1"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|--manifest /tmp/haven-soak/needles/\*.needles.json|--rules-only|'
  _expect "(g) --rules-only in a lane fails" "${d}" 1 "--rules-only appears"
  _expect "(g) --rules-only in rust-check.yml passes (base)" "${b}" 0
  d="${tmp}/g2"; rm -rf "${d}"; cp -r "${b}" "${d}"; write_runner "${d}/harness" 'run-good.sh' rules
  _expect "(g) the rules profile in a lane runner fails" "${d}" 1 "uses --rules-only (or the rules profile)"
  # The `rust-test` sink class carries the cargo exemption, so it is confined to
  # the workflow that scans cargo transcripts. The base names it in
  # rust-check.yml, which is the passing half of this pair.
  d="${tmp}/g3"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|--sink diag=/tmp/diag.log|--sink rust-test=/tmp/diag.log|'
  _expect "(g) a rust-test sink in a lane fails" "${d}" 1 "outside rust-check.yml"
  d="${tmp}/g4"; rm -rf "${d}"; cp -r "${b}" "${d}"; sed -i 's|--sink drive=/tmp/flutter-drive.log|--sink rust-test=/tmp/flutter-drive.log|' "${d}/harness/run-good.sh"
  _expect "(g) a rust-test sink in a lane runner fails" "${d}" 1 "appears in a lane runner"

  # (h)
  d="${tmp}/h1"; mut "${b}" "${d}" 'wf/e2e-android.yml' '/check-proxy-sidecar-summary.sh/d; /Proxy declaration channel stayed healthy/d'
  _expect "(h) a proxy lane without the sidecar summary fails" "${d}" 1 "never runs tooling/e2e/ci/check-proxy-sidecar-summary.sh"
  d="${tmp}/h2"; mut "${b}" "${d}" 'wf/e2e-android.yml' '/Discard needle manifests/,$d'
  _expect "(h) a proxy lane without the discard step fails" "${d}" 1 "no final \`if: always()\` step"
  d="${tmp}/h3"; mut "${b}" "${d}" 'wf/e2e-android.yml' '/- name: Discard needle manifests/{n;s|if: always\(\)|if: success()|}'
  _expect "(h) a discard that is not always() fails" "${d}" 1 "no final \`if: always()\` step"
  d="${tmp}/h4"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|\*\.canaries\.json$||'
  _expect "(h) a discard missing one of the three shapes fails" "${d}" 1 "no final \`if: always()\` step"
  d="${tmp}/h5"; rm -rf "${d}"; cp -r "${b}" "${d}"
  awk '/- name: Discard needle manifests/ { d = 1 } d && n < 3 { disc = disc $0 "\n"; n++; next } /- name: Upload failure artifacts/ { printf "%s", disc } { print }' \
    "${b}/wf/e2e-android.yml" > "${d}/wf/e2e-android.yml"
  _expect "(h) a discard BEFORE the upload fails" "${d}" 1 "after every upload-artifact step"
  d="${tmp}/h6"; mut "${b}" "${d}" 'wf/e2e-android.yml' '/HAVEN_LOGSCAN_PROFILE: proxy/d'
  _expect "(h) a proxy lane without HAVEN_LOGSCAN_PROFILE at job level fails" "${d}" 1 "does not declare HAVEN_LOGSCAN_PROFILE: proxy"
  d="${tmp}/h7"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|HAVEN_LOGSCAN_PROFILE: proxy|HAVEN_LOGSCAN_PROFILE: host|'
  _expect "(h) a proxy lane declaring the host profile fails" "${d}" 1 "does not declare HAVEN_LOGSCAN_PROFILE: proxy at job level (it declares host)"
  d="${tmp}/h8"; rm -rf "${d}"; cp -r "${b}" "${d}"; write_proxy_only_lane "${d}/wf"
  _expect "(h) a proxy-starting job with no recognised capture still needs its discard" "${d}" 1 "e2e-proxy-only.yml:proxy_only: this job starts the recording proxy"

  # (i)
  d="${tmp}/i1"; mut "${b}" "${d}" 'wf/e2e-android.yml' '/Build the runtime log scanner/,+1d'
  _expect "(i) a HAVEN_LOGSCAN lane without the scanner build fails" "${d}" 1 "builds the scanner"
  d="${tmp}/i2"; mut "${b}" "${d}" 'wf/e2e-android.yml' '/mkdir -m 0700 -p \/tmp\/haven-soak\/needles/d'
  _expect "(i) a HAVEN_LOGSCAN lane without the mkdir half of the rotation fails" "${d}" 1 "needle directory is not rotated"
  d="${tmp}/i3"; mut "${b}" "${d}" 'wf/e2e-android.yml' '0,/rm -f \/tmp\/haven-soak\/needles/{s|/tmp/haven-soak/needles/\*.needles.json ||}'
  _expect "(i) a rotation missing one rm -f shape fails" "${d}" 1 "needle directory is not rotated"
  _expect "(i) rotate-needle-dir.sh inside a retry command counts (iOS lane, base)" "${b}" 0
  d="${tmp}/i4"; mut "${b}" "${d}" 'wf/e2e-ios.yml' '/rotate-needle-dir.sh/d'
  _expect "(i) the iOS lane without either rotation shape fails" "${d}" 1 "needle directory is not rotated"
  d="${tmp}/i5"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|HAVEN_LOGSCAN: "true"|HAVEN_LOGSCAN: "false"|; /Build the runtime log scanner/,+1d'
  _expect "(i) is asked only of a lane with the flag on (the proxy rules still hold)" "${d}" 0

  # no-capture record, extractor cross-check
  d="${tmp}/n1"; mut "${b}" "${d}" 'wf/flutter-check.yml' 's|^(\s+)run: flutter analyze.*|\1run: flutter test 2>\&1 \| tee "${RUNNER_TEMP}/t.log"|'
  _expect "a NO_CAPTURE workflow that starts capturing is a stale record" "${d}" 1 "records this workflow as capturing nothing"
  d="${tmp}/n2"; rm -rf "${d}"; cp -r "${b}" "${d}"; rm "${d}/wf/flutter-check.yml"
  _expect "a NO_CAPTURE entry for a workflow that is gone is stale" "${d}" 1 "which does not exist"
  d="${tmp}/x1"; mut "${b}" "${d}" 'wf/e2e-android.yml' 's|^jobs:|jobz:|'
  _expect "a workflow the extractor cannot attribute is BROKEN, never clean" "${d}" 2 "stopped parsing"

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
  local wf="${REPO_ROOT}/.github/workflows" harness="${REPO_ROOT}/tooling/e2e/ci"
  [[ -f "${harness}/scan-logs.sh" && -f "${harness}/logscan-gate.sh" ]] || {
    echo "ERROR: the wrapper or the gate library is missing under tooling/e2e/ci — the chain this guard checks does not exist" >&2
    exit 2
  }
  log "checking that every captured log reaches the log-privacy wrapper (${wf#"${REPO_ROOT}"/}, ${harness#"${REPO_ROOT}"/})"
  check_tree "${wf}" "${harness}" "${MIN_CAPTURING_JOBS}" "${MIN_TEE_CAPTURES}"
  if (( BROKEN > 0 )); then
    echo >&2
    echo "This guard could not see the repository the way it expects to. That is not" >&2
    echo "a clean bill of health: an extractor that stops matching reports every lane" >&2
    echo "as compliant. See the header of ${SELF_NAME}." >&2
    exit 2
  fi
  if (( VIOLATIONS > 0 )); then
    echo >&2
    echo "A captured log that the wrapper never read is a log that may carry an" >&2
    echo "identifier into a public artifact or job log. See CLAUDE.md (Log anonymity," >&2
    echo "Security Rule 15) and docs/E2E_TROUBLESHOOTING.md failure mode 13." >&2
    exit 1
  fi
  log "OK — every capturing lane is wired through scan-logs.sh."
}

main "$@"
