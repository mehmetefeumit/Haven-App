#!/usr/bin/env bash
#
# CI guard: the wire-privacy oracles must be REACHED BY A LANE.
#
# ## Why this exists
#
# `scripts/ci/check_wire_proxy_test_only.sh` is the NEGATIVE half of the wire
# instrument's boundary: it proves the recording proxy is unreachable from the
# shipped app. This is the POSITIVE half, and it answers a different question —
# is the instrument reached by anything at all?
#
# Three oracles read the journal the proxy writes
# (`tooling/e2e/ci/check-wire-journal.sh`, `check-wire-correlation.sh`,
# `check-wire-canaries.dart`). All three are green on every PR, and every one of
# those green results comes from a `--self-test` over hermetic fixtures. None of
# them has ever read a journal produced by a real run.
#
# That is the exact shape `docs/CI_HARDENING_BACKLOG.md` catalogues under
# "Cross-cutting note: the recurring failure mode" — code that is written,
# reviewed, passes its own self-test, and executes nowhere. Ten instances are
# recorded there; three were produced by the round that catalogued it, and the
# most recent (instance 10) was a coverage gate whose self-test ran only in the
# local pre-push hook. The wire oracles are instance 11 unless something fails
# when the chain is broken.
#
# ## The chain, and why all four links are load-bearing
#
# A lane instruments itself by starting the recording proxy in front of the
# hermetic relay. Four things have to be true, and a break in ANY of them leaves
# an oracle that runs, reports CLEAN, and has observed nothing:
#
#   1. RELAY URL POINTS AT THE PROXY. The proxy listens on 7788 and forwards to
#      the relay on 7777. If the lane's `ws://…` still names 7777, the app
#      talks straight to the relay, the recorder sees no traffic, and the
#      journal is empty-but-valid. This is the quietest break of the four:
#      starting the proxy is the visible edit, and re-pointing the URL is the
#      one-line change in a different part of the file that is easy to omit.
#
#   2. THE PROXY IS STOPPED, UNDER `if: always()`. The proxy is a background
#      process holding a claim on its journal path
#      (`start-wire-proxy.sh`'s per-instance `.journalpath` sidecar). A lane
#      that leaks it on the failure path leaves a live instance on a reused
#      runner, and the next start refuses — so the FIRST red run silently
#      disables recording for every run after it.
#
#   3. AT LEAST ONE ORACLE RUNS, AFTER THE PROXY STARTED AND AFTER A DRIVE.
#      Recording without asserting is a lane that pays the cost and buys
#      nothing. Both ordering halves matter because workflow steps run in file
#      order: above the proxy start, an oracle reads a journal from a previous
#      run or no journal at all; above every drive, it reads the empty file the
#      proxy just created. The second is the more insidious, because "a journal
#      with no client->relay traffic" is a state the oracles already have a
#      name for — META-FLOOR — so a step-ORDER bug surfaces in the log as a
#      scenario that published nothing.
#
#   4. ONE SENTINEL STRING, BOTH HALVES. Every oracle anchors its read at the
#      sentinel the drive emitted (`TestRelay.emitWireJournalSentinel()`), so a
#      background wake appending mid-read cannot race the snapshot. The lane
#      hands the token to the drive (`--dart-define=HAVEN_WIRE_SENTINEL=…`) and
#      to the oracle (`--sentinel …`). If the two halves name different values
#      the oracle finds no anchor and exits META-FLOOR — but a lane that mints
#      the token twice gets two DIFFERENT random strings and the failure looks
#      like a flake, not a wiring bug. See "How a lane wires this in" in
#      `tooling/e2e/ci/check-wire-journal.sh`.
#
#      Two things make this link the fiddliest of the four, and both are
#      failures that a naive string comparison PASSES:
#
#        * The define may be one call deeper. The Android and iOS lanes build
#          the app inside `run-single-avd-scenario.sh` / `run-ios-sim-
#          scenario.sh`, so the workflow sets an env and the harness turns it
#          into the define. Demanding the define in the workflow would red a
#          correct lane; accepting the env alone would pass a lane whose env
#          reaches no define at all. So the job's text and the text of every
#          `tooling/e2e/ci/*.sh` it invokes are searched as one chain.
#        * A variable both halves name and nobody sets is trivially "the same
#          string" — the empty one. `TestRelay`'s token is
#          `String.fromEnvironment(…, defaultValue: 'HAVEN_WIRE_SENTINEL:
#          default…')`, so a missing define never fails a build: the app emits
#          a constant, the oracle anchors on nothing, and the run reports
#          META-FLOOR as if the SCENARIO were at fault. Hence the binding
#          check — a bare identifier must be set somewhere in the job.
#
# ## Anti-vacuity: expectations are derived FROM the repo
#
# A guard over lanes that carries a hardcoded floor rots the way
# `check_e2e_step_timeout_ordering.sh`'s did: its floor of "at least 10 steps /
# 8 drives" was written for an 11-lane repo, and by the time the repo had 35
# steps the extractor could have lost two thirds of them and still passed. That
# guard was fixed on 2026-08-09 to derive its expectation from the repo by a
# mechanism INDEPENDENT of the thing it checks, and to NAME the file that went
# missing rather than report a shortfall. This guard follows it:
#
#   * The extractor parses workflow YAML into per-job / per-step records. The
#     cross-check greps the RAW files for the same markers. Two independent
#     readings of one source: if the record parser rots, the grep still sees the
#     lane, and the mismatch NAMES the file.
#   * The population of lanes that COULD wire the proxy is not a constant
#     either — it is every job that starts a hermetic relay
#     (`start-local-relay.sh` / `start-strfry.sh` / `start-profile-relays.sh`)
#     or the proxy itself. Add a lane and it joins the population automatically.
#   * If NO job wires the proxy, this guard FAILS. "Zero instrumented lanes"
#     is the state the whole workstream exists to end; it must never be the
#     state in which every check passes for want of anything to check.
#
# ## The known-unwired list is pinned by EQUALITY
#
# Not every lane needs the recorder. `e2e-integration` never talks to a relay
# as a user; the single-purpose B-lanes assert one runtime behaviour each and
# a wire transcript adds nothing they do not already have. So exemptions are
# allowed — declared in `KNOWN_UNWIRED_LANES` below, one line each with the
# reason.
#
# It is pinned by SET EQUALITY, not by `>=`, following
# `haven/test/lints/announcement_keys_reachable_test.dart`'s `_knownUnwired`
# (whose expected set is deliberately empty, and whose emptiness is the steady
# state). Equality buys both directions:
#
#   * ADDING a lane to the list is a visible, reviewable act in the diff. A
#     `>=` list would let a lane be quietly excused.
#   * A lane DROPPING OUT of the wired set reds, because it appears in the
#     computed unwired set and not in the declared one. That is the regression
#     this guard is really for: wiring that is removed, or that decays when a
#     lane is rewritten, with three green self-tests still claiming coverage.
#   * A STALE entry reds too — a lane that got wired but stayed on the list.
#
# Pure bash/grep/awk, no toolchain — belongs in repo-guards.yml.
#
# Usage:
#   bash scripts/ci/check_wire_oracle_lane_reachable.sh
#   bash scripts/ci/check_wire_oracle_lane_reachable.sh --self-test
#
# Exit codes:
#   0  at least one lane wires the chain end to end, and every wired lane is
#      complete; the unwired set equals the declared exemptions
#   1  a CONTRACT violation — a broken link, or an exemption-set mismatch
#   2  the guard cannot see the repo — a missing directory, or an extractor
#      that stopped attributing lanes the raw grep can still find

set -uo pipefail

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SELF_NAME
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

# The recorder's lifecycle scripts and the three oracles that read its journal.
# `[.]` rather than `\.`: these strings are handed to awk via -v, where a
# backslash escape is consumed by the string literal before the regex ever sees
# it (awk warns and treats `\.` as a bare `.`). A bracket expression means the
# same thing to awk and to `grep -E`, with no escaping layer in between.
readonly PROXY_START_RE='start-wire-proxy[.]sh'
readonly PROXY_STOP_RE='stop-wire-proxy[.]sh'
readonly ORACLE_RE='check-wire-journal[.]sh|check-wire-correlation[.]sh|check-wire-canaries[.]dart'

# Every way a lane brings up a hermetic relay. This is what defines the
# POPULATION of lanes that could put a recorder in front of one — derived from
# the repo, so a new lane joins it without editing this guard.
readonly RELAY_START_RE='start-local-relay[.]sh|start-strfry[.]sh|start-profile-relays[.]sh'

# Every way a lane DRIVES the app. Not a hand-kept list of harness names: the
# convention `tooling/e2e/ci/run-*.sh` is the same one
# check_e2e_step_timeout_ordering.sh derives its drive steps from, so a new
# harness joins it by being named like its siblings.
readonly DRIVE_RE='tooling/e2e/ci/run-[A-Za-z0-9._-]+[.]sh|flutter[[:space:]]+drive'

# Harness scripts a job may invoke. The Android and iOS lanes BUILD the app
# inside their harness, so the dart-defines that reach the app are one call
# deeper than the workflow — link 4 has to follow the chain there.
readonly HARNESS_REF_RE='tooling/e2e/ci/[A-Za-z0-9._-]+[.]sh'

# Root the harness scripts are resolved against. A parameter, not a constant,
# so the self-test stays hermetic: its fixtures ship their own harness dir.
HARNESS_ROOT="${REPO_ROOT}"

# start-wire-proxy.sh's default listen port when the lane passes no argv and no
# routing table (its header: "defaults: 7788 ws://127.0.0.1:7777").
readonly DEFAULT_LISTEN_PORT='7788'

# ---------------------------------------------------------------------------
# The known-unwired list. `<workflow-file>:<job-id>`, one per line, each with
# the reason it does not carry the recorder. Pinned by EQUALITY (see header):
# this set must be exactly the set of relay-starting jobs that do not start the
# proxy. Adding a line is a reviewable act; a lane losing its wiring reds here.
# ---------------------------------------------------------------------------
readonly KNOWN_UNWIRED_LANES=(
  # Component integration tests. They exercise the FFI and service layer
  # against a relay, not the product's own publish path, so a send-side wire
  # transcript would assert over traffic no user ever generates.
  'e2e-integration.yml:e2e_integration'

  # Single-purpose runtime lanes. Each proves ONE behaviour with its own
  # purpose-built oracle (a publish count, a permission read, a servo log, an
  # outage/recovery pair). None of them drives the full three-user flow, so
  # their journals would carry a fraction of the kind set the closed-world
  # oracle is built to close over — and a lane whose oracle certifies a sample
  # it never had is the failure mode Workstream C exists to prevent.
  'e2e-fgs-publish.yml:e2e_fgs_publish'
  'e2e-real-gps.yml:e2e_real_gps'
  'e2e-ios-real-gps.yml:e2e_ios_real_gps'
  'e2e-ios-auth-tier.yml:e2e_ios_auth_tier'
  'e2e-permission-revocation.yml:e2e_permission_revocation'
  'e2e-location-provider-toggle.yml:e2e_location_provider_toggle'
  'e2e-clock-skew.yml:e2e_clock_skew'
  'e2e-network-reconnect.yml:e2e_network_reconnect'
  'e2e-kp-rotation.yml:e2e_kp_rotation'
  'e2e-background-catchup.yml:e2e_background_catchup'
  'e2e-relay-customization.yml:e2e_relay_customization'

  # The kind-0 + Blossom plane. C7's egress guard already runs here; the wire
  # oracles are parked on the profile lane until the `_followups` in
  # tooling/e2e/wire_allowlist.json (kinds 10002 / 10050 required-ness) are
  # closed by a real journal from the full flow.
  'e2e-profile.yml:e2e_profile_android'
  'e2e-profile.yml:e2e_profile_ios'

  # Nightly repetition of the e2e_combined flow for flake measurement. It runs
  # the same scenario N times in one job; N journals into one recorder would
  # need per-iteration rotation the harness does not do.
  'e2e-flakiness-stress.yml:flake_stress'
)

VIOLATIONS=0
BROKEN=0

violation() { printf 'FAIL: %s\n' "$*" >&2; VIOLATIONS=$((VIOLATIONS + 1)); }
broken()    { printf 'BROKEN: %s\n' "$*" >&2; BROKEN=$((BROKEN + 1)); }
log()       { printf '[%s] %s\n' "${SELF_NAME}" "$*"; }

# ---------------------------------------------------------------------------
# Extractor. Flattens a workflow into TAB-separated records:
#
#   <basename>\t<job-id>\t<step-index>\t<line-no>\t<text>
#
# Step index 0 means "inside the job but above its first step" — the job-level
# `env:` block, which is where every lane in this repo declares its relay URL.
#
# Full-line comments are dropped, exactly as the raw cross-check below drops
# them, so a commented-out marker is neither counted nor demanded. Inline
# comments are NOT stripped: a `#` inside a `run:` body can be shell, a URL
# fragment or a string, and mis-stripping one would silently shorten a step.
# ---------------------------------------------------------------------------
emit_records() { # emit_records <workflow-file>
  awk -v base="${1##*/}" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }

    # A top-level key closes whatever block we were in.
    /^[^[:space:]]/ {
      injobs = ($0 ~ /^jobs:[[:space:]]*(#.*)?$/) ? 1 : 0
      job = ""; insteps = 0; stepindent = -1; stepidx = 0
      next
    }
    !injobs { next }

    # A job id: exactly two spaces of indent and nothing after the colon.
    /^  [A-Za-z0-9_.-]+:[[:space:]]*(#.*)?$/ {
      job = $0
      sub(/^  /, "", job)
      sub(/:[[:space:]]*(#.*)?$/, "", job)
      insteps = 0; stepindent = -1; stepidx = 0
      next
    }
    job == "" { next }

    /^[[:space:]]*steps:[[:space:]]*(#.*)?$/ {
      insteps = 1; stepindent = -1; stepidx = 0
      next
    }

    {
      if (insteps && $0 ~ /^[[:space:]]*-[[:space:]]/) {
        ind = match($0, /[^ ]/) - 1
        if (stepindent < 0) stepindent = ind
        if (ind == stepindent) stepidx++
      }
      printf "%s\t%s\t%d\t%d\t%s\n", base, job, stepidx, NR, $0
    }
  ' "$1"
}

# Records for one job, in file order.
job_records() { # job_records <records> <file> <job>
  awk -F'\t' -v f="$2" -v j="$3" '$1 == f && $2 == j' <<<"$1"
}

# Records for one step of one job.
step_records() { # step_records <records> <file> <job> <step-index>
  awk -F'\t' -v f="$2" -v j="$3" -v s="$4" \
    '$1 == f && $2 == j && $3 == s' <<<"$1"
}

# The text column only.
text_of() { cut -f5- ; }

# Drops lines that are a hermetic `--self-test` invocation rather than a lane
# step. repo-guards.yml runs the very same scripts that way.
drop_self_tests() { grep -vF -- '--self-test' ; }

_uncommented() { grep -v '^[[:space:]]*#' "$1" ; }

# Joins shell `\` line-continuations so each output line is ONE logical
# command. Without this the unit of analysis is the workflow STEP, and a lane
# that runs all three oracles from a single `run: |` block — which both wired
# lanes do — would satisfy "this step passes --sentinel" on the strength of one
# invocation while the other two read the journal unanchored.
join_continuations() {
  awk '{
    line = $0
    sub(/^[[:space:]]+/, " ", line)
    buf = buf line
    if (buf ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", buf); next }
    print buf; buf = ""
  } END { if (buf != "") print buf }'
}

# One line per ORACLE INVOCATION in a job, arguments joined.
oracle_cmds() { # oracle_cmds <job-records>
  text_of <<<"$1" | join_continuations | grep -E -- "${ORACLE_RE}" | drop_self_tests
}

# The oracle an invocation names, for messages that point at the right one.
oracle_name() { # oracle_name <joined-command>
  grep -oE -- "${ORACLE_RE}" <<<"$1" | head -1
}

# Normalises a sentinel value so the two halves can be compared as STRINGS
# without caring which shell/expression syntax each used:
#   "${TOKEN}"  $TOKEN  ${{ env.TOKEN }}   ->  TOKEN
# A literal token normalises to itself.
norm_token() { # norm_token <raw-value>
  local v="$1"
  v="${v//\"/}"; v="${v//\'/}"
  v="${v//\$/}"; v="${v//\{/}"; v="${v//\}/}"
  v="${v//[[:space:]]/}"
  v="${v#env.}"
  # `${X:-fallback}` names X. The fallback is a CONSTANT, and a constant
  # sentinel is the one value the oracle must never anchor on, so it is dropped
  # here and the binding check below is what decides whether X is real.
  v="${v%%:-*}"
  printf '%s' "${v}"
}

# True when a normalised token actually names something in this job.
#
# The hole this closes: `--sentinel "${TOKEN}"` and
# `--dart-define=HAVEN_WIRE_SENTINEL="${TOKEN}"` are trivially "the same
# string" when TOKEN is set nowhere — both halves expand to empty. The drive
# then emits `TestRelay`'s compiled-in defaultValue and the oracle anchors on
# "", so the run proves nothing while every string comparison here holds.
token_is_bound() { # token_is_bound <normalised-token> <job-text>
  local t="$1" txt="$2"
  # Not a bare shell identifier: either a literal token, or a GitHub
  # expression context (`github.run_id`, `steps.mint.outputs.token`,
  # `inputs.…`). Both are bound by construction.
  [[ "${t}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  # `--dart-define=NAME=…` is a USE of NAME, not a binding. Left in, the
  # reference would certify itself.
  #
  # The binding must carry a NON-EMPTY value. `NAME: ""` is a binding in the
  # grammatical sense and none at all in the sense this check exists for: it
  # is exactly the "both halves expand to empty" hole described above, and
  # e2e-ios.yml really does carry `HAVEN_WIRE_SENTINEL: ""` on its
  # deliberately-uninstrumented background-mirror step. Accepting it let the
  # guard bless a lane whose mint step had been deleted.
  grep -qE "(^|[^[:alnum:]_.])${t}[[:space:]]*[:=][[:space:]]*(\"[^\"]+\"|'[^']+'|[^[:space:]\"'][^[:space:]]*)" \
    <<<"$(sed 's/--dart-define=[^[:space:]]*//g' <<<"${txt}")"
}

# The text of the job PLUS every harness script it invokes that exists on
# disk. One call deeper is as far as this goes, deliberately: it is where the
# lanes put their build, and each extra hop costs a false negative when a
# script cannot be resolved.
chain_text() { # chain_text <job-text>
  local txt="$1" rel
  printf '%s\n' "${txt}"
  while IFS= read -r rel; do
    [[ -n "${rel}" && -f "${HARNESS_ROOT}/${rel}" ]] || continue
    # Full-line comments are dropped, and this is load-bearing rather than
    # tidy: `check-wire-journal.sh`'s own header documents the wiring with a
    # literal `--dart-define=HAVEN_WIRE_SENTINEL="${TOKEN}"` example. Every
    # wired lane invokes that oracle, so without this filter link 4's drive
    # half would be satisfied — in EVERY lane — by the documentation of the
    # thing it is checking.
    _uncommented "${HARNESS_ROOT}/${rel}"
  done < <(grep -oE -- "${HARNESS_REF_RE}" <<<"${txt}" | sort -u)
}

# ---------------------------------------------------------------------------
# Link 1 — the app is pointed at the proxy, not past it.
#
# Every literal `ws://host:PORT` a proxy-starting job declares must name a port
# the proxy LISTENS on. Checking every literal URL rather than only
# `HAVEN_E2E_RELAY` is deliberate: multi-relay lanes (e2e-profile, kp-rotation,
# relay-customization) carry several, and a lane that re-points one and forgets
# the rest records a partial transcript, which is worse than none — it looks
# complete.
# ---------------------------------------------------------------------------
check_relay_points_at_proxy() { # <records> <file> <job>
  local records="$1" file="$2" job="$3"
  local jr; jr="$(job_records "${records}" "${file}" "${job}")"

  # The listen set, read from the lane's own start invocation(s).
  local listen="" line args first port
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    # `HAVEN_WIRE_PROXY_ROUTES='7788=ws://…,7789=ws://…'` wins over argv.
    if [[ "${line}" == *HAVEN_WIRE_PROXY_ROUTES* ]]; then
      while IFS= read -r port; do
        [[ -n "${port}" ]] && listen+="${port%%=*}"$'\n'
      done < <(grep -oE '[0-9]+=wss?://' <<<"${line}")
      continue
    fi
    args="${line#*start-wire-proxy.sh}"
    # A YAML block scalar keeps the shell's `\` line continuations, and one
    # sitting where argv[1] would be reads as a listen port of `\`. That falls
    # through to the 7788 default, so a lane passing an explicit port on the
    # NEXT line would be measured against a port it never uses — the guard
    # reddening a correctly wired lane, which is how guards get deleted.
    args="${args//\\/ }"
    # shellcheck disable=SC2086
    set -- ${args}
    first="${1:-}"
    if [[ "${first}" =~ ^[0-9]+$ ]]; then
      listen+="${first}"$'\n'
    else
      listen+="${DEFAULT_LISTEN_PORT}"$'\n'
    fi
  done < <(text_of <<<"${jr}" | grep -E -- "${PROXY_START_RE}|HAVEN_WIRE_PROXY_ROUTES" | drop_self_tests)

  listen="$(grep -v '^$' <<<"${listen}" | sort -u)"
  if [[ -z "${listen}" ]]; then
    broken "${file}:${job}: the job starts the recorder but no listen port could be derived from it. Either start-wire-proxy.sh's argv convention changed or this guard's parser has rotted into one that would accept any relay URL."
    return
  fi

  # Every literal ws:// / wss:// endpoint the lane hardcodes — EXCEPT the ones
  # on the proxy's own start line or routing table, which are its UPSTREAMS by
  # definition and are supposed to name the relay port.
  local urls
  urls="$(text_of <<<"${jr}" \
            | grep -vE -- "${PROXY_START_RE}|HAVEN_WIRE_PROXY_ROUTES" \
            | grep -oE 'wss?://[A-Za-z0-9._-]+:[0-9]+' | sort -u)"
  if [[ -z "${urls}" ]]; then
    violation "${file}:${job}: the job starts the recorder but declares NO literal ws:// relay endpoint, so nothing here can be checked against the proxy's listen port. Keep the lane's relay URL in the workflow (a \`HAVEN_E2E_RELAY: ws://host:${DEFAULT_LISTEN_PORT}\` env) — a URL that moves into a harness script takes link 1 out of reach of every static check."
    return
  fi

  local url bad=""
  while IFS= read -r url; do
    [[ -z "${url}" ]] && continue
    port="${url##*:}"
    grep -qxF "${port}" <<<"${listen}" || bad+=" ${url}"
  done <<<"${urls}"

  if [[ -n "${bad}" ]]; then
    violation "${file}:${job}: the recorder is started but the app is pointed past it —${bad} does not name a proxy listen port ($(tr '\n' ' ' <<<"${listen}" | sed 's/ *$//')). The proxy forwards to the relay, so traffic aimed at the RELAY port never reaches the recorder and the journal is empty-but-valid: all three oracles then report CLEAN over nothing. If that URL is the proxy's own UPSTREAM rather than the app's relay, declare it where it is recognisable as one — on the start-wire-proxy.sh line itself, or in HAVEN_WIRE_PROXY_ROUTES — rather than in a separate \`env:\` entry, which is indistinguishable from an app-facing URL."
  fi
}

# ---------------------------------------------------------------------------
# Link 2 — the recorder is stopped, on every outcome.
# ---------------------------------------------------------------------------
check_proxy_is_stopped() { # <records> <file> <job>
  local records="$1" file="$2" job="$3"
  local jr; jr="$(job_records "${records}" "${file}" "${job}")"

  local stop_steps
  stop_steps="$(awk -F'\t' -v re="${PROXY_STOP_RE}" '$5 ~ re' <<<"${jr}" \
                 | drop_self_tests | cut -f3 | sort -nu)"
  if [[ -z "${stop_steps}" ]]; then
    violation "${file}:${job}: the job starts the recorder and never stops it. start-wire-proxy.sh CLAIMS its journal path in a sidecar and refuses to start while another live instance holds it, so a leaked proxy on a reused runner disables recording for every later run — the first red run silently switches the instrument off. Add a \`bash tooling/e2e/ci/stop-wire-proxy.sh\` step under \`if: always()\`."
    return
  fi

  local s step_text
  while IFS= read -r s; do
    [[ -z "${s}" ]] && continue
    if [[ "${s}" == "0" ]]; then
      violation "${file}:${job}: stop-wire-proxy.sh appears outside any step, so it can carry no \`if:\` at all and will not run on the failure path."
      continue
    fi
    step_text="$(step_records "${records}" "${file}" "${job}" "${s}" | text_of)"
    if ! grep -qE 'if:.*always\(\)' <<<"${step_text}"; then
      violation "${file}:${job}: the stop-wire-proxy.sh step is not guarded by \`if: always()\`. The failure path is exactly the path that leaks the recorder: a lane only leaves a live proxy behind when the drive failed, which is when the teardown is skipped by default step-on-failure semantics."
    fi
  done <<<"${stop_steps}"
}

# ---------------------------------------------------------------------------
# Link 3 — at least one oracle runs, over a journal, after the proxy started.
# ---------------------------------------------------------------------------
check_oracle_runs() { # <records> <file> <job>
  local records="$1" file="$2" job="$3"
  local jr; jr="$(job_records "${records}" "${file}" "${job}")"

  local oracle_lines
  oracle_lines="$(awk -F'\t' -v re="${ORACLE_RE}" '$5 ~ re' <<<"${jr}" | drop_self_tests)"
  if [[ -z "${oracle_lines}" ]]; then
    violation "${file}:${job}: the job records a wire journal and asserts NOTHING over it. Run at least one of check-wire-journal.sh / check-wire-correlation.sh / check-wire-canaries.dart post-drive. A lane that records without asserting pays the whole cost of the instrument and buys none of its verdict — and leaves all three oracles still proven only by their own fixtures."
    return
  fi

  local first_oracle first_start
  first_oracle="$(cut -f4 <<<"${oracle_lines}" | sort -n | head -1)"
  first_start="$(awk -F'\t' -v re="${PROXY_START_RE}" '$5 ~ re' <<<"${jr}" \
                  | drop_self_tests | cut -f4 | sort -n | head -1)"
  if [[ -n "${first_start}" ]] && (( first_oracle < first_start )); then
    violation "${file}:${job}: an oracle step (line ${first_oracle}) sits ABOVE the start-wire-proxy.sh step (line ${first_start}). Workflow steps run in file order, so it reads whatever journal the runner happened to be carrying — from a previous job on a reused runner, or nothing at all."
  fi

  # POST-DRIVE. The proxy-start ordering above only proves the journal exists;
  # it does not prove anything was recorded INTO it. An oracle that runs before
  # every drive reads the file the proxy created and nothing else — which is
  # not an error at any layer: a journal with no client->relay events is
  # exactly what the oracles call META-FLOOR, and a lane that reaches that
  # state through step ORDER looks, in the log, like a scenario that published
  # nothing.
  local first_drive last_oracle
  first_drive="$(awk -F'\t' -v re="${DRIVE_RE}" '$5 ~ re' <<<"${jr}" \
                  | drop_self_tests | cut -f4 | sort -n | head -1)"
  if [[ -z "${first_drive}" ]]; then
    broken "${file}:${job}: the job records a wire journal but no drive step could be identified in it (nothing matching \`tooling/e2e/ci/run-*.sh\` or \`flutter drive\`). Either the lane records a journal it never drives traffic into, or this guard's drive convention has rotted and link 3's post-drive ordering is asserting nothing here."
  else
    last_oracle="$(cut -f4 <<<"${oracle_lines}" | sort -n | tail -1)"
    if (( last_oracle < first_drive )); then
      violation "${file}:${job}: every oracle step (last at line ${last_oracle}) sits ABOVE the first drive step (line ${first_drive}). The journal exists by then but the scenario has not run, so the oracles read a file with no client->relay traffic in it and report META-FLOOR — a wiring bug that reads like a scenario that published nothing."
    fi
  fi

  # Per INVOCATION, not per step: see join_continuations().
  local cmd
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    if ! grep -qF -- '--journal' <<<"${cmd}"; then
      violation "${file}:${job}: the \`$(oracle_name "${cmd}")\` invocation names no \`--journal\`. All three oracles require at least one and exit 2 (usage) without it, so this call cannot be reading the recording at all."
    fi
  done < <(oracle_cmds "${jr}")
}

# ---------------------------------------------------------------------------
# Link 4 — one sentinel string, both halves.
# ---------------------------------------------------------------------------
check_sentinel_is_shared() { # <records> <file> <job>
  local records="$1" file="$2" job="$3"
  local jr; jr="$(job_records "${records}" "${file}" "${job}")"
  local txt; txt="$(text_of <<<"${jr}")"

  # The DRIVE half: a `--dart-define=HAVEN_WIRE_SENTINEL=` anywhere the job can
  # reach — spelled in the workflow, or spelled in a harness script the job
  # invokes. The Android and iOS lanes build the app INSIDE
  # run-single-avd-scenario.sh / run-ios-sim-scenario.sh, so requiring the
  # define in the workflow would red a correctly wired lane; accepting a bare
  # `HAVEN_WIRE_SENTINEL:` env instead (what this used to do) would pass a lane
  # whose env reaches no define at all, which is the failure that costs the
  # most: `TestRelay`'s token is `String.fromEnvironment(..., defaultValue:
  # 'HAVEN_WIRE_SENTINEL:default…')`, so a missing define does not fail the
  # build — the app emits a CONSTANT token and the oracle anchors on a string
  # the run never produced.
  local drive="" v
  while IFS= read -r v; do
    [[ -z "${v}" ]] && continue
    drive+="$(norm_token "${v#--dart-define=HAVEN_WIRE_SENTINEL=}")"$'\n'
  done < <(grep -oE -- '--dart-define=HAVEN_WIRE_SENTINEL=[^[:space:]\\]+' \
             <<<"$(chain_text "${txt}")")

  drive="$(grep -v '^$' <<<"${drive}" | sort -u)"

  # The ORACLE half, PER INVOCATION. Both wired lanes run more than one oracle
  # out of a single `run: |` block, so a step-level test would let one anchored
  # call vouch for its unanchored neighbours.
  local cmds; cmds="$(oracle_cmds "${jr}")"
  [[ -z "${cmds}" ]] && return   # link 3 already reported this

  local cmd oracle="" missing=""
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    local found=""
    while IFS= read -r v; do
      [[ -z "${v}" ]] && continue
      v="${v#--sentinel}"; v="${v#=}"
      oracle+="$(norm_token "${v}")"$'\n'
      found=1
    done < <(grep -oE -- '--sentinel[= ]+[^[:space:]\\]+' <<<"${cmd}")
    [[ -z "${found}" ]] && missing+=" $(oracle_name "${cmd}")"
  done <<<"${cmds}"

  oracle="$(grep -v '^$' <<<"${oracle}" | sort -u)"

  if [[ -n "${missing}" ]]; then
    violation "${file}:${job}: an oracle invocation passes no \`--sentinel\` (${missing# }). Without it the read is unanchored: a background wake appending to the journal mid-read lands inside the snapshot, and check-wire-journal.sh / check-wire-correlation.sh refuse the run as META-FLOOR (rc 4, \"the read cannot be anchored\") rather than guessing."
  fi

  if [[ -z "${drive}" ]]; then
    violation "${file}:${job}: an oracle is anchored on a sentinel the DRIVE is never given. No \`--dart-define=HAVEN_WIRE_SENTINEL=\` appears in this job or in any tooling/e2e/ci/*.sh it invokes, so the app compiles TestRelay's defaultValue instead — a CONSTANT token, identical on every run, which the oracle will never find. An \`env:\` entry alone is not the define; something has to forward it."
    return
  fi

  local t bad="" unbound=""
  while IFS= read -r t; do
    [[ -z "${t}" ]] && continue
    grep -qxF "${t}" <<<"${drive}" || bad+=" ${t}"
    token_is_bound "${t}" "${txt}" || unbound+=" ${t}"
  done <<<"${oracle}"

  if [[ -n "${bad}" ]]; then
    violation "${file}:${job}: the two halves of the sentinel do not name the same string — the oracle anchors on '${bad# }' while the drive is handed '$(tr '\n' ' ' <<<"${drive}" | sed 's/ *$//')'. There must be ONE string read from ONE place by both halves; minting it twice yields two different random tokens and the failure then reads as a flake instead of a wiring bug."
  fi

  if [[ -n "${unbound}" ]]; then
    violation "${file}:${job}: the sentinel variable '${unbound# }' is REFERENCED by both halves and SET by neither — no \`env:\` entry, no \`>> \$GITHUB_ENV\` write, no assignment in this job. Both halves then expand to the empty string, which makes them trivially equal: the string comparison this guard performs would hold, the drive would fall back to TestRelay's compiled-in default token, and the oracle would anchor on nothing."
  fi
}

# ---------------------------------------------------------------------------
# Anti-vacuity. Derive what the extractor SHOULD have seen by grepping the raw
# files — a different mechanism reading the same source — and name the file
# whenever the two disagree. This is the half that stops the guard decaying
# into a rubber stamp when a workflow convention changes under it.
# ---------------------------------------------------------------------------
check_extractor_sees_the_repo() { # <records> <workflow-dir> <candidate-set>
  local records="$1" wf="$2" candidates="$3"
  local f base raw att

  # (a) EXACT count of proxy starts. `start-wire-proxy.sh` appears once per
  #     invocation, so the raw line count IS the number of invocations — no
  #     estimate. If the record parser stops attributing one (a job header the
  #     job regex no longer matches, a `steps:` block it never enters), the
  #     grep still finds it and the mismatch names the file.
  for f in "${wf}"/*.yml "${wf}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    base="${f##*/}"
    raw="$(_uncommented "${f}" | grep -E -- "${PROXY_START_RE}" | drop_self_tests | wc -l)"
    att="$(awk -F'\t' -v b="${base}" -v re="${PROXY_START_RE}" \
             '$1 == b && $5 ~ re' <<<"${records}" | drop_self_tests | wc -l)"
    raw="${raw//[[:space:]]/}"; att="${att//[[:space:]]/}"
    if (( raw != att )); then
      broken "${base}: the raw files contain ${raw} start-wire-proxy.sh invocation(s) but the extractor attributed ${att} to a job. It has stopped parsing this workflow, so every link check below is silently skipped for it."
    fi
  done

  # (b) SET coverage of the POPULATION. Any workflow that brings up a hermetic
  #     relay must contribute at least one candidate job — otherwise the lane
  #     is invisible to the equality pin and could neither be demanded nor
  #     excused. Names the lane rather than reporting a count.
  local missing=""
  for f in "${wf}"/*.yml "${wf}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    base="${f##*/}"
    _uncommented "${f}" | grep -E -- "${RELAY_START_RE}|${PROXY_START_RE}" \
      | drop_self_tests | grep -q . || continue
    grep -q "^${base}:" <<<"${candidates}" || missing+=" ${base}"
  done
  [[ -z "${missing}" ]] || broken "these workflows start a hermetic relay but the extractor counted no job in them:${missing}. Either the lane changed shape or the job parser stopped matching, and the known-unwired equality pin can no longer see them."
}

# ---------------------------------------------------------------------------
# The whole check over one workflow directory.
# ---------------------------------------------------------------------------
check_dir() { # check_dir <workflow-dir> <exempt-list-newline-separated> [harness-root]
  local wf="$1" exempt="$2"
  HARNESS_ROOT="${3:-${REPO_ROOT}}"
  local records="" f

  [[ -d "${wf}" ]] || { broken "${wf} not found"; return; }

  for f in "${wf}"/*.yml "${wf}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    records+="$(emit_records "${f}")"$'\n'
  done
  records="$(grep -v '^$' <<<"${records}")"
  if [[ -z "${records}" ]]; then
    broken "${wf}: the extractor produced no records at all from $(ls -1 "${wf}" 2>/dev/null | wc -l | tr -d ' ') file(s)."
    return
  fi

  # Population: every job that starts a hermetic relay OR the recorder —
  # matched over the job text PLUS one call deeper, exactly as link 4 reads it.
  #
  # The chain hop is what closes the set-membership hole. `candidates` and
  # `wired` are both derived from the same text, so a lane that stops matching
  # RELAY_START_RE at the same moment it stops matching PROXY_START_RE leaves
  # BOTH sets and lands in neither `unwired` nor the equality pin — it exits
  # every check in this file, silently. That is not hypothetical: folding a
  # lane's `start-local-relay.sh` and `start-wire-proxy.sh` calls into one
  # `run-ios-sim-bringup.sh` is the same one-call-deeper refactor this repo
  # already applies to its builds, and before this hop it dropped the iOS lane
  # out of the population with the guard still reporting OK. Reading the chain
  # means the bringup script's own text keeps the lane in the population, so
  # the loss of wiring surfaces as an undeclared lane instead of as nothing.
  local candidates wired unwired
  local pop_records="" rec jt
  while IFS= read -r rec; do
    [[ -n "${rec}" ]] || continue
    jt="$(chain_text "$(awk -F'\t' '{print $5}' <<<"${rec}")")"
    pop_records+="$(awk -F'\t' -v OFS='\t' -v t="${jt//$'\n'/ }" '{$5=t; print}' <<<"${rec}")"$'\n'
  done <<<"${records}"
  pop_records="$(grep -v '^$' <<<"${pop_records}")"

  candidates="$(awk -F'\t' -v re="${RELAY_START_RE}|${PROXY_START_RE}" '$5 ~ re' <<<"${pop_records}" \
                 | drop_self_tests | awk -F'\t' '{print $1":"$2}' | sort -u)"
  wired="$(awk -F'\t' -v re="${PROXY_START_RE}" '$5 ~ re' <<<"${records}" \
            | drop_self_tests | awk -F'\t' '{print $1":"$2}' | sort -u)"

  check_extractor_sees_the_repo "${records}" "${wf}" "${candidates}"

  if [[ -z "${candidates}" ]]; then
    broken "no job in ${wf} starts a hermetic relay or the recorder. The population this guard reasons over is empty, so every set comparison below would hold vacuously."
    return
  fi

  # (c) The floor that cannot be exempted. Zero instrumented lanes is the state
  #     Workstream C exists to end; a guard that PASSED there would be the
  #     eleventh instance of the failure mode it was written for.
  if [[ -z "${wired}" ]]; then
    violation "NO lane wires the recording proxy. All three wire oracles (check-wire-journal.sh, check-wire-correlation.sh, check-wire-canaries.dart) are green on every PR from their own --self-test fixtures and have never read a journal produced by a real run. $(wc -l <<<"${candidates}" | tr -d ' ') relay-starting job(s) exist and none of them starts start-wire-proxy.sh."
  fi

  # (d) Equality pin over the known-unwired set.
  unwired="$(comm -23 <(printf '%s\n' "${candidates}") <(printf '%s\n' "${wired}"))"
  local declared; declared="$(grep -v '^$' <<<"${exempt}" | sort -u)"
  local undeclared stale
  undeclared="$(comm -23 <(printf '%s\n' "${unwired}") <(printf '%s\n' "${declared}") | grep -v '^$')"
  stale="$(comm -13 <(printf '%s\n' "${unwired}") <(printf '%s\n' "${declared}") | grep -v '^$')"

  if [[ -n "${undeclared}" ]]; then
    violation "these relay-starting lanes neither wire the recorder nor appear in KNOWN_UNWIRED_LANES: $(tr '\n' ' ' <<<"${undeclared}" | sed 's/ *$//'). Either instrument them or add them to the list WITH A REASON — the list is pinned by equality precisely so that excusing a lane is a visible act in the diff, and so that a lane which silently LOSES its wiring surfaces here."
  fi
  if [[ -n "${stale}" ]]; then
    violation "these entries in KNOWN_UNWIRED_LANES are stale — the job either wires the recorder now, or no longer exists: $(tr '\n' ' ' <<<"${stale}" | sed 's/ *$//'). A stale exemption is an exemption nobody can re-derive; delete the line."
  fi

  # The four links, per wired job.
  local entry file job
  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    file="${entry%%:*}"; job="${entry#*:}"
    check_relay_points_at_proxy "${records}" "${file}" "${job}"
    check_proxy_is_stopped     "${records}" "${file}" "${job}"
    check_oracle_runs          "${records}" "${file}" "${job}"
    check_sentinel_is_shared   "${records}" "${file}" "${job}"
  done <<<"${wired}"

  if (( VIOLATIONS == 0 && BROKEN == 0 )); then
    log "$(wc -l <<<"${candidates}" | tr -d ' ') relay-starting job(s); $(grep -c . <<<"${wired}") wired end to end; $(grep -c . <<<"${declared}") declared unwired, and the two sets partition the population exactly"
  fi
}

# ---------------------------------------------------------------------------
# Self-test. Hermetic: synthetic workflow directories in a temp dir, no repo
# access. Every fixture pins BOTH directions — the shape that must pass and the
# exact break that must fail — because a guard made of greps is worth only what
# its fixtures prove, and this one's whole job is to notice an absence.
# ---------------------------------------------------------------------------

# A lane with the chain complete. Callers mutate one line to break one link.
write_wired_lane() { # write_wired_lane <dir> [relay-port] [extra...]
  local dir="$1" port="${2:-7788}"
  mkdir -p "${dir}"
  cat > "${dir}/e2e-android.yml" <<YAML
name: E2E Android
on:
  workflow_call:
jobs:
  e2e_android:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    env:
      HAVEN_E2E_RELAY: ws://10.0.2.2:${port}
      HAVEN_WIRE_SENTINEL: HAVEN_WIRE_SENTINEL:\${{ github.run_id }}-\${{ github.run_attempt }}
    steps:
      - name: Checkout
        uses: actions/checkout@v6
      - name: Build E2E test APK
        run: |
          flutter build apk --debug \\
            --dart-define=HAVEN_E2E_RELAY="\${HAVEN_E2E_RELAY}" \\
            --dart-define=HAVEN_WIRE_SENTINEL="\${HAVEN_WIRE_SENTINEL}"
      - name: Start strfry relay
        run: bash tooling/e2e/ci/start-strfry.sh
      - name: Start wire proxy
        run: bash tooling/e2e/ci/start-wire-proxy.sh
      - name: Run e2e_combined on the emulator
        run: bash tooling/e2e/ci/run-single-avd-scenario.sh integration_test/e2e/e2e_combined.dart
      - name: Wire journal closed-world oracle
        if: always()
        run: |
          bash tooling/e2e/ci/check-wire-journal.sh \\
            --journal /tmp/haven-wire-journal.ndjson \\
            --sentinel "\${HAVEN_WIRE_SENTINEL}"
      - name: Stop wire proxy
        if: always()
        run: bash tooling/e2e/ci/stop-wire-proxy.sh
      - name: Tear down strfry relay
        if: always()
        run: bash tooling/e2e/ci/stop-strfry.sh
YAML
}

# A lane that starts a relay and nothing else — the exemption population.
write_plain_lane() { # write_plain_lane <dir> <basename> <job-id>
  local dir="$1" base="$2" job="$3"
  mkdir -p "${dir}"
  cat > "${dir}/${base}" <<YAML
name: ${job}
on:
  workflow_call:
jobs:
  ${job}:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    env:
      HAVEN_E2E_RELAY: ws://10.0.2.2:7777
    steps:
      - name: Start strfry relay
        run: bash tooling/e2e/ci/start-strfry.sh
      - name: Drive
        run: bash tooling/e2e/ci/run-single-avd-scenario.sh x.dart
YAML
}

self_test() {
  local tmp failures=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # Exemption list used by every fixture unless a case overrides it.
  local EX_PLAIN='e2e-integration.yml:e2e_integration'

  # Harness root every fixture resolves `tooling/e2e/ci/*.sh` against. It is
  # EMPTY by default, so a fixture's verdict depends on the fixture and never
  # on the checked-out repo — the self-test has to stay hermetic, and reading
  # the real scripts would let a lane's link-4 verdict change under it.
  mkdir -p "${tmp}/harness-empty"

  _expect() { # _expect <desc> <dir> <exempt> <want-rc> [want-substring] [harness-root]
    local desc="$1" dir="$2" exempt="$3" want="$4" want_grep="${5:-}"
    local harness="${6:-${tmp}/harness-empty}"
    local out rc=0
    VIOLATIONS=0; BROKEN=0
    check_dir "${dir}" "${exempt}" "${harness}" >"${tmp}/out.txt" 2>"${tmp}/err.txt"
    out="$(cat "${tmp}/out.txt" "${tmp}/err.txt")"
    if (( BROKEN > 0 )); then rc=2; elif (( VIOLATIONS > 0 )); then rc=1; fi
    # A check that PRINTS a finding without counting it would exit 0 in the
    # real run; a check that counts without printing names nothing for the
    # operator. Both are failures of the guard, not of the fixture.
    if grep -q '^FAIL:' <<<"${out}" && (( VIOLATIONS == 0 )); then
      echo "  FAIL: ${desc}: a violation was printed but not counted" >&2
      failures=1; return
    fi
    if grep -q '^BROKEN:' <<<"${out}" && (( BROKEN == 0 )); then
      echo "  FAIL: ${desc}: a misconfiguration was printed but not counted" >&2
      failures=1; return
    fi
    if (( rc != want )); then
      echo "  FAIL: ${desc}: expected rc ${want}, got ${rc}" >&2
      sed 's/^/      /' <<<"${out}" >&2
      failures=1; return
    fi
    if [[ -n "${want_grep}" ]] && ! grep -qF -- "${want_grep}" <<<"${out}"; then
      echo "  FAIL: ${desc}: output did not name '${want_grep}'" >&2
      sed 's/^/      /' <<<"${out}" >&2
      failures=1; return
    fi
    echo "  ok: ${desc}"
  }

  echo "[${SELF_NAME}] self-test"

  # --- A. The healthy shape. Nothing may fire. This is the fixture that stops
  #        a guard hard-coded to red from looking correct on every negative one.
  local a="${tmp}/a"; write_wired_lane "${a}"
  write_plain_lane "${a}" 'e2e-integration.yml' 'e2e_integration'
  _expect "a correctly wired lane plus one declared exemption passes" \
    "${a}" "${EX_PLAIN}" 0

  # --- B. Link 1: the proxy is started, the app still points at the relay.
  local b="${tmp}/b"; write_wired_lane "${b}" 7777
  write_plain_lane "${b}" 'e2e-integration.yml' 'e2e_integration'
  _expect "link 1: relay URL left on the upstream port fails, naming it" \
    "${b}" "${EX_PLAIN}" 1 "ws://10.0.2.2:7777"

  # ...and the routing-table form must PASS, or a multi-relay lane could never
  #    be instrumented and the guard would red on a correct repo.
  local b2="${tmp}/b2"; write_wired_lane "${b2}" 7789
  write_plain_lane "${b2}" 'e2e-integration.yml' 'e2e_integration'
  sed -i "s|run: bash tooling/e2e/ci/start-wire-proxy.sh|run: HAVEN_WIRE_PROXY_ROUTES='7788=ws://127.0.0.1:7777,7789=ws://127.0.0.1:7778' bash tooling/e2e/ci/start-wire-proxy.sh|" \
    "${b2}/e2e-android.yml"
  _expect "link 1: a routing table declares its listen ports and passes" \
    "${b2}" "${EX_PLAIN}" 0

  # ...and an explicit argv port must be honoured too.
  local b3="${tmp}/b3"; write_wired_lane "${b3}" 9999
  write_plain_lane "${b3}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|start-wire-proxy.sh$|start-wire-proxy.sh 9999 ws://127.0.0.1:7777|' \
    "${b3}/e2e-android.yml"
  _expect "link 1: an explicit argv listen port is honoured" \
    "${b3}" "${EX_PLAIN}" 0

  # ...and the VACUITY route for link 1: a lane whose relay URL is not in the
  #    workflow at all. Every port comparison would then hold over an empty
  #    set — the guard would report link 1 clean having compared nothing.
  local b4="${tmp}/b4"; write_wired_lane "${b4}"
  write_plain_lane "${b4}" 'e2e-integration.yml' 'e2e_integration'
  sed -i '/HAVEN_E2E_RELAY: ws:/d' "${b4}/e2e-android.yml"
  _expect "link 1: a wired lane with no literal relay URL fails, not passes" \
    "${b4}" "${EX_PLAIN}" 1 "declares NO literal ws://"

  # ...and the link-1 parser's OWN rot case. A routing table whose value the
  #    guard cannot read leaves it with no listen port to compare against — at
  #    which point every URL in the lane would trivially "match" the empty set.
  #    That must be BROKEN (the instrument cannot see), never a quiet pass.
  local b5="${tmp}/b5"; write_wired_lane "${b5}"
  write_plain_lane "${b5}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|run: bash tooling/e2e/ci/start-wire-proxy.sh|run: HAVEN_WIRE_PROXY_ROUTES="${WIRE_ROUTES}" bash tooling/e2e/ci/start-wire-proxy.sh|' \
    "${b5}/e2e-android.yml"
  _expect "link 1: an unreadable routing table is BROKEN, not a pass" \
    "${b5}" "${EX_PLAIN}" 2 "no listen port could be derived"

  # --- C. Link 2: no teardown at all.
  local c="${tmp}/c"; write_wired_lane "${c}"
  write_plain_lane "${c}" 'e2e-integration.yml' 'e2e_integration'
  perl -0pi -e 's/      - name: Stop wire proxy\n        if: always\(\)\n        run: bash tooling\/e2e\/ci\/stop-wire-proxy\.sh\n//' \
    "${c}/e2e-android.yml" 2>/dev/null \
    || sed -i '/stop-wire-proxy.sh/d' "${c}/e2e-android.yml"
  _expect "link 2: a lane that never stops the recorder fails" \
    "${c}" "${EX_PLAIN}" 1 "never stops it"

  # --- C2. Link 2: teardown present but not on the failure path. This is the
  #         sharp one: the step EXISTS and reads correct in a diff.
  local c2="${tmp}/c2"; write_wired_lane "${c2}"
  write_plain_lane "${c2}" 'e2e-integration.yml' 'e2e_integration'
  perl -0pi -e 's/(      - name: Stop wire proxy\n)        if: always\(\)\n/$1/' \
    "${c2}/e2e-android.yml"
  _expect "link 2: a teardown without if: always() fails" \
    "${c2}" "${EX_PLAIN}" 1 "not guarded by"

  # --- C3. Link 2: the teardown named in a job-level `env:` rather than a
  #         step. It reads like wiring in a diff and can carry no `if:` at all,
  #         so it never runs on any path.
  local c3="${tmp}/c3"; write_wired_lane "${c3}"
  write_plain_lane "${c3}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|      HAVEN_E2E_RELAY: ws://10.0.2.2:7788|      HAVEN_E2E_RELAY: ws://10.0.2.2:7788\n      TEARDOWN_CMD: bash tooling/e2e/ci/stop-wire-proxy.sh|' \
    "${c3}/e2e-android.yml"
  _expect "link 2: a teardown outside any step fails" \
    "${c3}" "${EX_PLAIN}" 1 "outside any step"

  # --- D. Link 3: recording with no oracle.
  local d="${tmp}/d"; write_wired_lane "${d}"
  write_plain_lane "${d}" 'e2e-integration.yml' 'e2e_integration'
  perl -0pi -e 's/      - name: Wire journal closed-world oracle\n        if: always\(\)\n        run: \|\n(          .*\n)+//' \
    "${d}/e2e-android.yml"
  _expect "link 3: recording without asserting fails" \
    "${d}" "${EX_PLAIN}" 1 "asserts NOTHING over it"

  # --- D2. Link 3: an oracle placed ABOVE the proxy start reads a journal from
  #         a previous run. Steps run in file order; this is a real ordering bug.
  local d2="${tmp}/d2"; write_wired_lane "${d2}"
  write_plain_lane "${d2}" 'e2e-integration.yml' 'e2e_integration'
  perl -0pi -e 's/(      - name: Start wire proxy\n        run: bash tooling\/e2e\/ci\/start-wire-proxy\.sh\n)((      - name: Run e2e_combined on the emulator\n        run: .*\n)(      - name: Wire journal closed-world oracle\n        if: always\(\)\n        run: \|\n(?:          .*\n)+))/$4$1$3/' \
    "${d2}/e2e-android.yml"
  # The substring is the FULL phrase, not "sits ABOVE": moving the oracle above
  # the proxy start also moves it above the drive, so both ordering rules fire
  # and a loose match would let either one stand in for the other. Mutation-
  # tested: with the proxy-start rule neutered this fixture must still red.
  _expect "link 3: an oracle above the proxy start fails" \
    "${d2}" "${EX_PLAIN}" 1 "sits ABOVE the start-wire-proxy.sh step"

  # --- D3. Link 3: the oracle runs but names no journal.
  local d3="${tmp}/d3"; write_wired_lane "${d3}"
  write_plain_lane "${d3}" 'e2e-integration.yml' 'e2e_integration'
  sed -i '/--journal \/tmp\/haven-wire-journal.ndjson/d' "${d3}/e2e-android.yml"
  _expect "link 3: an oracle step with no --journal fails" \
    "${d3}" "${EX_PLAIN}" 1 "names no"

  # --- D4. Link 3, the post-drive half. The oracle sits AFTER the proxy start
  #         (so D2 cannot fire) and BEFORE the drive, which is the version of
  #         the bug that produces a syntactically perfect journal containing
  #         nothing. Both oracles then report META-FLOOR, which reads in the
  #         log as a scenario that published nothing rather than as a lane
  #         whose steps are in the wrong order.
  local d4="${tmp}/d4"; write_wired_lane "${d4}"
  write_plain_lane "${d4}" 'e2e-integration.yml' 'e2e_integration'
  perl -0pi -e 's/(      - name: Run e2e_combined on the emulator\n        run: .*\n)((      - name: Wire journal closed-world oracle\n        if: always\(\)\n        run: \|\n(?:          .*\n)+))/$2$1/' \
    "${d4}/e2e-android.yml"
  _expect "link 3: an oracle above the first drive fails" \
    "${d4}" "${EX_PLAIN}" 1 "sits ABOVE the first drive"

  # --- D5. ...and the vacuity route for that assertion: a wired lane in which
  #         no drive step can be identified at all. The ordering comparison
  #         would then hold over an empty set, so it must be BROKEN.
  local d5="${tmp}/d5"; write_wired_lane "${d5}"
  write_plain_lane "${d5}" 'e2e-integration.yml' 'e2e_integration'
  sed -i '/run-single-avd-scenario.sh/d' "${d5}/e2e-android.yml"
  _expect "link 3: a wired lane with no identifiable drive is BROKEN" \
    "${d5}" "${EX_PLAIN}" 2 "no drive step could be identified"

  # --- E. Link 4: the oracle anchors on a token the drive never got.
  local e="${tmp}/e"; write_wired_lane "${e}"
  write_plain_lane "${e}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|--sentinel "${HAVEN_WIRE_SENTINEL}"|--sentinel "${SOME_OTHER_TOKEN}"|' \
    "${e}/e2e-android.yml"
  _expect "link 4: two different sentinel strings fail" \
    "${e}" "${EX_PLAIN}" 1 "do not name the same string"

  # --- E2. Link 4: no --sentinel at all — the read is unanchored.
  local e2="${tmp}/e2"; write_wired_lane "${e2}"
  write_plain_lane "${e2}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's| *--sentinel "${HAVEN_WIRE_SENTINEL}"||' "${e2}/e2e-android.yml"
  _expect "link 4: an oracle with no --sentinel fails" \
    "${e2}" "${EX_PLAIN}" 1 "passes no"

  # --- E2b. The GRANULARITY of E2, and the gap that the real lanes exposed:
  #          both of them run several oracles out of ONE `run: |` block. A
  #          step-level test lets the first, correctly anchored invocation
  #          vouch for its neighbours, so this fixture adds a SECOND oracle to
  #          the same step and strips only that one's `--sentinel`. The step
  #          still contains the flag; the second call is still unanchored.
  local e2b="${tmp}/e2b"; write_wired_lane "${e2b}"
  write_plain_lane "${e2b}" 'e2e-integration.yml' 'e2e_integration'
  perl -0pi -e 's|(\n            --sentinel "\$\{HAVEN_WIRE_SENTINEL\}"\n)|$1          bash tooling/e2e/ci/check-wire-correlation.sh \\\n            --journal /tmp/haven-wire-journal.ndjson\n|' \
    "${e2b}/e2e-android.yml"
  _expect "link 4: a SECOND oracle in the same step without --sentinel fails" \
    "${e2b}" "${EX_PLAIN}" 1 "check-wire-correlation.sh"

  # ...and the same granularity for link 3's --journal.
  local e2c="${tmp}/e2c"; write_wired_lane "${e2c}"
  write_plain_lane "${e2c}" 'e2e-integration.yml' 'e2e_integration'
  perl -0pi -e 's|(\n            --sentinel "\$\{HAVEN_WIRE_SENTINEL\}"\n)|$1          bash tooling/e2e/ci/check-wire-correlation.sh \\\n            --sentinel "\$\{HAVEN_WIRE_SENTINEL\}"\n|' \
    "${e2c}/e2e-android.yml"
  _expect "link 3: a SECOND oracle in the same step without --journal fails" \
    "${e2c}" "${EX_PLAIN}" 1 "invocation names no"

  # --- E3. Link 4: the drive is never handed the token.
  local e3="${tmp}/e3"; write_wired_lane "${e3}"
  write_plain_lane "${e3}" 'e2e-integration.yml' 'e2e_integration'
  sed -i '/HAVEN_WIRE_SENTINEL: HAVEN_WIRE_SENTINEL:/d' "${e3}/e2e-android.yml"
  sed -i '/--dart-define=HAVEN_WIRE_SENTINEL=/d' "${e3}/e2e-android.yml"
  _expect "link 4: a sentinel the drive never receives fails" \
    "${e3}" "${EX_PLAIN}" 1 "never given"

  # --- E4. Link 4 false-positive direction: a lane that renames the variable
  #         and writes it from a mint step must PASS. `${X}` and `$X` are one
  #         string, and a `>> $GITHUB_ENV` write is a binding.
  local e4="${tmp}/e4"; write_wired_lane "${e4}"
  write_plain_lane "${e4}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|      HAVEN_WIRE_SENTINEL: HAVEN_WIRE_SENTINEL:.*|      DUMMY: unused|' \
    "${e4}/e2e-android.yml"
  sed -i 's|      - name: Build E2E test APK|      - name: Mint the wire sentinel\n        run: echo "TOKEN=HAVEN_WIRE_SENTINEL:$(openssl rand -hex 16)" >> "$GITHUB_ENV"\n      - name: Build E2E test APK|' \
    "${e4}/e2e-android.yml"
  sed -i 's|--dart-define=HAVEN_WIRE_SENTINEL="${HAVEN_WIRE_SENTINEL}"|--dart-define=HAVEN_WIRE_SENTINEL="${TOKEN}"|' \
    "${e4}/e2e-android.yml"
  sed -i 's|--sentinel "${HAVEN_WIRE_SENTINEL}"|--sentinel $TOKEN|' \
    "${e4}/e2e-android.yml"
  _expect "link 4: \${X} in one half and \$X in the other is one string" \
    "${e4}" "${EX_PLAIN}" 0

  # --- E5. Link 4's sharpest failure, and the one the draft of this guard
  #         PASSED: both halves name the same variable and NOTHING sets it.
  #         Every string comparison holds — over the empty string. Same file as
  #         E4 minus the mint step, so the fixture differs by exactly the bug.
  local e5="${tmp}/e5"; write_wired_lane "${e5}"
  write_plain_lane "${e5}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|      HAVEN_WIRE_SENTINEL: HAVEN_WIRE_SENTINEL:.*|      DUMMY: unused|' \
    "${e5}/e2e-android.yml"
  sed -i 's|--dart-define=HAVEN_WIRE_SENTINEL="${HAVEN_WIRE_SENTINEL}"|--dart-define=HAVEN_WIRE_SENTINEL="${TOKEN}"|' \
    "${e5}/e2e-android.yml"
  sed -i 's|--sentinel "${HAVEN_WIRE_SENTINEL}"|--sentinel $TOKEN|' \
    "${e5}/e2e-android.yml"
  _expect "link 4: a token both halves name and nobody sets fails" \
    "${e5}" "${EX_PLAIN}" 1 "SET by neither"

  # --- E5b. The same hole with a binding PRESENT but EMPTY. `NAME: ""` is a
  #          binding grammatically and none at all in the sense this check
  #          exists for -- both halves still expand to empty. It is not a
  #          hypothetical shape: e2e-ios.yml carries `HAVEN_WIRE_SENTINEL: ""`
  #          on its deliberately-uninstrumented background-mirror step, so a
  #          lane whose mint step was deleted would still have looked bound.
  local e5b="${tmp}/e5b"; write_wired_lane "${e5b}"
  write_plain_lane "${e5b}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|      HAVEN_WIRE_SENTINEL: HAVEN_WIRE_SENTINEL:.*|      HAVEN_WIRE_SENTINEL: ""|' \
    "${e5b}/e2e-android.yml"
  _expect "link 4: an EMPTY binding does not count as bound" \
    "${e5b}" "${EX_PLAIN}" 1 "SET by neither"

  # --- E5c. The POPULATION hole. `candidates` and `wired` are both derived
  #          from lane text, so a lane that folds BOTH its relay start and its
  #          proxy start into one harness script leaves both sets at once,
  #          lands in neither `unwired` nor the equality pin, and exits every
  #          check here in silence. The one-call-deeper hop in the population
  #          derivation is what keeps it visible: the bringup script's own text
  #          still names start-local-relay.sh, so the lane stays a candidate
  #          and its lost wiring surfaces as an undeclared lane.
  local e5c="${tmp}/e5c"; write_wired_lane "${e5c}"
  write_plain_lane "${e5c}" 'e2e-integration.yml' 'e2e_integration'
  sed -i 's|bash tooling/e2e/ci/start-strfry.sh.*|bash tooling/e2e/ci/run-bringup.sh|; s|bash tooling/e2e/ci/start-wire-proxy.sh.*|bash tooling/e2e/ci/run-bringup.sh|' \
    "${e5c}/e2e-android.yml"
  local hbringup="${tmp}/harness-bringup"
  mkdir -p "${hbringup}/tooling/e2e/ci"
  cat > "${hbringup}/tooling/e2e/ci/run-bringup.sh" <<'SH'
#!/usr/bin/env bash
bash tooling/e2e/ci/start-strfry.sh
SH
  _expect "a lane that hides BOTH starts in a harness stays in the population" \
    "${e5c}" "${EX_PLAIN}" 1 "neither wire the recorder" "${hbringup}"

  # --- E6. Link 4, one call deeper. The Android/iOS lanes build inside their
  #         harness, so the workflow sets the env and the SCRIPT spells the
  #         define. That must PASS — demanding the define in the workflow would
  #         red the only shape a real lane can have.
  local e6="${tmp}/e6"; write_wired_lane "${e6}"
  write_plain_lane "${e6}" 'e2e-integration.yml' 'e2e_integration'
  sed -i '/--dart-define=HAVEN_WIRE_SENTINEL=/d' "${e6}/e2e-android.yml"
  local hforward="${tmp}/harness-forward"
  mkdir -p "${hforward}/tooling/e2e/ci"
  cat > "${hforward}/tooling/e2e/ci/run-single-avd-scenario.sh" <<'SH'
#!/usr/bin/env bash
flutter build apk --debug \
  --dart-define=HAVEN_WIRE_SENTINEL="${HAVEN_WIRE_SENTINEL}"
SH
  _expect "link 4: a define spelled in the harness the job invokes passes" \
    "${e6}" "${EX_PLAIN}" 0 "" "${hforward}"

  # ...and the trap that shape sets. `check-wire-journal.sh`'s header
  # DOCUMENTS the wiring with a literal `--dart-define=HAVEN_WIRE_SENTINEL=`
  # example, and every wired lane invokes that oracle — so a chain reader that
  # does not drop comments finds the define in every lane, forever, and link 4
  # becomes unfailable. The fixture is the comment WITHOUT the code.
  local hdoc="${tmp}/harness-doconly"
  mkdir -p "${hdoc}/tooling/e2e/ci"
  cat > "${hdoc}/tooling/e2e/ci/check-wire-journal.sh" <<'SH'
#!/usr/bin/env bash
# How a lane wires this in:
#   flutter drive --dart-define=HAVEN_WIRE_SENTINEL="${TOKEN}"
#   check-wire-journal.sh --journal … --sentinel "${TOKEN}"
exit 0
SH
  _expect "link 4: a define that exists only in a harness COMMENT does not count" \
    "${e6}" "${EX_PLAIN}" 1 "DRIVE is never given" "${hdoc}"

  # --- F. The floor that cannot be exempted: NOTHING is wired. Even with every
  #        lane declared, this must RED — it is the state Workstream C exists to
  #        end, and a guard that passed here would be the failure mode itself.
  local f="${tmp}/f"; mkdir -p "${f}"
  write_plain_lane "${f}" 'e2e-integration.yml' 'e2e_integration'
  write_plain_lane "${f}" 'e2e-android.yml' 'e2e_android'
  _expect "zero wired lanes fails LOUDLY even when all are declared" \
    "${f}" $'e2e-integration.yml:e2e_integration\ne2e-android.yml:e2e_android' \
    1 "NO lane wires the recording proxy"

  # --- G. The equality pin, both directions.
  local g="${tmp}/g"; write_wired_lane "${g}"
  write_plain_lane "${g}" 'e2e-integration.yml' 'e2e_integration'
  write_plain_lane "${g}" 'e2e-clock-skew.yml' 'e2e_clock_skew'
  _expect "an undeclared unwired lane fails, naming it" \
    "${g}" "${EX_PLAIN}" 1 "e2e-clock-skew.yml:e2e_clock_skew"

  _expect "a stale exemption (the lane is wired now) fails, naming it" \
    "${a}" $'e2e-integration.yml:e2e_integration\ne2e-android.yml:e2e_android' \
    1 "stale"

  # ...and the regression the equality pin is really for: a lane that LOSES its
  #    wiring. Same declared list as fixture A, which passed.
  local g2="${tmp}/g2"; write_wired_lane "${g2}"
  write_plain_lane "${g2}" 'e2e-integration.yml' 'e2e_integration'
  sed -i '/wire-proxy.sh/d;/check-wire-journal.sh/d' "${g2}/e2e-android.yml"
  _expect "a lane that silently loses its wiring fails against the same list" \
    "${g2}" "${EX_PLAIN}" 1 "e2e-android.yml:e2e_android"

  # --- H. Anti-vacuity (a): a start-wire-proxy.sh line the extractor cannot
  #        attribute to a job. The raw grep still sees it; the mismatch must be
  #        reported as BROKEN, not swallowed as "nothing to check".
  local h="${tmp}/h"; write_wired_lane "${h}"
  write_plain_lane "${h}" 'e2e-integration.yml' 'e2e_integration'
  cat > "${h}/e2e-orphan.yml" <<'YAML'
name: orphan
on:
  workflow_call:
# The proxy start reaches the file through a top-level anchor, outside `jobs:`,
# so the record parser never attributes it while the raw grep still finds it.
x-templates:
  recorder: bash tooling/e2e/ci/start-wire-proxy.sh
YAML
  _expect "vacuity: an unattributed start-wire-proxy.sh line is BROKEN" \
    "${h}" "${EX_PLAIN}" 2 "e2e-orphan.yml"

  # ...and the same rot where the file IS parsed. Above, the whole workflow is
  # invisible, so the SET check (b) would catch it on its own; here a real job
  # is attributed and only the proxy line escapes, which is the shape a job
  # header the parser stops matching actually produces. Only the COUNT check
  # (a) can see it. Mutation-tested: neutering (a) must red this fixture.
  local h1b="${tmp}/h1b"; write_wired_lane "${h1b}"
  write_plain_lane "${h1b}" 'e2e-integration.yml' 'e2e_integration'
  cat > "${h1b}/e2e-halfseen.yml" <<'YAML'
name: half seen
on:
  workflow_call:
x-templates:
  recorder: bash tooling/e2e/ci/start-wire-proxy.sh
jobs:
  lane:
    runs-on: ubuntu-latest
    env:
      HAVEN_E2E_RELAY: ws://10.0.2.2:7777
    steps:
      - name: Start strfry relay
        run: bash tooling/e2e/ci/start-strfry.sh
      - name: Drive
        run: bash tooling/e2e/ci/run-single-avd-scenario.sh x.dart
YAML
  _expect "vacuity: a proxy line the parser drops from a job it DOES see is BROKEN" \
    "${h1b}" $'e2e-integration.yml:e2e_integration\ne2e-halfseen.yml:lane' \
    2 "the raw files contain"

  # --- H2. Anti-vacuity (b): a relay-starting workflow the job parser cannot
  #         see at all. It would otherwise be invisible to the equality pin —
  #         neither demandable nor excusable.
  local h2="${tmp}/h2"; write_wired_lane "${h2}"
  write_plain_lane "${h2}" 'e2e-integration.yml' 'e2e_integration'
  cat > "${h2}/e2e-indirect.yml" <<'YAML'
name: indirect
on:
  workflow_call:
env:
  RELAY: bash tooling/e2e/ci/start-strfry.sh
jobs:
  lane:
    runs-on: ubuntu-latest
    steps:
      - name: Start relay
        run: ${RELAY}
YAML
  # The marker reaches the file through top-level `env:` indirection: the raw
  # grep sees the lane, the per-job attribution does not.
  _expect "vacuity: a relay lane with no attributed job is BROKEN, naming it" \
    "${h2}" "${EX_PLAIN}" 2 "e2e-indirect.yml"

  # --- H3. Anti-vacuity, the three ways the guard could find NOTHING to reason
  #         over. Each has to be its own BROKEN: "no lanes" and "all lanes
  #         compliant" produce the same exit code otherwise, which is the
  #         failure mode this whole guard was written for.
  local h3="${tmp}/h3"; mkdir -p "${h3}"
  cat > "${h3}/nojobs.yml" <<'YAML'
name: no jobs at all
on:
  workflow_call:
YAML
  _expect "vacuity: a workflow dir yielding no records is BROKEN" \
    "${h3}" "${EX_PLAIN}" 2 "no records at all"

  local h4="${tmp}/h4"; mkdir -p "${h4}"
  cat > "${h4}/build.yml" <<'YAML'
name: build only
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: flutter build apk --debug
YAML
  _expect "vacuity: a workflow dir with no relay lane at all is BROKEN" \
    "${h4}" "${EX_PLAIN}" 2 "starts a hermetic relay or the recorder"

  _expect "vacuity: a missing workflow directory is BROKEN" \
    "${tmp}/does-not-exist" "${EX_PLAIN}" 2 "not found"

  # --- I. False-positive direction, part 2. repo-guards.yml runs these very
  #        scripts hermetically with --self-test; those steps are not lanes and
  #        must neither be counted as wiring nor demanded as one.
  local i="${tmp}/i"; write_wired_lane "${i}"
  write_plain_lane "${i}" 'e2e-integration.yml' 'e2e_integration'
  cat > "${i}/repo-guards.yml" <<'YAML'
name: Repo Guards
on:
  workflow_call:
jobs:
  guards:
    runs-on: ubuntu-latest
    steps:
      - name: Wire oracle self-tests
        run: |
          bash tooling/e2e/ci/check-wire-journal.sh --self-test
          bash tooling/e2e/ci/check-wire-correlation.sh --self-test
          bash tooling/e2e/ci/start-strfry.sh --self-test
          bash tooling/e2e/ci/start-wire-proxy.sh --self-test
YAML
  _expect "a hermetic --self-test job is neither a wired lane nor a candidate" \
    "${i}" "${EX_PLAIN}" 0

  # ...and a COMMENTED-OUT marker must not be read as a lane either, or the
  #    guard reds on a repo whose only sin is documenting itself.
  local i2="${tmp}/i2"; write_wired_lane "${i2}"
  write_plain_lane "${i2}" 'e2e-integration.yml' 'e2e_integration'
  cat > "${i2}/e2e-doc.yml" <<'YAML'
name: doc
on:
  workflow_call:
jobs:
  documented:
    runs-on: ubuntu-latest
    steps:
      - name: Note
        # This lane would call bash tooling/e2e/ci/start-strfry.sh and
        # bash tooling/e2e/ci/start-wire-proxy.sh if it needed a relay.
        run: echo nothing
YAML
  _expect "a commented-out marker is not a lane" "${i2}" "${EX_PLAIN}" 0

  # --- J. Multi-job file: only the job that starts the proxy is link-checked,
  #        and its sibling must still be accounted for by the equality pin.
  local j="${tmp}/j"; mkdir -p "${j}"
  write_wired_lane "${j}"
  cat > "${j}/e2e-profile.yml" <<'YAML'
name: E2E Profile
on:
  workflow_call:
jobs:
  e2e_profile_android:
    runs-on: ubuntu-latest
    env:
      HAVEN_E2E_RELAY: ws://10.0.2.2:7777
    steps:
      - name: Start strfry relay
        run: bash tooling/e2e/ci/start-strfry.sh
  e2e_profile_ios:
    runs-on: macos-latest
    env:
      HAVEN_E2E_RELAY: ws://localhost:7777
    steps:
      - name: Start host-native relay
        run: bash tooling/e2e/ci/start-local-relay.sh 7777
YAML
  _expect "both jobs of a two-job lane are accounted for separately" \
    "${j}" $'e2e-profile.yml:e2e_profile_android\ne2e-profile.yml:e2e_profile_ios' 0
  _expect "declaring only one job of a two-job lane fails, naming the other" \
    "${j}" 'e2e-profile.yml:e2e_profile_android' 1 "e2e-profile.yml:e2e_profile_ios"

  if (( failures )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  echo "self-test: OK"
  return 0
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

  local wf="${REPO_ROOT}/.github/workflows"
  [[ -d "${wf}" ]] || { echo "ERROR: ${wf} not found" >&2; exit 2; }
  for required in \
      'tooling/e2e/ci/start-wire-proxy.sh' \
      'tooling/e2e/ci/stop-wire-proxy.sh' \
      'tooling/e2e/ci/check-wire-journal.sh'; do
    [[ -f "${REPO_ROOT}/${required}" ]] || {
      echo "ERROR: ${required} not found — the chain this guard checks does not exist" >&2
      exit 2
    }
  done

  log "checking wire-oracle lane reachability in ${wf#"${REPO_ROOT}"/}"
  local exempt=""
  local entry
  for entry in "${KNOWN_UNWIRED_LANES[@]}"; do exempt+="${entry}"$'\n'; done
  check_dir "${wf}" "${exempt}"

  if (( BROKEN > 0 )); then
    echo >&2
    echo "This guard could not see the repository the way it expects to. That is" >&2
    echo "not a clean bill of health: an extractor that stops matching reports" >&2
    echo "every lane as compliant. See the header of ${SELF_NAME}." >&2
    exit 2
  fi
  if (( VIOLATIONS > 0 )); then
    echo >&2
    echo "The wire oracles assert nothing unless a lane starts the recorder, points" >&2
    echo "the app at it, stops it, and runs an oracle over the journal under the" >&2
    echo "SAME sentinel the drive emitted. See docs/WIRE_JOURNAL.md and" >&2
    echo "docs/CI_HARDENING_BACKLOG.md (Workstream C)." >&2
    exit 1
  fi
  log "OK — the wire-oracle chain is reached by a lane."
}

main "$@"
