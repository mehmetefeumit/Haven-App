#!/usr/bin/env bash
# CI guard: every cargo-audit ignore still matches an advisory.
#
# cargo-audit says nothing about an ignore that matches no advisory. A stale
# ignore is therefore a standing false green, the kind this repo already refuses
# for skips (check_no_undeclared_skips.sh) and for floors (a stale row in
# check_coverage_floors.sh): it documents a risk that no longer exists, and it
# pre-authorises the advisory's return — the next graph that resolves the
# vulnerable crate again is silenced by a justification written for a different
# graph. The MDK bump is expected to clear the libcrux block in
# haven-core/.cargo/audit.toml; this is what proves it did rather than assuming
# it.
#
# Every lockfile audit.yml audits (haven-core's, plus each `--file` there) is
# audited again WITHOUT the ignore list — from an empty directory, so no
# `.cargo/audit.toml` applies, and each report must say it applied none — and
# every ID in haven-core/.cargo/audit.toml must appear as the `advisory.id` of a
# vulnerability or an informational warning in at least one of those reports.
# An ID that is only another advisory's alias does not count.
#
# The advisory database is fetched live, so a WITHDRAWN advisory can redden
# this on a day nobody chose; the message names the ID and the fix is to delete
# it. The audit steps above it in audit.yml carry the same exposure.
#
# Usage:
#   bash scripts/ci/check_audit_ignores_live.sh [-- <extra cargo-audit args>]
#   bash scripts/ci/check_audit_ignores_live.sh --self-test   # no cargo-audit
#
# Exit codes:
#   0  every ignore is live (or the self-test passed)
#   1  an ignore matches no advisory (or the self-test failed)
#   2  misconfiguration: no ignore IDs, a malformed ID, a report that is not
#      cargo-audit JSON or was filtered, or no lockfile derived from audit.yml

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly AUDIT_TOML_REL='haven-core/.cargo/audit.toml'
readonly WORKFLOW_REL='.github/workflows/audit.yml'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=10

log() {
  printf '\033[1;34m[check_audit_ignores_live]\033[0m %s\n' "$*"
}

# The entries of the `ignore = [...]` array, comments stripped.
ignored_ids() { # <audit.toml>
  awk '
    { sub(/#.*/, "") }
    !inarr && /^[[:space:]]*ignore[[:space:]]*=[[:space:]]*\[/ { inarr = 1; sub(/^[^[]*\[/, "") }
    inarr {
      line = $0
      if (line ~ /\]/) { sub(/\].*/, "", line); inarr = 0 }
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) { v = parts[i]; gsub(/[[:space:]"]/, "", v); if (v != "") print v }
    }
  ' "$1"
}

# Repo-relative lockfiles audit.yml audits: haven-core's (its bare
# `cargo audit`) and every `--file ../<path>` (relative to haven-core).
audited_lockfiles() { # <repo-root>
  local wf="$1/${WORKFLOW_REL}"
  [[ -f "${wf}" ]] || return 0
  grep -qE '^[[:space:]]*run: cargo audit$' "${wf}" && echo 'haven-core/Cargo.lock'
  grep -oE 'cargo audit --file \.\./[^[:space:]]+' "${wf}" | sed 's|^cargo audit --file \.\./||'
}

# compare <audit.toml> <report.json>... — the check itself, over reports.
compare() {
  local toml="$1" report id; shift
  [[ -f "${toml}" ]] || { echo "ERROR: ${toml} not found" >&2; return 2; }
  local ids; ids="$(ignored_ids "${toml}")"
  [[ -n "${ids}" ]] || { echo "ERROR: no ignore IDs parsed from ${toml} — parser rot, or every ignore was removed (then retire this step)" >&2; return 2; }
  while read -r id; do
    [[ "${id}" =~ ^RUSTSEC-[0-9]{4}-[0-9]{4}$ ]] \
      || { echo "ERROR: '${id}' in ${toml} is not a RUSTSEC id" >&2; return 2; }
  done <<<"${ids}"

  local seen=''
  for report in "$@"; do
    jq -e 'has("vulnerabilities") and has("warnings") and (.settings.ignore | length) == 0' "${report}" >/dev/null 2>&1 \
      || { echo "ERROR: ${report} is not an unfiltered cargo-audit --json report" >&2; return 2; }
    seen+="$(jq -r '(.vulnerabilities.list[].advisory.id), (.warnings[][] | .advisory.id? // empty)' "${report}")"$'\n'
  done

  local -a stale=()
  while read -r id; do
    grep -qxF -- "${id}" <<<"${seen}" || stale+=("${id}")
  done <<<"${ids}"
  if (( ${#stale[@]} > 0 )); then
    printf '  %s matches no advisory in any audited lockfile\n' "${stale[@]}" >&2
    printf '\033[1;31m[check_audit_ignores_live] FAIL:\033[0m a stale ignore silences nothing today and would silence the advisory if it came back. Delete it, with its justification, from %s.\n' "${AUDIT_TOML_REL}" >&2
    return 1
  fi
  log "OK: all $(grep -c . <<<"${ids}") ignore(s) in ${AUDIT_TOML_REL} match a live advisory in $# unfiltered report(s)."
}

run_check() {
  local tmp rel n=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local -a reports=()
  while read -r rel; do
    [[ -n "${rel}" ]] || continue
    [[ -f "${REPO_ROOT}/${rel}" ]] || { echo "ERROR: ${REPO_ROOT}/${rel} (named by ${WORKFLOW_REL}) not found" >&2; return 2; }
    n=$(( n + 1 ))
    # From an empty directory: cargo-audit reads `.cargo/audit.toml` relative
    # to where it runs. Its exit code only says whether it found something.
    (cd "${tmp}" && cargo audit --json --file "${REPO_ROOT}/${rel}" "$@") >"${tmp}/${n}.json" || true
    reports+=("${tmp}/${n}.json")
  done < <(audited_lockfiles "${REPO_ROOT}")
  (( n > 0 )) || { echo "ERROR: derived no lockfile from ${WORKFLOW_REL}" >&2; return 2; }
  compare "${REPO_ROOT}/${AUDIT_TOML_REL}" "${reports[@]}"
}

# ---------------------------------------------------------------------------
# Self-test. The reports are real `cargo audit --json` output (0.22.1, advisory
# DB of 2026-09-19) cut down to the fields read here, so the extractor is proven
# against the shape cargo-audit writes rather than one it was written against.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # haven-core's lockfile: one vulnerability (carrying an alias and a related
  # id), one unmaintained warning, and a yanked warning, whose advisory is null.
  cat >"${tmp}/core.json" <<'EOF'
{"settings":{"target_arch":[],"target_os":[],"severity":null,"ignore":[],"informational_warnings":["unmaintained","unsound","notice"]},
 "vulnerabilities":{"found":true,"count":1,"list":[
  {"advisory":{"id":"RUSTSEC-2026-0209","package":"libcrux-aesgcm","aliases":["GHSA-0000-0000-0001"],"related":["RUSTSEC-2026-0999"]},"package":{"name":"libcrux-aesgcm","version":"0.0.7"}}]},
 "warnings":{
  "unmaintained":[{"kind":"unmaintained","package":{"name":"instant","version":"0.1.13"},"advisory":{"id":"RUSTSEC-2024-0384","package":"instant","aliases":[],"related":[]}}],
  "yanked":[{"kind":"yanked","package":{"name":"async-utility","version":"0.3.1"},"advisory":null}]}}
EOF
  # rust_builder's lockfile: the one unsound warning only it resolves.
  cat >"${tmp}/builder.json" <<'EOF'
{"settings":{"target_arch":[],"target_os":[],"severity":null,"ignore":[],"informational_warnings":["unmaintained","unsound","notice"]},
 "vulnerabilities":{"found":false,"count":0,"list":[]},
 "warnings":{"unsound":[{"kind":"unsound","package":{"name":"rand","version":"0.8.5"},"advisory":{"id":"RUSTSEC-2026-0097","package":"rand","aliases":[],"related":[]}}]}}
EOF
  _toml() { # <file> <line>...
    local f="$1"; shift
    { printf '# policy\n[advisories]\nignore = [\n'; printf '  %s\n' "$@"; printf ']\n'; } >"${f}"
  }
  _case() { # _case <label> <want-rc> <toml> <report>...
    local label="$1" want="$2" got=0; shift 2
    checked=$(( checked + 1 ))
    ( compare "$@" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  echo "check_audit_ignores_live.sh --self-test"
  local LIVE=('"RUSTSEC-2024-0384",  # unmaintained' '"RUSTSEC-2026-0097",  # unsound, rust_builder only' '"RUSTSEC-2026-0209",  # a vulnerability')

  _toml "${tmp}/live.toml" "${LIVE[@]}"
  _case "ignores matched across the reports' union (vulnerability, unmaintained, unsound) pass" 0 \
    "${tmp}/live.toml" "${tmp}/core.json" "${tmp}/builder.json"

  _toml "${tmp}/stale.toml" "${LIVE[@]}" '"RUSTSEC-2026-0073",  # cleared by the bump'
  _case "an ignore matching no advisory fails" 1 "${tmp}/stale.toml" "${tmp}/core.json" "${tmp}/builder.json"

  _case "an ignore matched only by a report left out of the union fails" 1 "${tmp}/live.toml" "${tmp}/core.json"

  _toml "${tmp}/alias.toml" "${LIVE[@]}" '"RUSTSEC-2026-0999",  # only ever named as a related id'
  _case "an id that is only another advisory's related/alias entry fails" 1 \
    "${tmp}/alias.toml" "${tmp}/core.json" "${tmp}/builder.json"

  _toml "${tmp}/commented.toml" "${LIVE[@]}" '# "RUSTSEC-2026-0073",  lifted'
  _case "a commented-out ignore is not an ignore" 0 "${tmp}/commented.toml" "${tmp}/core.json" "${tmp}/builder.json"

  jq '.settings.ignore = ["RUSTSEC-2026-0209"]' "${tmp}/core.json" >"${tmp}/filtered.json"
  _case "a report cargo-audit filtered through an ignore list is a misconfiguration" 2 \
    "${tmp}/live.toml" "${tmp}/filtered.json" "${tmp}/builder.json"

  printf 'error: couldn'\''t fetch advisory database\n' >"${tmp}/garbage.json"
  _case "a report that is not cargo-audit JSON is a misconfiguration" 2 \
    "${tmp}/live.toml" "${tmp}/garbage.json" "${tmp}/builder.json"

  _toml "${tmp}/empty.toml"
  _case "no ignore IDs is a misconfiguration, not a pass" 2 "${tmp}/empty.toml" "${tmp}/core.json"

  _toml "${tmp}/typo.toml" "${LIVE[@]}" '"RUSTSEC-2026-73",'
  _case "a malformed ignore id is a misconfiguration" 2 "${tmp}/typo.toml" "${tmp}/core.json" "${tmp}/builder.json"

  # The lockfile list is derived from audit.yml, in its step shapes.
  checked=$(( checked + 1 ))
  mkdir -p "${tmp}/wf/.github/workflows"
  printf '      - name: a\n        run: cargo audit\n      - name: b\n        run: cargo audit --file ../haven/rust_builder/Cargo.lock\n      - name: c\n        run: cargo audit --file ../tooling/soak/Cargo.lock\n' \
    >"${tmp}/wf/${WORKFLOW_REL}"
  if [[ "$(audited_lockfiles "${tmp}/wf" | tr '\n' ' ')" == 'haven-core/Cargo.lock haven/rust_builder/Cargo.lock tooling/soak/Cargo.lock ' ]]; then
    printf '  \033[1;32mPASS\033[0m the audited lockfiles are derived from audit.yml\n'
  else
    printf '  \033[1;31mFAIL\033[0m derived %s\n' "$(audited_lockfiles "${tmp}/wf" | tr '\n' ' ')" >&2
    fails=1
  fi

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
  --) shift; run_check "$@" ;;
  '') run_check ;;
  *) echo "usage: $(basename "$0") [--self-test | -- <extra cargo-audit args>]" >&2; exit 2 ;;
esac
