#!/usr/bin/env bash
# CI gate: no committed pubspec.lock pins a retracted package version.
#
# A publisher retracts a pub version that should never have been used, and the
# pub client then avoids it for new resolutions — but a lockfile already
# holding it keeps it, silently. That is the whole of the pub malware case:
# universal_file_viewer 0.1.5 and 0.1.6 carried XCSSET-style malware and were
# retracted, with no GitHub advisory and no OpenSSF MAL record, so osv-scanner
# (run_osv_gate.sh) cannot see them and only the retracted flag does. A
# retraction is never acknowledgeable: a non-retracted version always exists,
# so the fix is a new lock.
#
# Every hosted package in every committed pubspec.lock is looked up in the
# package API of the registry its lock entry names (`description.url`), and the
# locked version's `retracted` flag read. sdk, path and git packages have no
# registry entry and are skipped. A discontinued package is a warning: it still
# works, and its replacement is a planned change. A registry that does not
# answer, an entry the lock names but the registry does not list, or a non-https
# registry is a misconfiguration, never a pass.
#
# Usage:
#   bash scripts/ci/check_pub_retractions.sh [<pubspec.lock>...]
#       defaults to every committed pubspec.lock
#   bash scripts/ci/check_pub_retractions.sh --self-test   # stubbed curl, no network
#
# SECURITY_FINDINGS_OUT, when set, gets one `retracted:<pkg>@<ver>\t<summary>`
# line per retracted version.
#
# Exit codes:
#   0  no retracted version (discontinued ones warn), or the self-test passed
#   1  a locked version is retracted (or the self-test failed)
#   2  misconfiguration: an unreadable lockfile, a registry that did not answer
#      or does not list the locked version, a non-https registry

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=10
# Registry requests in flight at once: the locks hold about 200 packages, and
# one at a time took 35 s.
readonly FETCH_JOBS=8

log() {
  printf '\033[1;34m[check_pub_retractions]\033[0m %s\n' "$*"
}

finding() { # <key> <summary>
  [[ -n "${SECURITY_FINDINGS_OUT:-}" ]] || return 0
  printf '%s\t%s\n' "$1" "$2" >>"${SECURITY_FINDINGS_OUT}"
}

# "<name>\t<version>\t<registry url>" for each hosted package; rc 2 when the
# lock has no package section or a hosted entry lacks a field.
hosted_packages() { # <pubspec.lock>
  awk '
    function unq(v) { sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/^"|"[[:space:]]*$/, "", v); return v }
    function emit() {
      if (pkg != "" && src == "hosted") {
        if (name == "" || ver == "" || url == "") { printf "ERROR: %s: hosted package %s lacks its name, version or url\n", FILENAME, pkg > "/dev/stderr"; bad = 1 }
        else printf "%s\t%s\t%s\n", name, ver, url
      }
      n++; pkg = name = ver = url = src = ""
    }
    /^packages:[[:space:]]*$/ { inpk = 1; next }
    inpk && /^[^[:space:]#]/ { emit(); inpk = 0; done = 1 }
    !inpk { next }
    /^  [^[:space:]][^:]*:[[:space:]]*$/ { if (pkg != "") emit(); pkg = $1; sub(/:$/, "", pkg); next }
    /^      name:/ { name = unq($0) }
    /^      url:/ { url = unq($0) }
    /^    source:/ { src = unq($0) }
    /^    version:/ { ver = unq($0) }
    END { if (inpk) emit(); if (n == 0) { printf "ERROR: %s has no packages section\n", FILENAME > "/dev/stderr"; exit 2 } if (bad) exit 2 }
  ' "$1"
}

fetch() { # <registry url> <package> <out>
  curl -fsS --connect-timeout 10 --max-time 60 --retry 3 --retry-all-errors -H 'Accept: application/vnd.pub.v2+json' \
    "${1%/}/api/packages/$2" -o "$3" 2>/dev/null || rm -f "$3"
}

check() { # <pubspec.lock>...
  local lock name ver url body entry retracted=0 checked=0 tmp n=0 running=0
  local -A bodies=()
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  (( $# > 0 )) || { echo "ERROR: no pubspec.lock to check" >&2; return 2; }
  for lock in "$@"; do
    [[ -f "${lock}" ]] || { echo "ERROR: ${lock} not found" >&2; return 2; }
    hosted_packages "${lock}" >>"${tmp}/rows" || return 2
  done
  sort -u -o "${tmp}/rows" "${tmp}/rows"
  # Every package fetched once, FETCH_JOBS at a time; read below in sorted
  # order, so the output does not depend on which answer came first.
  while IFS=$'\t' read -r name ver url; do
    [[ "${name}" =~ ^[a-z0-9_]+$ ]] || { echo "ERROR: '${name}' is not a pub package name" >&2; return 2; }
    [[ "${url}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] \
      || { echo "ERROR: ${name} is hosted at '${url}', which is not an https registry" >&2; return 2; }
    [[ -z "${bodies["${url} ${name}"]:-}" ]] || continue
    n=$(( n + 1 )); bodies["${url} ${name}"]="${tmp}/body.${n}.json"
    fetch "${url}" "${name}" "${tmp}/body.${n}.json" &
    running=$(( running + 1 ))
    (( running < FETCH_JOBS )) || { wait -n; running=$(( running - 1 )); }
  done <"${tmp}/rows"
  wait
  while IFS=$'\t' read -r name ver url; do
    body="${bodies["${url} ${name}"]}"
    [[ -f "${body}" ]] || { echo "ERROR: ${url%/}/api/packages/${name} did not answer" >&2; return 2; }
    entry="$(jq -c --arg v "${ver}" '[.versions[]? | select(.version == $v)][0] // empty' "${body}" 2>/dev/null)" \
      || { echo "ERROR: ${url%/}/api/packages/${name} answered something that is not package JSON" >&2; return 2; }
    [[ -n "${entry}" ]] || { echo "ERROR: ${url} lists no ${name} ${ver}, the version the lock pins" >&2; return 2; }
    checked=$(( checked + 1 ))
    if [[ "$(jq -r '.retracted == true' <<<"${entry}")" == true ]]; then
      printf '\033[1;31m  %s %s is RETRACTED by its publisher\033[0m\n' "${name}" "${ver}" >&2
      finding "retracted:${name}@${ver}" "${name} ${ver} is retracted on ${url}"
      retracted=1
    fi
    if [[ "$(jq -r '.isDiscontinued == true' "${body}")" == true ]]; then
      printf 'warning: %s is discontinued%s\n' "${name}" "$(jq -r 'if .replacedBy then " (replaced by \(.replacedBy))" else "" end' "${body}")"
    fi
  done <"${tmp}/rows"
  (( checked > 0 )) || { echo "ERROR: no hosted package in $*" >&2; return 2; }
  if (( retracted )); then
    printf '\033[1;31m[check_pub_retractions] FAIL:\033[0m a lock pins a retracted version. Re-resolve it (flutter pub upgrade <package>); a retraction cannot be acknowledged.\n' >&2
    return 1
  fi
  log "OK: ${checked} hosted package version(s) across $# lockfile(s); none retracted."
}

committed_locks() {
  git -C "${REPO_ROOT}" ls-files -co --exclude-standard -- '*pubspec.lock' | while read -r rel; do
    [[ -f "${REPO_ROOT}/${rel}" ]] && printf '%s\n' "${REPO_ROOT}/${rel}"
  done
}

# ---------------------------------------------------------------------------
# Self-test. The API answers are real pub.dev responses (2026-11-12) cut down
# to the versions used here, served by a curl stub that logs each URL asked.
# ---------------------------------------------------------------------------
self_test() {
  local fx="${REPO_ROOT}/scripts/ci/fixtures/dependency-security/pub" tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/bin" "${tmp}/api/pub.example.org"
  cp -R "${fx}/pub.dev" "${tmp}/api/pub.dev"
  printf 'not json\n' >"${tmp}/api/pub.dev/garbled.json"
  # Serves https://<host>/api/packages/<name> from api/<host>/<name>.json,
  # failing as `curl -f` does when there is no such file.
  cat >"${tmp}/bin/curl" <<EOF
#!/usr/bin/env bash
out='' url=''
while (( \$# )); do case "\$1" in -o) out="\$2"; shift 2 ;; -H|--connect-timeout|--max-time|--retry) shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
printf '%s\n' "\${url}" >>"${tmp}/asked"
[[ "\${url}" =~ ^https://([^/]+)/api/packages/([a-z0-9_]+)\$ ]] || exit 3
f="${tmp}/api/\${BASH_REMATCH[1]}/\${BASH_REMATCH[2]}.json"
[[ -f "\${f}" ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "\${f}" "\${out}"
EOF
  chmod +x "${tmp}/bin/curl"

  _lock() { # <name> <sed expression> -> a variant of the clean lock
    sed "$2" "${fx}/clean.pubspec.lock.txt" >"${tmp}/$1.lock"
    printf '%s' "${tmp}/$1.lock"
  }
  _case() { # <label> <want-rc> <needle|-> <cmd>...
    local label="$1" want="$2" needle="$3" got=0; shift 3
    checked=$(( checked + 1 ))
    : >"${tmp}/findings"; : >"${tmp}/asked"
    ( PATH="${tmp}/bin:${PATH}" SECURITY_FINDINGS_OUT="${tmp}/findings" "$@" ) >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]] && { [[ "${needle}" == - ]] || grep -qF -- "${needle}" "${tmp}/out" "${tmp}/findings" "${tmp}/asked"; }; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d%s)\n' "${label}" "${want}" "${got}" "$([[ "${needle}" == - ]] || printf ', want output containing %q' "${needle}")" >&2
      sed 's/^/      /' "${tmp}/out" >&2
      fails=1
    fi
  }

  echo "check_pub_retractions.sh --self-test"
  # The clean lock asks the registry about its one hosted package and nothing
  # else: the sdk, path and git entries have no registry to ask.
  _only_hosted() { check "$@" && [[ "$(cat "${tmp}/asked")" == 'https://pub.dev/api/packages/http' ]]; }
  _case "a lock with no retracted version passes, asking only about hosted packages" 0 - \
    _only_hosted "${fx}/clean.pubspec.lock.txt"

  _case "a retracted locked version fails and files its finding" 1 \
    "$(printf 'retracted:universal_file_viewer@0.1.5\tuniversal_file_viewer 0.1.5 is retracted on https://pub.dev')" \
    check "$(_lock retracted 's/name: http$/name: universal_file_viewer/; s/version: "1.6.0"/version: "0.1.5"/')"

  _case "the non-retracted neighbour of a retracted version passes" 0 - \
    check "$(_lock fixed 's/name: http$/name: universal_file_viewer/; s/version: "1.6.0"/version: "0.1.7"/')"

  _case "a discontinued package warns and passes" 0 'warning: pedantic is discontinued (replaced by lints)' \
    check "$(_lock discontinued 's/name: http$/name: pedantic/; s/version: "1.6.0"/version: "1.11.1"/')"

  cp "${fx}/pub.dev/http.json" "${tmp}/api/pub.example.org/http.json"
  _case "the registry the lock entry names is the one asked" 0 'https://pub.example.org/api/packages/http' \
    check "$(_lock custom 's|url: "https://pub.dev"|url: "https://pub.example.org"|')"

  _case "a locked version the registry does not list is a misconfiguration" 2 'lists no http 9.9.9' \
    check "$(_lock unlisted 's/version: "1.6.0"/version: "9.9.9"/')"

  _case "a registry that does not answer is a misconfiguration" 2 'did not answer' \
    check "$(_lock missing 's/name: http$/name: no_such_package/')"

  _case "a registry answering something other than package JSON is a misconfiguration" 2 'not package JSON' \
    check "$(_lock garbled 's/name: http$/name: garbled/')"

  _case "a hosted package on a non-https registry is a misconfiguration" 2 'not an https registry' \
    check "$(_lock plain 's|url: "https://pub.dev"|url: "http://pub.dev"|')"

  # More packages than are fetched at once, the one that does not answer in
  # the middle: each is asked for once, and the run still fails on it.
  local i
  { printf 'packages:\n'
    for i in p0 p1 p2 p3 p4 no_such_package p5 p6 p7 p8 p9; do
      [[ "${i}" == no_such_package ]] || cp "${fx}/pub.dev/http.json" "${tmp}/api/pub.dev/${i}.json"
      printf '  %s:\n    dependency: transitive\n    description:\n      name: %s\n      url: "https://pub.dev"\n    source: hosted\n    version: "1.6.0"\n' "${i}" "${i}"
    done
  } >"${tmp}/many.lock"
  _each_once() {
    local rc=0
    check "$@" || rc=$?
    [[ "$(sort -u "${tmp}/asked" | wc -l)" -eq 11 && "$(wc -l <"${tmp}/asked")" -eq 11 ]] || return 3
    return "${rc}"
  }
  _case "packages fetched in parallel are each asked for once, and one that does not answer still fails the run" 2 \
    'https://pub.dev/api/packages/no_such_package did not answer' _each_once "${tmp}/many.lock"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  '') mapfile -t LOCKS < <(committed_locks); check "${LOCKS[@]}" ;;
  -*) echo "usage: $(basename "$0") [<pubspec.lock>... | --self-test]" >&2; exit 2 ;;
  *) check "$@" ;;
esac
