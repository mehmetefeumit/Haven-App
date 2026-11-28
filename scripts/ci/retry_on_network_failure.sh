#!/usr/bin/env bash
# Run a build command again only when it failed on the network.
#
# v0.1.15's iOS launch gate died in `pod install`: "Could not resolve host:
# cdn.cocoapods.org" (release run 43688120017). The same macOS runner had lost
# DNS four minutes earlier, and cargo's own retry carried the logscan build
# through it. CocoaPods retries CDN downloads, but not adding the trunk source
# on a fresh runner: a failed lookup sends it to a single `git clone`, so one
# lost lookup failed the release.
#
# Only a failure whose output names a network-level cause is retried, in at
# most ATTEMPTS attempts with a growing wait. Anything else, a real `pod install` or
# compile error included, fails at once with its own rc: retrying a
# deterministic failure would hide it behind more minutes, and an output that
# shows a recovered network warning beside a real error only costs the retries,
# never a false green, because every attempt must succeed on its own merits.
#
# One failure that is not the network is still not the change: Swift Package
# Manager's clone of a plugin's package refused by GitHub ("Failed to clone
# repository https://github.com/TimOliver/TOCropViewController.git: … could
# not read Username", job 140577177342 — GitHub answering an anonymous clone of
# a public repository as if it needed credentials). It is not retried; it fails
# at once with its own rc and one ::error:: naming the package and calling it
# infrastructure, so it is not read as the change under test.
#
# Usage:
#   retry_on_network_failure.sh -- <command> [args...]
#   retry_on_network_failure.sh --self-test
#
# Exit: the last attempt's rc; 2 on misuse. Written for bash 3.2.

set -uo pipefail

readonly ATTEMPTS=3
BACKOFF_SECS=(30 90)
# Every way CocoaPods' trunk setup fails is caught by its own line, since a
# lookup it swallows can recover in time for the clone to fail differently.
readonly NETWORK_RE='Could not resolve host|Couldn.t resolve host|Temporary failure in name resolution|nodename nor servname provided|Failed host lookup|Failed to connect to|Couldn.t connect to server|Failed to open TCP connection|Network is unreachable|Connection timed out|Connection reset by peer|Operation timed out|Timeout was reached|Empty reply from server|SSL_ERROR_SYSCALL|SSL connect error|Recv failure|The requested URL returned error: 5[0-9][0-9]|The Internet connection appears to be offline|A server with the specified hostname could not be found|Unable to add a source with url `https://cdn\.cocoapods\.org/`'
# A Swift package xcodebuild could not clone. The URL is a public package's,
# never anything of the user's.
readonly SPM_CLONE_RE='Failed to clone repository https://[^[:space:]:]+'
readonly SELF_TEST_CASES=9

note() { printf '[retry_on_network_failure] %s\n' "$*"; }

run() { # <command> [args...]
  local attempt=1 rc log
  log="$(mktemp)"
  while :; do
    "$@" 2>&1 | tee "${log}"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then rm -f "${log}"; return 0; fi
    if ! grep -Eq "${NETWORK_RE}" "${log}"; then
      if grep -Eq "${SPM_CLONE_RE}" "${log}"; then
        echo "::error::Swift Package Manager could not clone $(grep -Eo "${SPM_CLONE_RE}" "${log}" | head -n 1 | sed 's/^Failed to clone repository //'): the host refused or dropped the clone (infrastructure, not the change under test; not retried); re-run the job"
      fi
      rm -f "${log}"; return "${rc}"
    fi
    if (( attempt >= ATTEMPTS )); then
      note "INFRASTRUCTURE: attempt ${attempt}/${ATTEMPTS} also failed on the network (rc ${rc}); giving up."
      echo "::error::network failure on every one of ${ATTEMPTS} attempts (infrastructure, not the change under test); re-run the job"
      rm -f "${log}"; return "${rc}"
    fi
    note "attempt ${attempt}/${ATTEMPTS} failed on the network (rc ${rc}); retrying in ${BACKOFF_SECS[attempt-1]} s."
    echo "::warning::attempt ${attempt}/${ATTEMPTS} failed on the network (infrastructure); retrying"
    ${RETRY_ON_NETWORK_SLEEP:-sleep} "${BACKOFF_SECS[attempt-1]}"
    attempt=$(( attempt + 1 ))
  done
}

self_test() {
  local tmp ran=0 fail=0 rc
  tmp="$(mktemp -d)"
  # A stub that fails the first N runs with the given text, then succeeds.
  cat > "${tmp}/stub" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$1" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "$1"
if (( n <= $2 )); then echo "$3"; exit "$4"; fi
echo ok
EOF
  chmod +x "${tmp}/stub"
  expect() { # <label> <want rc> <want runs> <fails> <text> <rc>
    rm -f "${tmp}/count"
    rc=0; RETRY_ON_NETWORK_SLEEP=: run "${tmp}/stub" "${tmp}/count" "$4" "$5" "$6" >/dev/null 2>&1 || rc=$?
    local runs; runs="$(cat "${tmp}/count")"
    if [[ "${rc}" == "$2" && "${runs}" == "$3" ]]; then echo "  PASS $1"; else
      echo "  FAIL $1: rc ${rc} after ${runs} run(s), want rc $2 after $3" >&2; fail=1; fi
    ran=$(( ran + 1 ))
  }
  expect "a success runs once" 0 1 0 "" 0
  expect "a lost DNS lookup is retried, then passes" 0 2 1 "fatal: unable to access 'https://cdn.cocoapods.org/': Could not resolve host: cdn.cocoapods.org" 1
  expect "a trunk setup whose clone fails without a host error is retried" 0 2 1 "[!] Unable to add a source with url \`https://cdn.cocoapods.org/\` named \`trunk\`." 1
  expect "a real pod install error is not retried" 1 1 9 "[!] CocoaPods could not find compatible versions for pod \"Foo\"" 1
  expect "a compile error keeps its own rc, once" 65 1 9 "error: cannot find 'x' in scope" 65
  expect "a network failure on every attempt gives up after three" 7 3 9 "curl: (7) Failed to connect to example port 443" 7
  local spm out
  spm="  Failed to clone repository https://github.com/TimOliver/TOCropViewController.git:
    fatal: could not read Username for 'https://github.com': terminal prompts disabled"
  expect "a Swift package clone the host refused is not retried" 1 1 9 "${spm}" 1
  rm -f "${tmp}/count"
  out="$(RETRY_ON_NETWORK_SLEEP=: run "${tmp}/stub" "${tmp}/count" 9 "${spm}" 1 2>&1)" || true
  if [[ "${out}" == *"::error::Swift Package Manager could not clone https://github.com/TimOliver/TOCropViewController.git: "*"infrastructure"* ]]; then
    echo "  PASS …and is named as infrastructure, with the package"; ran=$(( ran + 1 ))
  else echo "  FAIL a refused Swift package clone must be named as infrastructure with its package: ${out}" >&2; fail=1; ran=$(( ran + 1 )); fi
  rc=0; bash "${BASH_SOURCE[0]}" -- >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" == 2 ]]; then echo "  PASS no command is refused (rc 2)"; else echo "  FAIL no command gave rc ${rc}, want 2" >&2; fail=1; fi
  ran=$(( ran + 1 ))
  rm -rf "${tmp}"
  (( ran == SELF_TEST_CASES )) || { echo "self-test FAIL: ran ${ran}, pinned ${SELF_TEST_CASES}" >&2; fail=1; }
  (( fail == 0 )) || { echo "retry_on_network_failure.sh --self-test: FAILED" >&2; return 1; }
  echo "retry_on_network_failure.sh --self-test: all ${ran} cases passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  --) shift; (( $# )) || { echo "usage: $0 -- <command> [args...]" >&2; exit 2; }; run "$@" ;;
  *) echo "usage: $0 -- <command> [args...] | --self-test" >&2; exit 2 ;;
esac
