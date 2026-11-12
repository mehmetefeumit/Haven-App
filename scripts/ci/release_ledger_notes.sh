#!/usr/bin/env bash
# Release notes: the advisories a release ships acknowledged.
#
# osv-scanner.toml is the one place an advisory may be acknowledged, each
# entry with a reason and an expiry (scripts/ci/check_ledger.sh holds those
# rules). A release that ships with one says so: this prints every
# [[IgnoredVulns]] id and the day its acknowledgement expires, for
# release-build.yml to put in the GitHub Release body. A ledger it cannot read
# fails the release rather than publishing a list shorter than what ships, and
# an id must look like an advisory id, so nothing in the ledger can write
# markdown into the Release page.
#
# Usage:
#   release_ledger_notes.sh <osv-scanner.toml>   # markdown on stdout
#   release_ledger_notes.sh --self-test
#
# Exit codes:
#   0  printed (or the self-test passed)
#   1  an entry has no readable id or effectiveUntil
#   2  misconfiguration: a missing ledger, an IgnoredVulns spelling this cannot
#      read, or a bad argument

set -euo pipefail

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=7

log() {
  printf '\033[1;34m[release_ledger_notes]\033[0m %s\n' "$*" >&2
}

notes() { # <osv-scanner.toml>
  local ledger="$1" headers mentions entries
  [[ -f "${ledger}" ]] || { echo "ERROR: ${ledger} not found" >&2; return 2; }
  headers="$(grep -cE '^[[:space:]]*\[\[IgnoredVulns\]\][[:space:]]*(#.*)?$' "${ledger}" || true)"
  mentions="$(grep -v '^[[:space:]]*#' "${ledger}" | grep -c 'IgnoredVulns' || true)"
  [[ "${headers}" == "${mentions}" ]] \
    || { echo "ERROR: ${ledger} names IgnoredVulns other than as a [[IgnoredVulns]] table; this cannot read it" >&2; return 2; }
  entries="$(awk '
    function flush() {
      if (!in_entry) return
      if (id !~ /^[A-Z]+(-[A-Za-z0-9]+)+$/ || until !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
        printf "ERROR: entry %d has no readable id or effectiveUntil (id \"%s\")\n", n, id > "/dev/stderr"
        bad = 1
      } else {
        printf "- `%s` until %s\n", id, until
      }
    }
    function value(s) { sub(/^[^=]*=[[:space:]]*/, "", s); sub(/[[:space:]]*(#.*)?$/, "", s); gsub(/^"|"$/, "", s); return s }
    /^[[:space:]]*\[/ { flush(); in_entry = ($0 ~ /^[[:space:]]*\[\[IgnoredVulns\]\]/); if (in_entry) n++; id = ""; until = ""; next }
    in_entry && /^[[:space:]]*id[[:space:]]*=/ { id = value($0); next }
    in_entry && /^[[:space:]]*effectiveUntil[[:space:]]*=/ { until = substr(value($0), 1, 10); next }
    END { flush(); exit bad }
  ' "${ledger}")" || return 1
  echo '## Acknowledged advisories'
  echo
  if [[ -z "${entries}" ]]; then
    echo 'This release ships with no acknowledged advisory.'
  else
    echo 'This release ships with these advisories acknowledged in `osv-scanner.toml`, each with a recorded reason, until the date shown:'
    echo
    printf '%s\n' "${entries}"
  fi
}

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <command>...
    local label="$1" want="$2" got=0; shift 2
    checked=$(( checked + 1 ))
    ( "$@" ) >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      sed 's/^/      /' "${tmp}/out" >&2
      fails=1
    fi
  }
  _lists() { # <ledger> <expected entry lines>
    local out
    out="$(notes "$1")" || return
    [[ "$(grep '^- ' <<<"${out}" || true)" == "$2" ]] || { printf 'listed:\n%s\n' "${out}"; return 1; }
  }

  echo "release_ledger_notes.sh --self-test"
  cat >"${tmp}/two.toml" <<'EOF'
# Acknowledged advisories, one [[IgnoredVulns]] table each.
[[IgnoredVulns]]
id = "RUSTSEC-2026-0459"  # SQLite page cache
effectiveUntil = 2027-02-09T00:00:00Z
reason = "local vector only; owner-decision: 2026-11-12"

[[PackageOverrides]]
id = "not-an-advisory"
effectiveUntil = 2030-01-01T00:00:00Z

[[IgnoredVulns]]
reason = "the id comes after the reason; owner-decision: 2026-10-01"
effectiveUntil = "2027-01-15T00:00:00Z"
id = "GHSA-72w2-rjgg-q729"
EOF
  _case "every IgnoredVulns entry is listed with its expiry, and no other table" 0 _lists "${tmp}/two.toml" \
    "$(printf '%s\n' '- `RUSTSEC-2026-0459` until 2027-02-09' '- `GHSA-72w2-rjgg-q729` until 2027-01-15')"

  printf '# nothing acknowledged\n' >"${tmp}/none.toml"
  _none() { notes "$1" | grep -qx 'This release ships with no acknowledged advisory.'; }
  _case "an empty ledger says nothing is acknowledged" 0 _none "${tmp}/none.toml"

  printf '[[IgnoredVulns]]\nid = "RUSTSEC-2026-0459"\nignoreUntil = 2027-02-09T00:00:00Z\n' >"${tmp}/noexpiry.toml"
  _case "an entry without effectiveUntil fails" 1 notes "${tmp}/noexpiry.toml"

  printf '[[IgnoredVulns]]\neffectiveUntil = 2027-02-09T00:00:00Z\nreason = "x"\n' >"${tmp}/noid.toml"
  _case "an entry without an id fails" 1 notes "${tmp}/noid.toml"

  printf '[[IgnoredVulns]]\nid = "RUSTSEC-1](https://example.invalid)"\neffectiveUntil = 2027-02-09T00:00:00Z\n' >"${tmp}/md.toml"
  _case "an id that is not advisory-shaped fails (no markdown into the Release)" 1 notes "${tmp}/md.toml"

  printf 'IgnoredVulns = [ { id = "RUSTSEC-2026-0459", effectiveUntil = 2027-02-09T00:00:00Z } ]\n' >"${tmp}/inline.toml"
  _case "an inline IgnoredVulns array is a misconfiguration, never an empty list" 2 notes "${tmp}/inline.toml"

  _case "a missing ledger is a misconfiguration" 2 notes "${tmp}/absent.toml"

  if (( checked != SELF_TEST_FIXTURES )); then
    printf '  \033[1;31mFAIL\033[0m ran %d fixtures, expected %d\n' "${checked}" "${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  (( fails == 0 )) || { echo "release_ledger_notes.sh --self-test: FAILED" >&2; return 1; }
  log "OK: self-test passed — listing, an empty ledger, a missing id or expiry, a non-advisory id, an unreadable spelling and a missing ledger."
}

case "${1:-}" in
  --self-test) self_test ;;
  -*|'') echo "ERROR: expected <osv-scanner.toml> or --self-test" >&2; exit 2 ;;
  *) notes "$1" ;;
esac
