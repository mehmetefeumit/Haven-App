#!/usr/bin/env bash
# CI guard: shipped code must never set a KeyPackage's lifetime.
#
# openmls's `KeyPackageBuilder` exposes a lifetime setter (`pub` at
# openmls-0.8.1/src/key_packages/mod.rs:467). Haven's KeyPackages take the
# library default (84 days, lifetime.rs:11) and rotate on that clock
# (`haven-core/src/relay/maintenance/kp_lifetime.rs`). A call to the setter in
# a shipped path could LENGTHEN `not_after` — a published KeyPackage, and the
# init key a Welcome is sealed to, outliving the rotation it is supposed to
# obey. That is the weakening the soak plan's OD-8 refused as a test seam, and
# it must not arrive as a product line either.
#
# The Tier-1 soak rig calls the setter on purpose (S12 `kp-expired-rejected`
# mints an EXPIRED package in the device's production shape), which is why the
# scan roots at the shipped trees only and `tooling/` is outside it.
#
# Same flat shape as check_no_exporter_label_override.sh: the token appears in
# NO file under haven-core/src or haven/rust_builder/src, comments included.
# Prose that needs the setter can say "openmls's KeyPackage lifetime setter"; a
# flat ban needs no comment parsing a rewording could sidestep.
#
# Pure grep, no toolchain.
#
# Usage:
#   bash scripts/ci/check_no_kp_lifetime_override.sh
#   bash scripts/ci/check_no_kp_lifetime_override.sh --self-test
#
# Exit codes:
#   0  the token is absent (or the self-test passed)
#   1  the token appears in a shipped path (or the self-test failed)
#   2  a scanned root is missing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CORE_SRC_DIR="${REPO_ROOT}/haven-core/src"
FFI_SRC_DIR="${REPO_ROOT}/haven/rust_builder/src"
FORBIDDEN_TOKEN='key_package_lifetime'

log() {
  printf '\033[1;34m[check_no_kp_lifetime_override]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_no_kp_lifetime_override] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  run_on() { set +e; REPO_ROOT_OVERRIDE="$1" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; echo $?; set -e; }

  mkdir -p "${tmp}/clean/haven-core/src" "${tmp}/clean/haven/rust_builder/src"
  printf 'fn mint() {}\n' > "${tmp}/clean/haven-core/src/lib.rs"
  [[ "$(run_on "${tmp}/clean")" == 0 ]] || fail "self-test: a clean tree must pass"

  for root in haven-core/src haven/rust_builder/src; do
    cp -r "${tmp}/clean" "${tmp}/planted"
    printf '// .%s(lifetime)\n' "${FORBIDDEN_TOKEN}" > "${tmp}/planted/${root}/kp.rs"
    [[ "$(run_on "${tmp}/planted")" == 1 ]] \
      || fail "self-test: a planted token under ${root} (in a comment) must exit 1"
    rm -rf "${tmp}/planted"
  done

  rm -rf "${tmp}/clean/haven/rust_builder/src"
  [[ "$(run_on "${tmp}/clean")" == 2 ]] || fail "self-test: a missing root must exit 2"

  log "OK: self-test passed — clean passes, a plant in either root fails, a missing root is a misconfiguration."
  exit 0
fi

[[ -d "${CORE_SRC_DIR}" ]] || { echo "ERROR: ${CORE_SRC_DIR} not found" >&2; exit 2; }
[[ -d "${FFI_SRC_DIR}" ]] || { echo "ERROR: ${FFI_SRC_DIR} not found" >&2; exit 2; }

log "Scanning haven-core/src and haven/rust_builder/src for '${FORBIDDEN_TOKEN}' ..."
hits="$(grep -rnF "${FORBIDDEN_TOKEN}" "${CORE_SRC_DIR}" "${FFI_SRC_DIR}" 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}" >&2
  fail "'${FORBIDDEN_TOKEN}' found in a shipped path — setting a KeyPackage's lifetime could lengthen not_after past the rotation Haven promises (soak plan OD-8)"
fi

log "OK: no KeyPackage lifetime override in a shipped path."
