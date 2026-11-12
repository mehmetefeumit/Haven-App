#!/usr/bin/env bash
# CI gate: no committed lockfile resolves a known-vulnerable or malicious
# package, except as the acknowledgement ledger allows.
#
# cargo-audit reads RustSec alone and skips every package that is not from
# crates.io, so MDK, the OpenMLS fork and the SQLCipher build of libsqlite3-sys
# are invisible to it, and it reads no pubspec.lock or Gemfile.lock at all.
# osv-scanner matches by name and version whatever the source, over OSV's union
# of RustSec, GitHub-reviewed advisories and the OpenSSF malicious-packages
# feed, for all three ecosystems; RUSTSEC-2026-0459 (the SQLite SQLCipher
# bundles) is the finding cargo-audit could not make.
#
# It always runs `--offline` against databases it downloads whole: the online
# mode posts every package name and version (`rust_lib_haven` among them) to
# osv.dev, and a scan's answer must not depend on a query service. It fetches
# each ecosystem's database itself, once per run into a cache of its own, and
# both passes read that one snapshot. osv-scanner that cannot load one
# ecosystem's database logs it and still exits 1 on the other ecosystems'
# findings, so a package it never checked would pass: a database-load or
# extraction error on its stderr, or a reported ecosystem with no database in
# the cache, is a misconfiguration. The ledger,
# osv-scanner.toml at the repository root, is the only config: osv-scanner
# drops an acknowledged advisory with all its aliases until its
# `effectiveUntil`, and check_ledger.sh holds the ledger's own rules.
#
# The verdict, over what osv-scanner reports once the ledger is applied:
#   - a MAL-* record fails, always, even acknowledged: it is read from a second
#     pass with no ledger applied;
#   - a RustSec record every affected entry of which is informational
#     (unmaintained, unsound, notice) is printed as a warning, as cargo-audit
#     treats it; GitHub has no such category, so a GHSA record fails even when
#     it aliases an informational RustSec one (acknowledging either id clears
#     both);
#   - anything else fails.
# And every committed lockfile under the root (git's view of it, or every
# `*.lock` file when the root is not a checkout, such as a release tag's
# lockfiles laid out by the nightly) must have contributed at least one package:
# osv-scanner says nothing about a file it did not parse. A committed `*.lock`
# osv-scanner does not recognise by name is a misconfiguration, so a lockfile
# cannot opt out of the scan by its name.
#
# Usage:
#   bash scripts/ci/run_osv_gate.sh [--unfiltered-json <out>] [<root>]
#       <root> defaults to the repository root. --unfiltered-json keeps the
#       pass with NO acknowledgement applied, which check_ledger.sh needs to
#       prove every entry still matches something.
#   bash scripts/ci/run_osv_gate.sh --binary-self-test
#       the installed osv-scanner against its downloaded database: an expired
#       acknowledgement stops suppressing, a live one suppresses, a
#       git-sourced package is matched, and a database it cannot load is
#       caught (audit.yml; the advisory data is live, so a withdrawn
#       RUSTSEC-2026-0459 or an un-flagged rack 2.0.0 reddens it and must be
#       swapped out).
#   bash scripts/ci/run_osv_gate.sh --self-test     # recorded output, no tool
#
# SECURITY_FINDINGS_OUT, when set, gets one `osv:<ID>:<pkg>@<ver>\t<summary>`
# line per failing advisory.
#
# Exit codes:
#   0  nothing beyond informational warnings (or a self-test passed)
#   1  a vulnerable or malicious package (or a self-test failed)
#   2  misconfiguration: osv-scanner exited other than 0/1, its output is not a
#      scan report, an advisory database did not download or load, a
#      committed lockfile contributed nothing or has a name osv-scanner does
#      not parse, or a missing argument or tool

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly LEDGER_REL='osv-scanner.toml'
readonly FIXTURES_REL='scripts/ci/fixtures/dependency-security'
readonly LOCKFILE_NAMES='Cargo.lock pubspec.lock Gemfile.lock'
readonly OSV_DB_HOST='https://osv-vulnerabilities.storage.googleapis.com'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=15

log() {
  printf '\033[1;34m[run_osv_gate]\033[0m %s\n' "$*"
}

finding() { # <key> <summary>
  [[ -n "${SECURITY_FINDINGS_OUT:-}" ]] || return 0
  printf '%s\t%s\n' "$1" "$2" >>"${SECURITY_FINDINGS_OUT}"
}

# Root-relative committed lockfiles, one per line; rc 2 on an unknown name.
lockfiles() { # <absolute root>
  local root="$1" rel base
  local -a all=()
  if [[ "$(git -C "${root}" rev-parse --show-toplevel 2>/dev/null)" == "${root}" ]]; then
    mapfile -t all < <(git -C "${root}" ls-files -co --exclude-standard -- '*.lock')
  else
    mapfile -t all < <(cd "${root}" && find . -type f -name '*.lock' | sed 's|^\./||')
  fi
  for rel in "${all[@]}"; do
    [[ -f "${root}/${rel}" ]] || continue
    base="${rel##*/}"
    [[ " ${LOCKFILE_NAMES} " == *" ${base} "* ]] \
      || { echo "ERROR: ${rel} is a lockfile osv-scanner does not recognise by name (it parses ${LOCKFILE_NAMES}). Commit it under its ecosystem's own name, in a directory of its own." >&2; return 2; }
    printf '%s\n' "${rel}"
  done | sort
}

# The OSV ecosystem whose database a lockfile is checked against.
ecosystem_of() { # <lockfile path>
  case "${1##*/}" in
    Cargo.lock) echo crates.io ;;
    pubspec.lock) echo Pub ;;
    Gemfile.lock) echo RubyGems ;;
  esac
}

# Downloads each ecosystem's whole database to the layout osv-scanner reads
# from OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY; osv-scanner's own download has no
# retry and no timeout.
fetch_dbs() { # <cache> <ecosystem>...
  local cache="$1" eco; shift
  for eco in "$@"; do
    mkdir -p "${cache}/osv-scalibr/${eco}"
    curl -fsS --connect-timeout 10 --max-time 60 --retry 3 --retry-all-errors \
      -o "${cache}/osv-scalibr/${eco}/all.zip" "${OSV_DB_HOST}/${eco}/all.zip" \
      || { echo "ERROR: could not download the ${eco} advisory database" >&2; return 2; }
  done
}

osv_scan() { # <cache> <stderr out> <osv-scanner scan source arguments>...
  local cache="$1" err="$2"; shift 2
  OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="${cache}" osv-scanner scan source --offline "$@" 2>"${err}"
}

# rc 2 unless osv-scanner checked every package it reported against a
# database: it exits 0/1 whether or not an ecosystem's database loaded.
dbs_loaded() { # <stderr> <report.json> <cache>
  local err="$1" report="$2" cache="$3" ecos eco
  local -a missing=()
  if grep -E 'could not load db for|Error during extraction' "${err}" >&2; then
    echo "ERROR: osv-scanner could not load an advisory database or read a lockfile; the packages it did not check would pass unscanned" >&2
    return 2
  fi
  ecos="$(jq -r '[.results[].packages[].package.ecosystem | sub(":.*"; "")] | unique[]' "${report}")" \
    || { echo "ERROR: ${report} is not an osv-scanner JSON report" >&2; return 2; }
  while read -r eco; do
    [[ -z "${eco}" || -s "${cache}/osv-scalibr/${eco}/all.zip" ]] || missing+=("${eco}")
  done <<<"${ecos}"
  (( ${#missing[@]} == 0 )) \
    || { echo "ERROR: osv-scanner reported ${missing[*]} packages, and no ${missing[*]} advisory database was fetched: a lockfile of an ecosystem this gate does not download" >&2; return 2; }
}

# evaluate <osv rc> <report.json> <unfiltered.json> <absolute root> <lockfile list file>
evaluate() {
  local rc="$1" report="$2" unfiltered="$3" root="$4" list="$5" rel n f
  [[ "${rc}" == 0 || "${rc}" == 1 ]] \
    || { echo "ERROR: osv-scanner exited ${rc} (127 error, 128 no packages, 129 API, 130 bad config) — not a verdict" >&2; return 2; }
  for f in "${report}" "${unfiltered}"; do
    jq -e '(.results | type) == "array"' "${f}" >/dev/null 2>&1 \
      || { echo "ERROR: ${f} is not an osv-scanner JSON report" >&2; return 2; }
  done
  [[ -s "${list}" ]] || { echo "ERROR: no committed lockfile under ${root}" >&2; return 2; }

  local -a silent=()
  while read -r rel; do
    n="$(jq --arg p "${root}/${rel}" '[.results[] | select(.source.path == $p) | .packages[]] | length' "${report}")"
    (( n > 0 )) || silent+=("${rel}")
  done <"${list}"
  if (( ${#silent[@]} > 0 )); then
    printf '  %s contributed no package to the scan\n' "${silent[@]}" >&2
    echo "ERROR: osv-scanner skipped a committed lockfile; a lockfile it did not read is a lockfile nobody scanned." >&2
    return 2
  fi

  # <verdict> <id> <pkg> <version> <lockfile> <informational kinds> <summary>,
  # separated by US (\037): a tab is IFS whitespace, so `read` would merge the
  # empty kinds field into the next.
  # MAL-* records are read from the scan with no acknowledgement applied: an
  # entry for a GHSA id that a malware record aliases would otherwise drop it.
  local rows
  rows="$(jq -r --arg root "${root}/" --argjson mal "$(jq '[.results[] as $r | $r.packages[] as $p
      | ($p.vulnerabilities // [])[] | select(.id | startswith("MAL-")) | {path: $r.source.path, package: $p.package, vuln: .}]' "${unfiltered}")" '
    def row($v; $lock; $p; $info): [$v, .id, $p.name, $p.version, $lock, ($info | map(select(. != null)) | unique | join(",")),
      ((.summary // "") | gsub("[\t\n\u001f]"; " "))] | join("\u001f");
    (.results[] | (.source.path | ltrimstr($root)) as $lock
      | .packages[] | .package as $p
      | (.vulnerabilities // [])[]
      | [.affected[]? | .database_specific.informational] as $info
      | (if (.id | startswith("RUSTSEC-")) and ($info | length) > 0 and all($info[]; . != null) then "warn" else "fail" end) as $v
      | row($v; $lock; $p; $info)),
    ($mal[] | .package as $p | (.path | ltrimstr($root)) as $lock | .vuln | row("fail"; $lock; $p; []))
  ' "${report}")"

  local verdict id pkg ver lock info summary failed=0
  while IFS=$'\037' read -r verdict id pkg ver lock info summary; do
    [[ -n "${verdict}" ]] || continue
    if [[ "${verdict}" == warn ]]; then
      printf 'warning: %s (%s) %s %s in %s: %s\n' "${id}" "${info}" "${pkg}" "${ver}" "${lock}" "${summary}"
    else
      printf '\033[1;31m  %s\033[0m %s %s in %s: %s\n' "${id}" "${pkg}" "${ver}" "${lock}" "${summary}" >&2
      failed=1
    fi
  done <<<"${rows}"

  if (( failed )); then
    awk -F'\037' '$1 == "fail" { print "osv:" $2 ":" $3 "@" $4 "\t" $3 " " $4 ": " $7 }' <<<"${rows}" | sort -u \
      | while IFS=$'\t' read -r key summary; do finding "${key}" "${summary}"; done
    printf '\033[1;31m[run_osv_gate] FAIL:\033[0m a committed lockfile resolves an advisory above. Update the lockfile; only a reasoned, owner-decided, expiring entry in %s may acknowledge one with no fix.\n' "${LEDGER_REL}" >&2
    return 1
  fi
  log "OK: $(grep -c . "${list}") committed lockfile(s) scanned; nothing beyond informational warnings."
}

run_check() { # [--unfiltered-json <out>] [<root>]
  local unfiltered='' root="${REPO_ROOT}"
  while (( $# )); do
    case "$1" in
      --unfiltered-json) unfiltered="${2:?--unfiltered-json needs a path}"; shift 2 ;;
      *) root="$1"; shift ;;
    esac
  done
  command -v osv-scanner >/dev/null || { echo "ERROR: osv-scanner not on PATH (scripts/ci/security_tools.env pins it)" >&2; return 2; }
  [[ -f "${REPO_ROOT}/${LEDGER_REL}" ]] || { echo "ERROR: ${LEDGER_REL} not found" >&2; return 2; }
  root="$(cd "${root}" && pwd -P)"
  local tmp rc=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  lockfiles "${root}" >"${tmp}/lockfiles" || return 2
  local -a ecos=()
  mapfile -t ecos < <(while read -r rel; do ecosystem_of "${rel}"; done <"${tmp}/lockfiles" | sort -u)
  fetch_dbs "${tmp}/db" "${ecos[@]}" || return 2
  osv_scan "${tmp}/db" "${tmp}/report.err" --config "${REPO_ROOT}/${LEDGER_REL}" \
    --format json --all-packages -r "${root}" >"${tmp}/report.json" || rc=$?
  # An explicit empty config, or osv-scanner would find the ledger itself.
  : >"${tmp}/none.toml"
  local urc=0
  osv_scan "${tmp}/db" "${tmp}/unfiltered.err" --config "${tmp}/none.toml" \
    --format json -r "${root}" >"${tmp}/unfiltered.json" || urc=$?
  [[ "${urc}" == 0 || "${urc}" == 1 ]] || { cat "${tmp}/unfiltered.err" >&2; echo "ERROR: the unacknowledged osv-scanner pass exited ${urc}" >&2; return 2; }
  [[ "${rc}" == 0 || "${rc}" == 1 ]] || cat "${tmp}/report.err" >&2
  # The ledger pass lists every package (--all-packages), so its ecosystems
  # are every ecosystem scanned.
  if [[ "${rc}" == 0 || "${rc}" == 1 ]]; then
    dbs_loaded "${tmp}/report.err" "${tmp}/report.json" "${tmp}/db" || return 2
    dbs_loaded "${tmp}/unfiltered.err" "${tmp}/report.json" "${tmp}/db" || return 2
  fi
  [[ -z "${unfiltered}" ]] || cp "${tmp}/unfiltered.json" "${unfiltered}"
  evaluate "${rc}" "${tmp}/report.json" "${tmp}/unfiltered.json" "${root}" "${tmp}/lockfiles"
}

# ---------------------------------------------------------------------------
# The installed binary, against its live database.
# ---------------------------------------------------------------------------
binary_self_test() {
  command -v osv-scanner >/dev/null || { echo "ERROR: osv-scanner not on PATH" >&2; return 2; }
  local tmp lock="${REPO_ROOT}/${FIXTURES_REL}/git-sourced.Cargo.lock.txt" fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  fetch_dbs "${tmp}/db" crates.io RubyGems || return 2
  _scan() { # <effectiveUntil> -> the advisory ids reported for the fixture
    printf '[[IgnoredVulns]]\nid = "RUSTSEC-2026-0459"\neffectiveUntil = %s\nreason = "owner-decision: 2026-11-12. fixture"\n' "$1" >"${tmp}/ledger.toml"
    local rc=0
    osv_scan "${tmp}/db" "${tmp}/err" --config "${tmp}/ledger.toml" \
      --format json -L "Cargo.lock:${lock}" >"${tmp}/out.json" || rc=$?
    [[ "${rc}" == 0 || "${rc}" == 1 ]] || { cat "${tmp}/err" >&2; echo "ERROR: osv-scanner exited ${rc}" >&2; return 2; }
    jq -r '[.results[].packages[].vulnerabilities[]?.id] | unique | join(" ")' "${tmp}/out.json"
  }
  local expired live
  expired="$(_scan 2020-01-01T00:00:00Z)" || return 2
  live="$(_scan 2099-01-01T00:00:00Z)" || return 2
  if [[ " ${expired} " == *' RUSTSEC-2026-0459 '* ]]; then
    printf '  \033[1;32mPASS\033[0m an expired acknowledgement stops suppressing, and the git-sourced libsqlite3-sys is matched\n'
  else
    printf '  \033[1;31mFAIL\033[0m expired acknowledgement: reported [%s], want RUSTSEC-2026-0459\n' "${expired}" >&2
    fails=1
  fi
  if [[ -z "${live}" ]]; then
    printf '  \033[1;32mPASS\033[0m an acknowledgement in effect suppresses the advisory and its aliases\n'
  else
    printf '  \033[1;31mFAIL\033[0m acknowledgement in effect: still reported [%s]\n' "${live}" >&2
    fails=1
  fi

  # rack 2.0.0 has had published advisories since 2019. With its database it
  # is reported; without it osv-scanner still exits 1 on the crate's finding.
  mkdir -p "${tmp}/tree" "${tmp}/cargo-only/osv-scalibr"
  cp "${lock}" "${tmp}/tree/Cargo.lock"
  printf 'GEM\n  remote: https://rubygems.org/\n  specs:\n    rack (2.0.0)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  rack\n' >"${tmp}/tree/Gemfile.lock"
  cp -R "${tmp}/db/osv-scalibr/crates.io" "${tmp}/cargo-only/osv-scalibr/"
  : >"${tmp}/none.toml"
  local rc=0 gems
  osv_scan "${tmp}/db" "${tmp}/err" --config "${tmp}/none.toml" --format json --all-packages -r "${tmp}/tree" >"${tmp}/out.json" || rc=$?
  gems="$(jq '[.results[].packages[] | select(.package.ecosystem == "RubyGems") | .vulnerabilities[]?] | length' "${tmp}/out.json" 2>/dev/null || echo 0)"
  if [[ "${rc}" == 1 ]] && (( gems > 0 )) && dbs_loaded "${tmp}/err" "${tmp}/out.json" "${tmp}/db" 2>/dev/null; then
    printf '  \033[1;32mPASS\033[0m a locked gem is checked against the RubyGems database\n'
  else
    printf '  \033[1;31mFAIL\033[0m rack 2.0.0 with its database: rc %s, %s advisories, want rc 1 and at least one\n' "${rc}" "${gems}" >&2
    fails=1
  fi
  rc=0
  osv_scan "${tmp}/cargo-only" "${tmp}/err" --config "${tmp}/none.toml" --format json --all-packages -r "${tmp}/tree" >"${tmp}/out.json" || rc=$?
  local drc=0
  dbs_loaded "${tmp}/err" "${tmp}/out.json" "${tmp}/cargo-only" 2>/dev/null || drc=$?
  if [[ "${rc}" == 1 && "${drc}" == 2 ]]; then
    printf '  \033[1;32mPASS\033[0m a database osv-scanner could not load is a misconfiguration, though it exits 1 on the other findings\n'
  else
    printf '  \033[1;31mFAIL\033[0m rack 2.0.0 without its database: osv-scanner rc %s (want 1), gate rc %s (want 2)\n' "${rc}" "${drc}" >&2
    fails=1
  fi
  (( fails == 0 )) || { echo "binary self-test: FAILED — the pinned osv-scanner does not behave as run_osv_gate.sh assumes" >&2; return 1; }
  echo "binary self-test: OK ($(osv-scanner --version | head -1))"
}

# ---------------------------------------------------------------------------
# Self-test. The reports are real osv-scanner v2.7.1 JSON (offline database of
# 2026-11-12, run over this repository) cut down to the fields read here, with
# the checkout path replaced by /ROOT.
# ---------------------------------------------------------------------------
self_test() {
  local fx="${REPO_ROOT}/${FIXTURES_REL}" tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local base="${fx}/osv-ledger-applied.json" extra="${fx}/osv-unacknowledged.json"
  printf 'haven-core/Cargo.lock\nhaven/pubspec.lock\ntooling/soak/Cargo.lock\n' >"${tmp}/locks"

  _found() { # <needle lines> — each line in the output or the findings
    local n
    while IFS= read -r n; do grep -qF -- "${n}" "${tmp}/out" "${tmp}/findings" || return 1; done <<<"$1"
  }
  _case() { # <label> <want-rc> <needle lines|-> <cmd>...
    local label="$1" want="$2" needle="$3" got=0; shift 3
    checked=$(( checked + 1 ))
    : >"${tmp}/findings"
    ( SECURITY_FINDINGS_OUT="${tmp}/findings" "$@" ) >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]] && { [[ "${needle}" == - ]] || _found "${needle}"; }; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d%s)\n' "${label}" "${want}" "${got}" "$([[ "${needle}" == - ]] || printf ', want output containing %q' "${needle}")" >&2
      sed 's/^/      /' "${tmp}/out" >&2
      fails=1
    fi
  }
  _with() { # <jq-filter> -> a variant of the base report
    jq --slurpfile x "${extra}" "$1" "${base}"
  }

  echo "run_osv_gate.sh --self-test"
  # osv-scanner exits 1 on informational records too; they pass, filing nothing.
  _quiet() { evaluate "$@" && ! grep -q . "${SECURITY_FINDINGS_OUT}"; }
  _case "informational RustSec findings pass as warnings and file no finding" 0 \
    'warning: RUSTSEC-2026-0237 (unmaintained) nostr-relay-builder 0.44.1 in haven-core/Cargo.lock' \
    _quiet 1 "${base}" "${base}" /ROOT "${tmp}/locks"

  _with '.results[0].packages += [$x[0].vulnerable]' >"${tmp}/vuln.json"
  _case "an unacknowledged vulnerability in a git-sourced package fails and files its finding" 1 \
    "$(printf 'osv:RUSTSEC-2026-0459:libsqlite3-sys@0.38.1\tlibsqlite3-sys 0.38.1: `libsqlite3-sys` via C SQLite\nlibsqlite3-sys 0.38.1 in haven-core/Cargo.lock: `libsqlite3-sys` via C SQLite')" \
    evaluate 1 "${tmp}/vuln.json" "${tmp}/vuln.json" /ROOT "${tmp}/locks"

  # Only RustSec marks a record informational; a GHSA alias of one is GitHub
  # calling it a vulnerability, even were it to copy the field.
  _with '.results[0].packages += [$x[0].ghsa_only | .vulnerabilities[0].affected[].database_specific.informational = "unsound"]' >"${tmp}/ghsa.json"
  _case "a GHSA record fails even when it aliases, or copies, an informational RustSec advisory" 1 \
    'osv:GHSA-cq8v-f236-94qc:rand@0.8.5' evaluate 1 "${tmp}/ghsa.json" "${tmp}/ghsa.json" /ROOT "${tmp}/locks"

  _with '.results[1].packages[0] += {vulnerabilities: [{id: "MAL-2026-0001", summary: "Malicious code in args (pub)",
      affected: [{package: {ecosystem: "Pub", name: "args"}, database_specific: {informational: "notice"}}]}]}' >"${tmp}/mal.json"
  _case "a MAL record fails even when acknowledged away and marked informational" 1 'osv:MAL-2026-0001:args@2.7.0' \
    evaluate 1 "${base}" "${tmp}/mal.json" /ROOT "${tmp}/locks"

  jq '.results[0].packages[1].vulnerabilities[0].affected += [{package: {ecosystem: "crates.io", name: "lru"}, database_specific: {informational: null}}]' \
    "${base}" >"${tmp}/mixed.json"
  _case "a RustSec record with one non-informational affected entry fails" 1 'osv:RUSTSEC-2026-0253:lru@0.16.4' \
    evaluate 1 "${tmp}/mixed.json" "${tmp}/mixed.json" /ROOT "${tmp}/locks"

  printf 'haven-core/Cargo.lock\nhaven/pubspec.lock\nhaven/ios/Gemfile.lock\ntooling/soak/Cargo.lock\n' >"${tmp}/locks+"
  _case "a committed lockfile osv-scanner did not report is a misconfiguration" 2 'haven/ios/Gemfile.lock contributed no package' \
    evaluate 0 "${base}" "${base}" /ROOT "${tmp}/locks+"

  _case "an osv-scanner exit other than 0/1 is a misconfiguration" 2 'exited 128' \
    evaluate 128 "${base}" "${base}" /ROOT "${tmp}/locks"

  printf 'Error: unable to load database\n' >"${tmp}/garbage.json"
  _case "a pass whose output is not a JSON report is a misconfiguration" 2 'not an osv-scanner JSON report' \
    evaluate 1 "${base}" "${tmp}/garbage.json" /ROOT "${tmp}/locks"

  # The committed set outside a checkout: every *.lock, and only known names.
  mkdir -p "${tmp}/tree/a" "${tmp}/tree/b/c"
  : >"${tmp}/tree/a/Cargo.lock"; : >"${tmp}/tree/b/c/pubspec.lock"; : >"${tmp}/tree/b/Cargo.lock.txt"
  _lists() { [[ "$(lockfiles "$1" | tr '\n' ' ')" == "$2" ]]; }
  _case "the lockfiles of a tree that is not a checkout are its *.lock files" 0 - \
    _lists "${tmp}/tree" 'a/Cargo.lock b/c/pubspec.lock '

  : >"${tmp}/tree/b/build_tool_runner.lock"
  _case "a lockfile osv-scanner cannot recognise by name is a misconfiguration" 2 'build_tool_runner.lock' \
    lockfiles "${tmp}/tree"

  # The whole run, with osv-scanner and curl replaced: the download, the
  # database-load check and the verdict wired together.
  mkdir -p "${tmp}/bin" "${tmp}/repo/haven-core" "${tmp}/repo/haven" "${tmp}/repo/tooling/soak"
  : >"${tmp}/repo/haven-core/Cargo.lock"; : >"${tmp}/repo/haven/pubspec.lock"; : >"${tmp}/repo/tooling/soak/Cargo.lock"
  cat >"${tmp}/bin/osv-scanner" <<'FAKE'
#!/usr/bin/env bash
sed "s|/ROOT|${FAKE_ROOT}|g" "${FAKE_REPORT}"
pass=unfiltered; [[ " $* " != *' --all-packages '* ]] || pass=ledger
[[ "${pass}" != "${FAKE_STDERR_PASS:-}" ]] || printf 'could not load db for Pub ecosystem: unable to fetch OSV database\n' >&2
exit 1
FAKE
  cat >"${tmp}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
[[ -z "${FAKE_CURL_FAIL:-}" ]] || exit 22
while (( $# )); do [[ "$1" != -o ]] || { printf 'zip' >"$2"; exit 0; }; shift; done
exit 2
FAKE
  chmod +x "${tmp}/bin/osv-scanner" "${tmp}/bin/curl"
  _run() { # <report> [<NAME=value> for the fakes]... -> run_check over the fake repository
    local report="$1"; shift
    # shellcheck disable=SC2163 # NAME=value pairs, exported as given
    (( $# == 0 )) || export "$@"
    PATH="${tmp}/bin:${PATH}" FAKE_ROOT="$(cd "${tmp}/repo" && pwd -P)" FAKE_REPORT="${report}" run_check "${tmp}/repo"
  }
  _case "a run whose databases all downloaded and loaded reaches the verdict" 0 'OK: 3 committed lockfile(s) scanned' \
    _run "${base}"

  _case "a database the ledger pass could not load fails, though osv-scanner exited 1 on the other findings" 2 'could not load db for Pub ecosystem' \
    _run "${base}" FAKE_STDERR_PASS=ledger
  _case "a database the unacknowledged pass could not load fails too" 2 'could not load db for Pub ecosystem' \
    _run "${base}" FAKE_STDERR_PASS=unfiltered

  _with '.results += [{source: {path: "/ROOT/haven/ios/Gemfile.lock"}, packages: [{package: {name: "rack", version: "2.0.0", ecosystem: "RubyGems"}}]}]' >"${tmp}/gem.json"
  _case "a reported ecosystem with no database fetched is a misconfiguration" 2 'no RubyGems advisory database was fetched' \
    _run "${tmp}/gem.json"

  _case "a database that does not download is a misconfiguration" 2 'could not download the' \
    _run "${base}" FAKE_CURL_FAIL=1

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
  --binary-self-test) binary_self_test ;;
  *) run_check "$@" ;;
esac
