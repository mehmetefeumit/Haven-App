#!/usr/bin/env bash
#
# Rotates the needle directory the recording wire proxy declares into and
# `haven-logscan seal` writes to: the declaration sidecars, the sealed
# manifest and the wire-canary manifest of any previous run are removed, and
# the directory exists owner-only. The same three `rm -f` shapes a lane runs
# inline before its first proxy start (e2e-android.yml, e2e-ios.yml); this
# script exists for the ONE place they cannot be written inline — a
# `nick-fields/retry` command, which restarts the proxy per attempt and which
# scripts/ci/check_e2e_lane_budget.sh admits only as a chain of tooling
# scripts. It must run BEFORE the proxy starts: the proxy creates its sidecar
# with O_EXCL on the drive's first declaration, so a file left by the previous
# attempt would make it refuse (or, appended to, seal that attempt's
# identifiers into this one's manifest), and a rotation once the proxy is live
# would unlink the file it holds open.
#
# Usage:
#   rotate-needle-dir.sh
#   rotate-needle-dir.sh --self-test
#
# The directory is a constant, never an argument or an env override, for the
# reason check_wire_proxy_test_only.sh records: a location-keyed guard is only
# as good as the path being fixed.

set -euo pipefail

readonly NEEDLE_DIR=/tmp/haven-soak/needles

rotate_needle_dir() {
  local dir="$1"
  mkdir -m 0700 -p "${dir}"
  rm -f "${dir}"/*.needles.decl "${dir}"/*.needles.json "${dir}"/*.canaries.json
}

run_self_test() {
  local tmp fail=0 dir mode
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  dir="${tmp}/needles"
  # (1) A fresh directory is created owner-only.
  rotate_needle_dir "${dir}"
  mode="$(stat -c '%a' "${dir}" 2>/dev/null || stat -f '%OLp' "${dir}")"
  if [[ ! -d "${dir}" || "${mode}" != "700" ]]; then
    echo "SELF-TEST FAIL (1): expected an owner-only directory, got mode '${mode}'" >&2
    fail=1
  fi
  # (2) Every sidecar shape of a previous run goes; the proxy's own pid and
  #     claim files, which are not needles, stay.
  : > "${dir}/alice.needles.decl"
  : > "${dir}/local-local.needles.json"
  : > "${dir}/alice.canaries.json"
  : > "${dir}/haven-wire-proxy.pid"
  rotate_needle_dir "${dir}"
  if [[ -e "${dir}/alice.needles.decl" || -e "${dir}/local-local.needles.json" \
        || -e "${dir}/alice.canaries.json" ]]; then
    echo "SELF-TEST FAIL (2): a previous run's sidecar survived the rotation" >&2
    fail=1
  fi
  if [[ ! -e "${dir}/haven-wire-proxy.pid" ]]; then
    echo "SELF-TEST FAIL (2): the rotation removed a file that is not a needle" >&2
    fail=1
  fi
  # (3) The real run rotates the fixed directory and nothing else.
  if ! grep -qE '^rotate_needle_dir "\$\{NEEDLE_DIR\}"$' "${BASH_SOURCE[0]}" \
     || ! grep -qE '^readonly NEEDLE_DIR=/tmp/haven-soak/needles$' "${BASH_SOURCE[0]}"; then
    echo "SELF-TEST FAIL (3): the real run no longer rotates the fixed needle directory" >&2
    fail=1
  fi
  if (( fail )); then
    echo "rotate-needle-dir.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "rotate-needle-dir.sh: self-test passed (3 fixtures: the directory is created owner-only, every previous sidecar shape is removed and nothing else is, and the real run rotates the fixed directory)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi
if (( $# > 0 )); then
  echo "ERROR: usage: $0  |  $0 --self-test" >&2
  exit 2
fi
rotate_needle_dir "${NEEDLE_DIR}"
