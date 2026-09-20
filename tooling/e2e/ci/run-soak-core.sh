#!/usr/bin/env bash
#
# E2E harness: drive ONE soak profile of the Tier-1 rig (tooling/soak) and gate
# everything it captured before the lane uploads any of it.
#
# LINUX ONLY. Unlike every other runner here this one is never sourced on a
# macOS runner: the soak lane is `ubuntu-latest` in all three profiles, there is
# no simulator half, and nothing in tooling/soak is built for Darwin in CI. It
# therefore uses bash 4 features (`mapfile`, `find -printf`) that
# logscan-gate.sh — which the iOS lanes DO source on macOS — deliberately
# avoids. If a soak profile ever runs on macOS, this file has to be re-read for
# bash 3.2 compatibility first.
#
# ## What it does, and why the order matters
#
#   1. Creates the uploadable evidence tree, `${RUNNER_TEMP}/soak-upload/`.
#      The rig's needles and per-scenario evidence live under /tmp/haven-soak,
#      which is WHOLLY upload-banned (check_wire_proxy_test_only.sh checks 3
#      and 6), so the two trees are separate by construction rather than by
#      care.
#   2. Runs the rig with BOTH streams redirected into that tree. An
#      unredirected soak binary writes into the job log, which cannot be
#      retracted; the redirected file is then scanned like any other capture.
#   3. Scans the tree TWICE, before anything uploads it:
#        * against the manifest the RIG sealed from its own declarations
#          (`--needle-manifest`, CI only) — the only thing that can search for
#          a value this run actually minted; and
#        * through `logscan_gate`, whose `host` seal adds the harness's fixed
#          host needles and the lane's endpoint exemptions.
#      Neither subsumes the other: the rig cannot declare a host needle, and
#      the gate cannot declare a value minted inside the rig. They are two
#      manifests on purpose — `logscan_seal` REUSES whatever sits at its own
#      run-id path, so a rig manifest written there would replace the host
#      needles instead of adding to them.
#   4. On a LEAK (rc 1) the wrapper has already deleted the sinks it named;
#      this runner removes what is left of the tree and leaves one
#      harness-authored line in its place, so the lane's upload publishes the
#      FACT of containment rather than the evidence. A VIOLATION is the
#      opposite case — the snapshot is the whole point — and is kept.
#
# Steps 3 and 4 are `soak_finalize`, and it is reached three ways, because the
# lane reaps with `timeout` — which signals the whole PROCESS GROUP, so an
# overrunning run dies between step 2 and step 3 while the upload step fires
# regardless: at the end of a healthy run, from this file's TERM/INT/EXIT traps
# inside the kill grace, and once more from the lane's own step
# (`--scan-only`), which is the only one of the three a SIGKILL cannot skip.
# The scan is idempotent: the second pass over a clean tree re-reads it, and
# over a contained one reports the leak that emptied it without re-reading the
# harness's note. Once entered it runs to completion — it ignores the signal it
# exists to survive, so the reap cannot land between the floor scanner deleting
# what it flagged and the tree being contained.
#
# ## The contract with the rig (tooling/soak)
#
# The lane passes `--timeline-out <tree>/soak-timeline.log`, and the rig writes
# its banner, its markers and any first-violation snapshot into THAT directory:
# it is the one path the rig is told about and the one the lane uploads.
# `LEAK.marker` and `VIOLATION.marker` are the two rc-1 evidence contracts
# (docs/SOAK_LANE.md); this runner reads their PRESENCE and never their
# contents.
#
# Usage:
#   run-soak-core.sh <pr|nightly|weekly>
#   run-soak-core.sh --scan-only <pr|nightly|weekly>   # the scan alone, no rig
#   run-soak-core.sh --self-test        # hermetic: no cargo, no network
#
# Exit codes (haven-logscan's closed set, folded 1 > 2 > 3 > 4 > 0):
#   0  clean   1  leak or invariant violation   2  the rig or a guard is broken
#   3  the run proves nothing                   4  it proves too little

set -euo pipefail

SOAK_CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SOAK_CI_DIR
SOAK_REPO_ROOT="$(cd "${SOAK_CI_DIR}/../../.." && pwd)"
readonly SOAK_REPO_ROOT

# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SOAK_CI_DIR}/logscan-gate.sh"

# A constant, never an argument and never an env override — the reason
# check_wire_proxy_test_only.sh records: every ban on this directory is only as
# good as the path being fixed.
readonly SOAK_NEEDLE_DIR=/tmp/haven-soak/needles
readonly SOAK_MANIFEST_SUFFIX='-soak.needles.json'
readonly SOAK_CONTAINED_LOG='soak-contained.log'

soak_log() { printf '\033[1;34m[soak]\033[0m %s\n' "$*"; }
soak_err() { printf '\033[1;31m[soak] ERROR:\033[0m %s\n' "$*" >&2; }

# The uploadable tree: `${RUNNER_TEMP}` on a runner, a temp dir locally.
soak_upload_dir() { printf '%s\n' "${SOAK_UPLOAD_DIR:-${RUNNER_TEMP:-/tmp}/soak-upload}"; }
# Scan reports are NDJSON, which no upload step may name
# (check_wire_proxy_test_only.sh invariant 3), so they live outside the tree.
soak_report_dir() { printf '%s\n' "${SOAK_REPORT_DIR:-${RUNNER_TEMP:-/tmp}/soak-reports}"; }

soak_run_id() { printf '%s\n' "${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-local}"; }

# Every *.log the rig left, comma-joined for one `--sink`. Printed, never read.
soak_sink_spec() { # soak_sink_spec <dir>
  local dir="$1" spec="" f
  local -a files=()
  mapfile -t files < <(find "${dir}" -maxdepth 1 -type f -name '*.log' | sort)
  (( ${#files[@]} > 0 )) || return 1
  for f in "${files[@]}"; do spec="${spec:+${spec},}${f}"; done
  printf '%s\n' "${spec}"
}

# Containment. The wrapper deleted the sinks it named; remove what is left and
# say so in one harness-authored line with nothing interpolated into it, so the
# lane's `if-no-files-found: error` upload still has a file and that file is
# safe by construction rather than by having been scanned.
soak_contain() { # soak_contain <dir>
  local dir="$1"
  find "${dir}" -mindepth 1 -delete 2>/dev/null || true
  mkdir -p "${dir}"
  printf '%s\n' \
    'haven-soak: the log-privacy scan reported a LEAK and every capture was' \
    'deleted on the runner before this upload. The class, encoding and' \
    'sink:line of each finding are in the job log; no value is recorded' \
    'anywhere, here or there.' > "${dir}/${SOAK_CONTAINED_LOG}"
}

soak_usage() {
  echo "usage: $(basename "${BASH_SOURCE[0]}") <pr|nightly|weekly> | --scan-only <pr|nightly|weekly> | --self-test" >&2
  exit 2
}

soak_profile_ok() { # soak_profile_ok <profile>
  case "${1:-}" in
    pr|nightly|weekly) return 0 ;;
    *) soak_err "unknown soak profile '${1:-}' (pr|nightly|weekly)"; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# The scan, and the three ways it is reached.
#
# The lane reaps with `timeout`, which signals the whole PROCESS GROUP: an
# overrunning run therefore dies HERE, between the rig and its scan, with a
# tree full of captures and an upload step that fires on every outcome short of
# a cancellation. So the scan is a function, not a tail — run at the end of a
# healthy run, from the TERM/INT/EXIT traps when the reaper gets there first,
# and once more by the lane's own step (`--scan-only`) after the drive, because
# a SIGKILL after the grace leaves no trap to run at all.
# ---------------------------------------------------------------------------

# The verdict of the one pass that read the tree; empty until that pass has
# one. `soak_on_exit` asks again in a process that already scanned, and the
# answer to that second call is what the first pass FOUND, never a bare 0.
SOAK_VERDICT=''
# What the traps pass to the scan; set with them, never before.
SOAK_PROFILE=''

soak_finalize() { # soak_finalize <profile>
  local profile="${1:-}"
  [[ -z "${SOAK_VERDICT}" ]] || return "${SOAK_VERDICT}"

  # A containment path is not interruptible by the signal it exists to survive.
  # The lane's deadline signals the whole group, so it lands inside this scan
  # as readily as before it, and a handler that re-entered here mid-pass would
  # leave the tree emptied by the floor scanner and never contained. Ignored,
  # not trapped: an ignored signal is discarded rather than deferred, so
  # nothing fires the moment this returns either. They stay ignored afterwards
  # — everything past this point is one fold and one exit, and the reaper's
  # signal has already been answered by the scan it asked for. SIGKILL after
  # the kill grace is what remains, and the lane's own `--scan-only` step,
  # which runs on every outcome, is the backstop for that.
  trap '' TERM INT HUP

  local upload reports manifest spec
  upload="$(soak_upload_dir)"
  reports="$(soak_report_dir)"
  manifest="${SOAK_NEEDLE_DIR}/$(soak_run_id)${SOAK_MANIFEST_SUFFIX}"
  mkdir -p "${reports}"

  # No tree at all. The drive creates it before the rig's first byte, so this
  # is the lane's own scan step running after a drive that never started — a
  # build step failed above it. Nothing was captured and nothing will be
  # uploaded; a verdict here would be a second red on top of the real one. An
  # EMPTY tree is the opposite case and stays rc 3 below: something ran and
  # recorded nothing.
  if [[ ! -d "${upload}" ]]; then
    soak_log "no evidence tree: nothing ran here, so there is nothing to read and nothing to publish."
    SOAK_VERDICT=0
    return 0
  fi

  # Contained already, by this run's drive or by its trap: what is left is the
  # harness's own note, and re-reading that would report a floor verdict over a
  # file the harness wrote. The leak verdict stands, unchanged.
  if [[ -f "${upload}/${SOAK_CONTAINED_LOG}" ]]; then
    soak_err "the evidence tree was contained by an earlier scan of this run; there is nothing left here to read."
    SOAK_VERDICT=1
    return 1
  fi

  spec="$(soak_sink_spec "${upload}")" || {
    soak_err "the rig left no *.log in its evidence tree; a run that recorded nothing cannot be proven clean."
    SOAK_VERDICT=3
    return 3
  }

  # The rig's own declarations first: the values this run minted are the ones
  # only it could declare, and they are what a leak would be.
  local needle_rc=0
  local scan_logs="${SCAN_LOGS:-${SOAK_CI_DIR}/scan-logs.sh}"
  if [[ "${HAVEN_LOGSCAN:-}" == "true" && -f "${manifest}" ]]; then
    bash "${scan_logs}" \
      --manifest "${manifest}" --sink "soak=${spec}" \
      --report "${reports}/soak-${profile}-rig.ndjson" || needle_rc=$?
  fi

  # ...then the harness's own host needles and endpoint exemptions, which the
  # rig has no way to declare.
  local gate_rc=0
  logscan_gate host "${SOAK_NEEDLE_DIR}" -- \
    --sink "soak=${spec}" --report "${reports}/soak-${profile}-host.ndjson" || gate_rc=$?

  # The rig re-seals its manifest as each world is built and again as each arm
  # finishes, so this branch is the one case that leaves none at all: a run
  # reaped before its FIRST world, which minted nothing to search for. The
  # captures it did leave were read by the structural rules and the host
  # needles alone. That is rc 4 exactly: intact, kept (nothing here is a proven
  # leak) and UNGRADED. Folded, so a leak still outranks it and a broken or
  # unusable run still reads as itself.
  local meta_rc=0
  if [[ "${HAVEN_LOGSCAN:-}" == "true" && ! -f "${manifest}" ]]; then
    soak_err "the rig sealed no manifest of its own declarations, so nothing searched these captures for a value THIS run minted; the structural rules and the host needles are all that read them."
    meta_rc=4
  fi

  local scan_rc=0
  worst_rc "${needle_rc}" "${gate_rc}" || scan_rc=$?
  worst_rc "${scan_rc}" "${meta_rc}" || scan_rc=$?

  if (( scan_rc == 1 )) || [[ -f "${upload}/LEAK.marker" ]]; then
    soak_contain "${upload}"
    soak_err "a capture carried a declared identifier; the evidence tree was removed on the runner."
  fi
  soak_log "scan ${scan_rc} (rig manifest ${needle_rc}, host gate ${gate_rc}, declaration floor ${meta_rc})"
  SOAK_VERDICT="${scan_rc}"
  return "${scan_rc}"
}

# The reaper arrived. A reaped run proves nothing (rc 3); a leak found while
# containing it still outranks that.
soak_on_signal() {
  trap - TERM INT EXIT
  soak_err "reaped before the scan; reading the evidence tree now, inside the kill grace."
  local scan_rc=0 rc=3
  soak_finalize "${SOAK_PROFILE}" || scan_rc=$?
  worst_rc 3 "${scan_rc}" || rc=$?
  exit "${rc}"
}

# Every other way out — `set -e`, a `return` this file does not expect, a plain
# end — with the same rule: nothing leaves this process with a capture no scan
# has read, and a leak found on the way out outranks the status that got here.
soak_on_exit() {
  local rc=$?
  local scan_rc=0 out=0
  trap - TERM INT EXIT
  soak_finalize "${SOAK_PROFILE}" || scan_rc=$?
  # FOLDED, never substituted. The scan the drive already ran is part of what
  # got us here, and the guard now answers with that verdict rather than 0 —
  # so overriding `rc` with it would quietly demote a rig-reported leak to the
  # scan's own milder code. Folding keeps whichever of the two is worse.
  worst_rc "${rc}" "${scan_rc}" || out=$?
  exit "${out}"
}

# The lane's own step, after the drive and before the upload, on every outcome
# short of a cancellation: the drive's own scan covers a healthy run, and this
# covers the run the reaper killed — including the one killed hard enough that
# no trap ran.
soak_scan_only() { # soak_scan_only <profile>
  soak_profile_ok "$1" || return $?
  soak_finalize "$1"
}

# ---------------------------------------------------------------------------

soak_main() { # soak_main <profile>
  local profile="${1:-}"
  soak_profile_ok "${profile}" || return $?

  local upload manifest stdout_log
  upload="$(soak_upload_dir)"
  manifest="${SOAK_NEEDLE_DIR}/$(soak_run_id)${SOAK_MANIFEST_SUFFIX}"
  stdout_log="${upload}/soak-${profile}-run.log"

  # Armed before the tree itself exists, because from the mkdir on every way
  # out of this process has a tree to answer for.
  SOAK_PROFILE="${profile}"
  trap soak_on_signal TERM INT
  trap soak_on_exit EXIT
  mkdir -p "${upload}"

  local -a rig_args=(
    --profile "${profile}"
    --timeline-out "${upload}/soak-timeline.log"
  )
  # CI only (owner decision Q5): the scan below is the manifest's reader and
  # the job's always() discard is what removes it. A local run seals in memory
  # and writes nothing.
  if [[ "${HAVEN_LOGSCAN:-}" == "true" ]]; then
    mkdir -m 0700 -p "${SOAK_NEEDLE_DIR}"
    rig_args+=(--needle-manifest "${manifest}")
  fi

  local rig_rc=0
  ( cd "${SOAK_REPO_ROOT}/tooling/soak" \
      && cargo run --profile soak --bin haven-soak -- "${rig_args[@]}" ) \
    > "${stdout_log}" 2>&1 || rig_rc=$?
  soak_log "rig exited ${rig_rc}"

  local scan_rc=0
  soak_finalize "${profile}" || scan_rc=$?

  local rc=0
  worst_rc "${rig_rc}" "${scan_rc}" || rc=$?
  soak_log "verdict ${rc} (rig ${rig_rc}, scan ${scan_rc})"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# --self-test: hermetic. No cargo, no relay, no network. It exercises the
# helpers and PINS the wiring properties a real run cannot re-check.
# ---------------------------------------------------------------------------
soak_self_test() {
  local tmp fails=0 cases=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <got-rc>
    cases=$(( cases + 1 ))
    if [[ "$2" == "$3" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%s, got rc=%s)\n' "$1" "$2" "$3" >&2
      fails=1
    fi
  }
  _eq() { # _eq <label> <want> <got>
    cases=$(( cases + 1 ))
    if [[ "$2" == "$3" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3" >&2
      fails=1
    fi
  }

  echo "run-soak-core.sh --self-test"
  local rc

  # (1) The sink spec is every *.log in the tree, sorted, comma-joined.
  local d="${tmp}/tree"; mkdir -p "${d}"
  : > "${d}/b.log"; : > "${d}/a.log"; : > "${d}/notes.ndjson"
  _eq "the sink spec names every .log and nothing else" \
    "${d}/a.log,${d}/b.log" "$(soak_sink_spec "${d}")"

  # (2) An empty tree is refused. A run that captured nothing cannot be proven
  #     clean, and must never read as a clean scan.
  local empty="${tmp}/empty"; mkdir -p "${empty}"
  rc=0; soak_sink_spec "${empty}" >/dev/null || rc=$?
  _case "a tree with no capture is refused, not scanned" 1 "${rc}"

  # (3) Containment removes every capture and leaves exactly one file.
  local c="${tmp}/contain"; mkdir -p "${c}/sub"
  : > "${c}/evidence.log"; : > "${c}/sub/nested.log"; : > "${c}/soak-timeline.log"
  soak_contain "${c}"
  _eq "containment leaves exactly the one harness-authored file" \
    "${SOAK_CONTAINED_LOG}" \
    "$(find "${c}" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"

  # (4) ...and that file interpolates nothing: a containment note carrying a
  #     path or a finding would publish what containment just deleted.
  rc=0
  if grep -qE '[$]|\{\{' "${c}/${SOAK_CONTAINED_LOG}"; then rc=1; fi
  _case "the containment note carries no interpolated text" 0 "${rc}"

  # (5) The needle directory is the FIXED constant, spelled here: every ban on
  #     it is keyed on the path not moving.
  rc=0
  if ! grep -qE '^readonly SOAK_NEEDLE_DIR=/tmp/haven-soak/needles$' "${BASH_SOURCE[0]}"; then rc=1; fi
  _case "the needle directory is a spelled constant" 0 "${rc}"

  # (6) THE WIRING PIN (check_logscan_wired_everywhere.sh RUNNER_PINS). The
  #     gate is what stands between a captured log and the job log, so its
  #     position is read from this file's own lines rather than trusted. This
  #     runner echoes NO captured log at all — the strongest form of the
  #     property the other runners pin by ordering — so the fixture asserts
  #     both halves: the gate call is at a command position, and no reading
  #     command names a capture anywhere in the file.
  local joined gate_at read_at
  joined="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "${BASH_SOURCE[0]}" | grep -vE '^[[:space:]]*#')"
  gate_at="$(grep -nE '^[[:space:]]*logscan_gate host "\$\{SOAK_NEEDLE_DIR\}"' <<<"${joined}" \
              | cut -d: -f1 | head -n 1 || true)"
  read_at="$(grep -nE '(^|[;&|[:space:]])(cat|tee|head|tail|less|more)[[:space:]]+[^|]*[.]log' <<<"${joined}" \
              | cut -d: -f1 | head -n 1 || true)"
  rc=0
  if [[ -z "${gate_at}" || -n "${read_at}" ]]; then rc=1; fi
  _case "the log-privacy gate runs and no captured log is ever echoed" 0 "${rc}"

  # (7) The rig's manifest never takes the gate's own run-id path (logscan_seal
  #     reuses a manifest already there, so the two would silently become one
  #     and the host needles would vanish from the seal) — and it still ends in
  #     the suffix scan-logs.sh requires.
  rc=0
  if [[ "${SOAK_MANIFEST_SUFFIX}" == '.needles.json' \
        || "${SOAK_MANIFEST_SUFFIX}" != *'.needles.json' ]]; then rc=1; fi
  _case "the rig manifest is distinct from the gate's and still a .needles.json" 0 "${rc}"

  # (8) A profile this runner does not know is rc 2, never a default.
  rc=0; ( soak_main 'weekley' ) >/dev/null 2>&1 || rc=$?
  _case "an unknown profile is a broken runner, not a default" 2 "${rc}"

  # (9) The uploadable tree is never under the banned soak root.
  local tree
  tree="$(SOAK_UPLOAD_DIR='' RUNNER_TEMP=/run/t soak_upload_dir)"
  rc=0
  if [[ "${tree}" == /tmp/haven-soak* ]]; then rc=1; fi
  _case "the uploadable tree is outside /tmp/haven-soak" 0 "${rc}"

  # (10) THE KILL PATH. The lane's deadline signals the whole process group, so
  #      a run that overruns dies between the rig and the scan — and the upload
  #      step fires anyway. Driven for real, with no clock in the fixture: a
  #      fake `cargo` on PATH signals its OWN group, which is exactly what
  #      `timeout` does, at the one instant the rig owns the foreground; `set
  #      -m` gives the job a group of its own so nothing else is in it. The
  #      capture holds key material, so a trap that ran must have CONTAINED.
  local reaped="${tmp}/reaped" reapedbin="${tmp}/reaped-bin" reapedpid
  mkdir -p "${reaped}" "${reapedbin}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "a fake rig, for the trap fixture\n"' \
    'kill -TERM 0' \
    'sleep 60' > "${reapedbin}/cargo"
  chmod +x "${reapedbin}/cargo"
  printf 'D/keyring ( 111): Entry { secret: Some([1, 2, 3]) }\n' > "${reaped}/planted.log"
  set -m
  PATH="${reapedbin}:${PATH}" HAVEN_LOGSCAN='' \
    SOAK_UPLOAD_DIR="${reaped}" SOAK_REPORT_DIR="${tmp}/reaped-reports" \
    bash "${BASH_SOURCE[0]}" pr >/dev/null 2>&1 &
  reapedpid=$!
  set +m
  rc=0; wait "${reapedpid}" || rc=$?
  _eq "a reaped run still scans, and contains what it read" \
    "${SOAK_CONTAINED_LOG}" \
    "$(find "${reaped}" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  _case "...and reports the leak, not the reaping" 1 "${rc}"

  # (11) The belt to that brace. Bash runs an EXIT trap before re-raising a
  #      fatal signal it has no trap for, so the tree is read on the way out of
  #      a death this runner never names — and on every `set -e` abort between
  #      the rig and the scan, which is the same path. The verdict stays the
  #      signal's (128+1): what the trap owes here is the containment.
  local hangup="${tmp}/hangup" hangupbin="${tmp}/hangup-bin"
  mkdir -p "${hangup}" "${hangupbin}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "a fake rig, for the exit-trap fixture\n"' \
    'kill -HUP 0' \
    'sleep 60' > "${hangupbin}/cargo"
  chmod +x "${hangupbin}/cargo"
  printf 'D/keyring ( 111): Entry { secret: Some([1, 2, 3]) }\n' > "${hangup}/planted.log"
  rc=0
  # The job notification for a signalled job goes to the shell's stderr; the
  # subshell keeps the fixture's own output readable.
  ( set -m
    PATH="${hangupbin}:${PATH}" HAVEN_LOGSCAN='' \
      SOAK_UPLOAD_DIR="${hangup}" SOAK_REPORT_DIR="${tmp}/hangup-reports" \
      bash "${BASH_SOURCE[0]}" pr >/dev/null 2>&1 &
    set +m
    wait $! ) 2>/dev/null || rc=$?
  _eq "a signal this runner traps nowhere still leaves the tree read and contained" \
    "${SOAK_CONTAINED_LOG}" \
    "$(find "${hangup}" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  _case "...and dies of the signal it was sent" 129 "${rc}"

  # (12) --scan-only is the lane's own step, between the drive and the upload.
  #      It reads the tree and never launches the rig: the fake `cargo` here
  #      would plant key material if it ran, so a clean verdict over an
  #      untouched tree is what proves it did not.
  local scanonly="${tmp}/scan-only" scanonlybin="${tmp}/scan-only-bin"
  mkdir -p "${scanonly}" "${scanonlybin}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "D/keyring ( 111): Entry { secret: Some([1, 2, 3]) }\n"' > "${scanonlybin}/cargo"
  chmod +x "${scanonlybin}/cargo"
  printf 'the rig said nothing identifying\n' > "${scanonly}/soak-pr-run.log"
  rc=0
  PATH="${scanonlybin}:${PATH}" HAVEN_LOGSCAN='' \
    SOAK_UPLOAD_DIR="${scanonly}" SOAK_REPORT_DIR="${tmp}/scan-only-reports" \
    bash "${BASH_SOURCE[0]}" --scan-only pr >/dev/null 2>&1 || rc=$?
  _case "--scan-only reads the tree and never launches the rig" 0 "${rc}"
  _eq "...and leaves a clean capture where the upload expects it" \
    'soak-pr-run.log' \
    "$(find "${scanonly}" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"

  # (13) The lane runs that step on every outcome, so it re-enters a tree the
  #      drive already contained. The leak verdict stands, and the harness's
  #      own note is never re-read as if it were evidence.
  local contained="${tmp}/already-contained"; mkdir -p "${contained}"
  soak_contain "${contained}"
  rc=0
  HAVEN_LOGSCAN='' SOAK_UPLOAD_DIR="${contained}" SOAK_REPORT_DIR="${tmp}/ac-reports" \
    bash "${BASH_SOURCE[0]}" --scan-only pr >/dev/null 2>&1 || rc=$?
  _case "a tree already contained keeps the leak verdict" 1 "${rc}"

  # (14) The lane runs the scan step even when a build step failed above the
  #      drive, so there is no tree at all. That is not a leak, not an unusable
  #      run, and not this step's red to report: it would be a second one on top
  #      of the compile failure. An EMPTY tree stays rc 3 — fixture (2).
  rc=0
  HAVEN_LOGSCAN='' SOAK_UPLOAD_DIR="${tmp}/never-created" SOAK_REPORT_DIR="${tmp}/nc-reports" \
    bash "${BASH_SOURCE[0]}" --scan-only pr >/dev/null 2>&1 || rc=$?
  _case "a tree the drive never created is not a second red" 0 "${rc}"

  # (15) A reaped run's captures are scanned by the structural rules and the
  #      host needles, but the rig seals its own manifest only at the END of a
  #      run — so nothing searched them for a value THIS run minted, and the
  #      verdict must say so (rc 4, ungraded) rather than read as clean. The
  #      gate runs against injected fakes here, as scan-logs.sh's own self-test
  #      does. The other direction — a manifest PRESENT is not downgraded — is
  #      fixture (12) inverted: the needle directory is a fixed constant no
  #      hermetic fixture may write into, so the arm tested here is the flag's.
  local ungraded="${tmp}/ungraded" fakebin="${tmp}/fake-logscan" fakewrap="${tmp}/fake-scan-logs"
  mkdir -p "${ungraded}"
  printf 'the rig said nothing identifying\n' > "${ungraded}/soak-pr-run.log"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${fakebin}"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${fakewrap}"
  chmod +x "${fakebin}" "${fakewrap}"
  rc=0
  HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fakebin}" SCAN_LOGS="${fakewrap}" \
    SOAK_UPLOAD_DIR="${ungraded}" SOAK_REPORT_DIR="${tmp}/ungraded-reports" \
    bash "${BASH_SOURCE[0]}" --scan-only pr >/dev/null 2>&1 || rc=$?
  _case "captures no rig manifest ever searched are UNGRADED, not clean" 4 "${rc}"

  # (16) ...and the new entry point validates its profile like the old one.
  rc=0
  bash "${BASH_SOURCE[0]}" --scan-only weekley >/dev/null 2>&1 || rc=$?
  _case "--scan-only with an unknown profile is a broken runner, not a default" 2 "${rc}"

  # (17) THE SIGNAL THAT LANDS INSIDE THE SCAN. Fixture (10) reaps BEFORE the
  #      scan; a process group is signalled all at once, so the same deadline
  #      lands just as readily in the middle of it — after the floor scanner
  #      has deleted what it flagged and before the tree is contained. A
  #      handler that re-entered `soak_finalize` there would answer for a
  #      verdict that did not exist yet and leave an emptied, uncontained tree
  #      behind it. Driven for real and with no clock in the fixture: the
  #      stubbed floor signals the group at the one instant finalize owns the
  #      foreground, ignoring the signal itself so its own LEAK verdict
  #      survives to be read, and appends a line per call so "the tree was read
  #      exactly once" is counted rather than assumed.
  local mid="${tmp}/mid-scan" midbin="${tmp}/mid-bin" midcalls="${tmp}/mid-calls" midpid
  mkdir -p "${mid}" "${midbin}"
  : > "${midcalls}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "a fake rig, for the mid-scan fixture\n"' > "${midbin}/cargo"
  printf '%s\n' '#!/usr/bin/env bash' \
    'trap "" TERM' \
    'printf "read\n" >> "${SOAK_MID_CALLS}"' \
    'kill -TERM 0' \
    'exit 1' > "${midbin}/floor"
  chmod +x "${midbin}/cargo" "${midbin}/floor"
  printf 'D/keyring ( 111): Entry { secret: Some([1, 2, 3]) }\n' > "${mid}/planted.log"
  set -m
  PATH="${midbin}:${PATH}" HAVEN_LOGSCAN='' SECRET_SCAN="${midbin}/floor" \
    SOAK_MID_CALLS="${midcalls}" \
    SOAK_UPLOAD_DIR="${mid}" SOAK_REPORT_DIR="${tmp}/mid-reports" \
    bash "${BASH_SOURCE[0]}" pr >/dev/null 2>&1 &
  midpid=$!
  set +m
  rc=0; wait "${midpid}" || rc=$?
  _eq "a signal landing inside the scan still leaves the tree contained" \
    "${SOAK_CONTAINED_LOG}" \
    "$(find "${mid}" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  _case "...and the verdict is the leak, not the interruption" 1 "${rc}"
  _eq "...and the tree was read exactly once" 1 "$(wc -l < "${midcalls}" | tr -d ' ')"

  # (18) ...and the verdict a trap carries out of here is the one computed
  #      here. Bash before 5.3 resolves a bare `return` inside a trap handler
  #      to the status of the last command run BEFORE the handler, which on
  #      this path is the reaped rig — so one anywhere a handler can reach
  #      reports the reaping in place of the scan (run 35478132251, through
  #      logscan-gate.sh's flag-off arm). The bash that has the bug is not the
  #      bash that runs this, so the guard is static: every `return` outside
  #      this self-test names its status.
  #      Materialised first: under pipefail a `grep -q` that matches exits
  #      early, SIGPIPEs the stage above it, and the hit then reads as a miss.
  local runner_half
  runner_half="$(sed -n '1,/^soak_self_test()/p' "${BASH_SOURCE[0]}" | grep -vE '^[[:space:]]*#')"
  rc=0
  if grep -qE '^[[:space:]]*return[[:space:]]*$' <<<"${runner_half}"; then rc=1; fi
  _case "no bare \`return\` on a path a trap handler can reach" 0 "${rc}"

  # (18b) The traps are armed before the evidence tree exists, so no way out
  #       of `soak_main` leaves a tree that nothing answers for.
  local armed_at tree_at
  armed_at="$(grep -nE '^  trap soak_on_exit EXIT$' <<<"${runner_half}" | head -n 1 | cut -d: -f1)"
  tree_at="$(grep -nE '^  mkdir -p "\$\{upload\}"$' <<<"${runner_half}" | head -n 1 | cut -d: -f1)"
  rc=0
  [[ -n "${armed_at}" && -n "${tree_at}" ]] && (( armed_at < tree_at )) || rc=1
  _case "the traps are armed before the evidence tree is created" 0 "${rc}"

  # (19) THE FOLD, not a substitution. `soak_on_exit` arrives with the status
  #      that got here and then asks the scan for its verdict, and the two are
  #      different codes: a rig that PROVED a violation (1) under a scan that
  #      could only say "ungraded" (4) has to leave as the 1. The guard answers
  #      with what the first pass found rather than 0, so substituting it —
  #      which is what this line did before — publishes "proves too little"
  #      over the violation the rig had already proven.
  local folded="${tmp}/folded" foldbin="${tmp}/fold-bin"
  mkdir -p "${folded}" "${foldbin}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "a fake rig that found a violation\n"' \
    'exit 1' > "${foldbin}/cargo"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 4' > "${foldbin}/floor"
  chmod +x "${foldbin}/cargo" "${foldbin}/floor"
  rc=0
  PATH="${foldbin}:${PATH}" HAVEN_LOGSCAN='' SECRET_SCAN="${foldbin}/floor" \
    SOAK_UPLOAD_DIR="${folded}" SOAK_REPORT_DIR="${tmp}/folded-reports" \
    bash "${BASH_SOURCE[0]}" pr >/dev/null 2>&1 || rc=$?
  _case "a violation the rig proved is not demoted to the scan's milder code" 1 "${rc}"

  if (( fails )); then
    soak_err "self-test FAILED"
    return 1
  fi
  soak_log "self-test OK (${cases} cases)"
  return 0
}

case "${1:-}" in
  --self-test)
    (( $# == 1 )) || soak_usage
    soak_self_test
    exit $?
    ;;
  --scan-only)
    (( $# == 2 )) || soak_usage
    soak_scan_only "$2" || exit $?
    exit 0
    ;;
esac
(( $# == 1 )) || soak_usage
soak_main "$1"
