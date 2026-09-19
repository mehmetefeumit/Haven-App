#!/usr/bin/env bash
# Local runner for the Tier-1 soak rig (tooling/soak).
#
# The lane is `soak-core.yml`; this is the same rig, driven by hand, for the one
# thing CI cannot do — running the SAME seed several times to decide whether a
# failure is real or a race the rig itself introduced. A soak that reproduces
# 3/3 at a seed is a defect; one that reproduces 1/3 is a flake in the harness,
# and the harness is not allowed to have any (CLAUDE.md, test reliability).
#
# Subcommands:
#   core        Run one soak profile. The only subcommand this phase has; the
#               nightly/weekly SCHEDULERS are Phase 2, but their profiles run
#               here today, which is the only way S17/S18/S19 execute at all
#               outside `cargo test` (docs/SOAK_LANE.md says so).
#
# Options:
#   --profile <pr|nightly|weekly>   default: pr
#   --count <n>                     run it n times and report every verdict
#                                   (default 1). A seed given with --count > 1
#                                   is the reproduction question; a seed left
#                                   out is the search for one.
#   --seed <u64>                    pin the nemesis schedule
#   --scenario-filter <glob>        narrow the registry
#   --stop-at-step <n>              stop after n scheduled ops and take the
#                                   same snapshot a violation would, with rc 0
#   --out <dir>                     where the evidence tree goes, one
#                                   `run-<n>/` subdirectory per run
#                                   (default: a fresh temp directory, printed)
#
# What this deliberately does NOT do: pass `--needle-manifest`. The sealed
# manifest holds every value the run declared, verbatim; CI writes one because
# its `scan-logs.sh` step is a real reader and a landed guard mandates the
# rotation and the discard. A laptop has neither, so the rig seals in memory,
# scans in process, and leaves nothing behind (owner decision Q5).
#
# It also does not scan through `tooling/e2e/ci/scan-logs.sh`: the rig's own
# per-scenario scan runs in process against the manifest it just sealed, which
# is the stronger of the two, and the lane's second (host-needle) pass exists
# for needles a laptop does not have.
#
# Exit codes: the rig's own, folded across runs as 1 > 2 > 3 > 4 > 0.
#   0 clean   1 leak or violation   2 the rig is broken
#   3 the run proves nothing        4 it proves too little

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SOAK_DIR="${REPO_ROOT}/tooling/soak"

BLUE=$'\033[1;34m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
[[ -t 1 ]] || { BLUE=''; RED=''; RESET=''; }
say() { printf '%s[soak-local]%s %s\n' "${BLUE}" "${RESET}" "$*"; }
die() { printf '%s[soak-local] ERROR:%s %s\n' "${RED}" "${RESET}" "$*" >&2; exit 2; }

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'
  exit "${1:-2}"
}

# The rc taxonomy's fold: 1 beats 2 beats 3 beats 4 beats 0 (haven-logscan's
# `worse()`, which the rig reuses so one taxonomy holds end to end).
worse_rc() { # worse_rc <a> <b>
  local rc
  for rc in 1 2 3 4; do
    if (( $1 == rc || $2 == rc )); then printf '%s\n' "${rc}"; return; fi
  done
  printf '0\n'
}

main() {
  [[ $# -gt 0 ]] || usage 2
  case "$1" in -h|--help) usage 0 ;; esac
  local sub="$1"; shift
  [[ "${sub}" == core ]] || { printf 'unknown subcommand %s\n\n' "${sub}" >&2; usage 2; }

  local profile=pr count=1 out=""
  local -a passthrough=()
  while (( $# > 0 )); do
    case "$1" in
      --profile) [[ $# -ge 2 ]] || die "--profile takes pr|nightly|weekly"; profile="$2"; shift 2 ;;
      --count)   [[ $# -ge 2 ]] || die "--count takes a positive integer"; count="$2"; shift 2 ;;
      --out)     [[ $# -ge 2 ]] || die "--out takes a directory"; out="$2"; shift 2 ;;
      --seed|--scenario-filter|--stop-at-step|--duration|--members|--circles|--relays|--tick-ms)
        [[ $# -ge 2 ]] || die "$1 takes a value"; passthrough+=("$1" "$2"); shift 2 ;;
      --needle-manifest)
        die "--needle-manifest is refused here. The sealed manifest holds every value the run declared, verbatim; CI writes one because its scan step reads it and a landed guard rotates and discards it. A local run has neither, so it seals in memory and leaves nothing on disk." ;;
      -h|--help) usage 0 ;;
      *) die "unknown option '$1'" ;;
    esac
  done

  case "${profile}" in pr|nightly|weekly) ;; *) die "unknown profile '${profile}' (pr|nightly|weekly)" ;; esac
  [[ "${count}" =~ ^[1-9][0-9]*$ ]] || die "--count must be a positive integer, got '${count}'"
  [[ -f "${SOAK_DIR}/Cargo.toml" ]] || die "${SOAK_DIR} not found — the rig is not in this tree."

  if [[ -z "${out}" ]]; then
    out="$(mktemp -d -t haven-soak-local.XXXXXX)"
  fi
  mkdir -p "${out}"
  say "evidence tree: ${out}"

  # One build, then N runs: a rebuild between runs would put compile time inside
  # the reproduction loop and make the verdicts harder to compare.
  say "building the rig under [profile.soak] (release + debug-assertions)"
  ( cd "${SOAK_DIR}" && cargo build --profile soak --bin haven-soak )

  local fold=0 i rc verdicts="" run_dir
  for (( i = 1; i <= count; i++ )); do
    rc=0
    # One directory per run, emptied first. The rig writes its banner, its
    # schedule, its markers and any first-violation snapshot beside the
    # timeline, so a shared directory would leave run 3 reading run 1's marker
    # and run 2's banner — which is exactly the comparison --count exists for.
    run_dir="${out}/run-${i}"
    rm -rf "${run_dir}"
    mkdir -p "${run_dir}"
    ( cd "${SOAK_DIR}" \
        && cargo run --profile soak --bin haven-soak -- \
             --profile "${profile}" \
             --timeline-out "${run_dir}/soak-timeline.log" \
             ${passthrough[@]+"${passthrough[@]}"} ) || rc=$?
    verdicts+="  run ${i}: rc ${rc}"$'\n'
    say "run ${i}/${count}: rc ${rc} (evidence in run-${i})"
    fold="$(worse_rc "${fold}" "${rc}")"
  done

  printf '%s' "${verdicts}"
  say "verdict ${fold} over ${count} run(s) of the ${profile} profile"
  if (( count > 1 )); then
    say "a defect reproduces at every run of one seed; anything less is a race in the rig, which is a bug in the rig."
  fi
  exit "${fold}"
}

main "$@"
