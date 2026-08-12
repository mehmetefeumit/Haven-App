#!/usr/bin/env bash
#
# The FAST half of repo-guards.yml, for the pre-commit hook.
#
# ## Why this exists
#
# repo-guards.yml is a pure-grep job, but not a uniformly fast one: the e2e
# harness `--self-test`s inside it drive watchdogs and sleep through fixtures
# (run-ios-sim-scenario alone is ~24 s, the wire-journal oracles ~15 s each),
# which is fine for CI and far too slow for something that runs on every commit.
# The SOURCE guards are the opposite: argument-less greps over the tree, with no
# watchdog, no fixture and nothing to wait on, and they are fanned out across
# cores below. Neither their COUNT nor a wall-clock figure is written down here
# — the list is DERIVED (below), so both go stale on the next guard added; the
# count is printed at run time instead.
#
# That fast half is also the half that keeps catching things. In CI run
# 31216078806 `check_location_access_gate.sh` went red because a stagger
# refactor moved a `.timeout(` one call deeper than the guard could follow —
# visible in a two-second grep, paid for with a full CI round-trip instead.
#
# ## The list is DERIVED, never hardcoded
#
# It is read out of .github/workflows/repo-guards.yml, which stays the single
# source of truth. A guard added there is picked up here on the next commit with
# no edit to this file — a hardcoded copy would drift silently, and a hook that
# silently checks less than it claims is worse than no hook.
#
# The selection is "argument-less `bash scripts/ci/check_*.sh`", which is
# exactly the source-guard shape. Anything taking a flag (`--self-test`) or
# living under tooling/e2e/ci is deliberately excluded as the slow half; CI and
# the pre-push gate still run everything.
#
# ## What this does NOT do
#
# It reads the WORKING TREE, not the staged content — same as the coverage
# manifest lint already on this hook. So it can flag an edit you have not staged
# yet, and (rarely) miss a bad staged change you have already fixed unstaged.
# Isolating the index properly means stashing, which can lose work; for a
# two-second advisory that trade is not worth it. CI remains the authority.
#
# Usage:
#   bash scripts/ci/run_source_guards.sh            # run them
#   bash scripts/ci/run_source_guards.sh --list     # print what would run
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WORKFLOW="${ROOT}/.github/workflows/repo-guards.yml"

RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
[[ -t 1 ]] || { RED=''; GREEN=''; DIM=''; RESET=''; }

if [[ ! -f "${WORKFLOW}" ]]; then
  echo "${RED}ERROR${RESET}: ${WORKFLOW#"${ROOT}/"} not found — cannot derive the guard list." >&2
  exit 1
fi

mapfile -t GUARDS < <(
  grep -oE 'bash scripts/ci/check_[a-zA-Z0-9_]+\.sh$' "${WORKFLOW}" \
    | sed 's|^bash ||' | sort -u
)

# A hook that found nothing to run must SAY so, not exit 0. An empty list means
# the workflow's shape changed under this parser, and silently passing would
# turn the whole hook into decoration.
if (( ${#GUARDS[@]} == 0 )); then
  echo "${RED}ERROR${RESET}: derived an EMPTY guard list from ${WORKFLOW#"${ROOT}/"}." >&2
  echo "  The parser expects steps shaped 'run: bash scripts/ci/check_<name>.sh'." >&2
  echo "  Fix this script rather than bypassing it — it is currently checking nothing." >&2
  exit 1
fi

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${GUARDS[@]}"
  exit 0
fi

jobs="$( { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4; } )"

# Each guard writes its own output file so parallel runs cannot interleave, and
# a failure can be replayed in full rather than as a stray line.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

printf '%s' "${DIM}▶ ${#GUARDS[@]} source guards${RESET} "
printf '%s\n' "${GUARDS[@]}" \
  | xargs -P "${jobs}" -I{} bash -c '
      g="{}"; out="'"${tmp}"'/$(printf "%s" "$g" | tr "/" "_").out"
      # The guard PATH is recorded inside the marker, never encoded in the
      # filename: round-tripping a path through a filename mangles the
      # underscores that every guard name contains.
      if bash "'"${ROOT}"'/$g" >"$out" 2>&1; then printf .; else printf X; printf "%s" "$g" >"$out.failed"; fi
    '
echo

failed=0
for f in "${tmp}"/*.failed; do
  [[ -e "$f" ]] || break
  base="${f%.failed}"
  echo "${RED}FAILED${RESET}: $(cat "${f}")"
  sed 's/^/    /' "${base}" >&2
  failed=1
done

if (( failed )); then
  echo "${RED}Source guards FAILED.${RESET} Fix the above, or commit with --no-verify." >&2
  exit 1
fi

echo "${GREEN}OK${RESET}: ${#GUARDS[@]} source guards passed."
