#!/usr/bin/env bash
#
# Provisions CI tools from the Ubuntu archive, through a transient mirror
# outage, or fails naming them.
#
# ubuntu-latest moved to Ubuntu 26.04, which ships no xmllint, so the guards
# job installs it on every run instead of only when an image regressed. In CI
# run 44523702729 every archive mirror answered 503 or timed out for minutes,
# the one-shot `apt-get install` failed, and twelve guard steps went red
# blaming everything but the archive.
#
#   * Only a tool whose command is missing is installed: a healthy image costs
#     no network at all.
#   * The first attempt resolves against the package lists the image ships —
#     that run's `apt-get update` fetched no Ubuntu index, and the install
#     still resolved the package — so an `update` is paid only after a failed
#     attempt, where it also cures a list naming a version the archive has
#     since removed (404).
#   * The retry is a whole download, not apt's per-URI `Acquire::Retries`: apt
#     spends every retry on one URI before failing over to the next mirror,
#     which is why the runner image sets it to 1. An outage of the whole mirror
#     list needs time, not more attempts at one host. The Acquire values below
#     are the image's own, stated so the budget does not depend on the image.
#   * Every network call runs under `timeout` with the budget that is left, so
#     this fails, naming the tools, before the step's `timeout-minutes` does.
#     Only the download is ever killed: the install proper runs afterwards from
#     the local cache with `--no-download`, untimed, so dpkg is never cut off.
#
# Usage:
#   ensure_ci_tools.sh <command>=<package>...    e.g. xmllint=libxml2-utils jq=jq
#   ensure_ci_tools.sh --self-test
#
# Env: ENSURE_CI_TOOLS_BUDGET  seconds the archive may take in all (default 300)
#      ENSURE_CI_TOOLS_PAUSE   seconds between attempts (default 10)
#
# Exit: 0 every command is present; 1 a tool could not be provisioned (an
# infrastructure failure, never a guard verdict); 2 usage.

set -euo pipefail

usage() { echo "usage: $0 <command>=<package>... | --self-test" >&2; exit 2; }

ensure() {
  local budget="${ENSURE_CI_TOOLS_BUDGET:-300}" pause="${ENSURE_CI_TOOLS_PAUSE:-10}"
  local pair cmds=() pkgs=() root=()
  (($#)) || usage
  for pair in "$@"; do
    [[ "${pair}" =~ ^[A-Za-z0-9._+-]+=[a-z0-9][a-z0-9.+-]+$ ]] || usage
    command -v "${pair%%=*}" >/dev/null 2>&1 || { cmds+=("${pair%%=*}"); pkgs+=("${pair#*=}"); }
  done
  ((${#pkgs[@]})) || return 0
  ((EUID == 0)) || root=(sudo)
  local apt=(apt-get -q -y --no-install-recommends
    -o Acquire::Retries=1 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15)
  local deadline=$((SECONDS + budget))
  # `timeout 0` means no limit, so a spent budget must refuse, not call it.
  within() {
    local left=$((deadline - SECONDS))
    ((left > 0)) && "${root[@]}" timeout "${left}" "$@"
  }
  give_up() {
    echo "::error title=CI tool provisioning::$1 ${pkgs[*]} (for ${cmds[*]}) — an infrastructure failure, not a guard verdict; every guard needing ${cmds[*]} reports it missing." >&2
    exit 1
  }

  echo "Installing ${pkgs[*]} for ${cmds[*]} (archive budget ${budget}s)."
  until within "${apt[@]}" install --download-only "${pkgs[@]}"; do
    ((SECONDS + pause < deadline)) || give_up "the Ubuntu archive did not serve, within ${budget}s,"
    sleep "${pause}"
    within "${apt[@]}" update || true
  done
  "${root[@]}" "${apt[@]}" install --no-download "${pkgs[@]}" \
    || give_up "apt could not install the downloaded"
  for pair in "${cmds[@]}"; do
    command -v "${pair}" >/dev/null 2>&1 || give_up "${pair} is still missing after installing"
  done
}

self_test() {
  local tmp failures=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  mkdir "${tmp}/bin"
  # sudo stub: the real one resets PATH, which would bypass the apt-get stub.
  printf '#!/usr/bin/env bash\nexec "$@"\n' >"${tmp}/bin/sudo"
  # apt-get stub. Every call is logged; STUB_MODE picks the archive's health.
  cat >"${tmp}/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
args=" $* "
op=install; [[ "${args}" == *" update "* ]] && op=update
[[ "${args}" == *" --download-only "* ]] && op=download
[[ "${args}" == *" --no-download "* ]] && op=unpack
echo "${op}" >>"${STUB_DIR}/calls"
case "${STUB_MODE}:${op}" in
  hang:download) exec sleep 600 ;;
  down:download) exit 100 ;;
  stale:download) [[ -e "${STUB_DIR}/refreshed" ]] || exit 100 ;;
  stale:update) touch "${STUB_DIR}/refreshed" ;;
  *:unpack)
    [[ "${STUB_MODE}" == wrong ]] && exit 0
    printf '#!/bin/sh\n' >"${STUB_DIR}/bin/haven-selftest-tool"
    chmod +x "${STUB_DIR}/bin/haven-selftest-tool"
    ;;
esac
STUB
  chmod +x "${tmp}/bin/sudo" "${tmp}/bin/apt-get"

  # _case <name> <want rc> <mode> <budget> <want calls> <stderr regex, '' = silent> <args...>
  _case() {
    local name="$1" want="$2" mode="$3" budget="$4" calls="$5" err="$6" got=0
    shift 6
    rm -f "${tmp}/calls" "${tmp}/refreshed" "${tmp}/bin/haven-selftest-tool"
    : >"${tmp}/calls"
    PATH="${tmp}/bin:${PATH}" STUB_DIR="${tmp}" STUB_MODE="${mode}" \
      ENSURE_CI_TOOLS_BUDGET="${budget}" ENSURE_CI_TOOLS_PAUSE=0 \
      bash "${BASH_SOURCE[0]}" "$@" >/dev/null 2>"${tmp}/err" || got=$?
    local seen
    seen="$(paste -sd' ' "${tmp}/calls")"
    if [[ "${got}" != "${want}" || "${seen}" != "${calls}" ]] \
      || { [[ -z "${err}" ]] && [[ -s "${tmp}/err" ]]; } \
      || { [[ -n "${err}" ]] && ! grep -qE "${err}" "${tmp}/err"; }; then
      echo "self-test FAILED [${name}]: rc ${got} (want ${want}), apt calls '${seen}' (want '${calls}')" >&2
      sed 's/^/    /' "${tmp}/err" >&2
      failures=$((failures + 1))
    fi
  }

  _case "a present tool touches no network" 0 healthy 60 "" '' bash=bash
  _case "a missing tool is fetched, then installed from the cache" 0 healthy 60 \
    "download unpack" '' bash=bash haven-selftest-tool=haven-pkg
  _case "a failed fetch refreshes the lists and tries again" 0 stale 60 \
    "download update download unpack" '' haven-selftest-tool=haven-pkg
  _case "an archive that never serves fails naming the tool and the package, and installs nothing" 1 down 0 \
    "" 'haven-pkg \(for haven-selftest-tool\) — an infrastructure failure' haven-selftest-tool=haven-pkg
  _case "a hung fetch is killed at the budget, not at the step cap" 1 hang 2 \
    "download" 'did not serve, within 2s, haven-pkg \(for haven-selftest-tool\)' haven-selftest-tool=haven-pkg
  _case "a package that does not provide the command fails" 1 wrong 60 \
    "download unpack" 'haven-selftest-tool is still missing' haven-selftest-tool=haven-pkg
  _case "no arguments are a usage error" 2 healthy 60 "" '^usage:'
  _case "a malformed pair is a usage error" 2 healthy 60 "" '^usage:' 'xmllint libxml2-utils'

  if ((failures > 0)); then
    echo "ensure_ci_tools: self-test FAILED (${failures})" >&2
    return 1
  fi
  echo "ensure_ci_tools: self-test OK (8 fixtures)."
}

case "${1:-}" in
  --self-test) self_test ;;
  *) ensure "$@" ;;
esac
