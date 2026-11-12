#!/usr/bin/env bash
# CI guard: every acknowledged advisory is reasoned, owner-decided, expiring
# and still real.
#
# osv-scanner.toml is the one place Haven says "we ship this advisory on
# purpose". An acknowledgement without an end date is a permanent silencing
# that nobody re-decides, which is why RUSTSEC-2026-0237 was never given a
# cargo-audit ignore (those cannot expire). This holds, over the ledger:
#
#   1. Each [[IgnoredVulns]] entry has an `id` (RUSTSEC-, GHSA- or CVE-; never
#      MAL-, which is never acknowledgeable), a `reason` carrying
#      `owner-decision: YYYY-MM-DD` (a real date, not after today), and
#      `effectiveUntil` — never the deprecated `ignoreUntil`. No id twice, and
#      nothing but such entries: a [[PackageOverrides]] block would silence a
#      whole package with no rule here applying to it.
#   2. `effectiveUntil` is after today and at most 90 days out (UTC dates).
#      Within 14 days it warns, and files `ledger-expiring:<ID>` for the
#      nightly's issue; on or after it, `ledger-expired:<ID>` and a failure.
#   3. Every id in haven-core/.cargo/audit.toml's `ignore` has a valid entry:
#      cargo-audit's ignores cannot expire, so the ledger supplies their end.
#   4. Every osv-scanner scan in .github/workflows and scripts/ci passes
#      `--offline`: the online mode posts every package name and version to
#      osv.dev. A scan is `osv-scanner` followed by `scan`, `fix` or a flag
#      other than --version/--help, on one logical line (continuations
#      joined), outside a comment; an invocation through a variable is not
#      seen, which is why run_osv_gate.sh spells the binary out.
#   5. Liveness (with --mode): every entry matches, as id or alias, an advisory
#      in the scan run with NO acknowledgement applied, or — with
#      --watcher-matches — one check_upstream_advisories.sh found in range. A
#      stale entry would silence the advisory if it came back. Unmatched is a
#      failure in `full` mode (nightly, release, where the watcher runs) and a
#      warning in `pr` mode (the watcher does not run on pull requests); it
#      files `ledger-stale:<ID>` either way.
#
# "Today" is LEDGER_TODAY (YYYY-MM-DD) when set, else the UTC date, so the
# self-test never reads the clock.
#
# Usage:
#   bash scripts/ci/check_ledger.sh --static                    # rules 1-4
#   bash scripts/ci/check_ledger.sh --mode pr|full --osv-json <unfiltered.json> \
#        [--watcher-matches <matches.tsv>]                      # rules 1-5
#   bash scripts/ci/check_ledger.sh --self-test
#
# Exit codes:
#   0  the ledger holds (warnings allowed), or the self-test passed
#   1  a rule is broken (or the self-test failed)
#   2  misconfiguration: an unreadable ledger, a bad argument or input file

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly LEDGER_REL='osv-scanner.toml'
readonly AUDIT_TOML_REL='haven-core/.cargo/audit.toml'
readonly MAX_DAYS=90
readonly WARN_DAYS=14

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=22

log() {
  printf '\033[1;34m[check_ledger]\033[0m %s\n' "$*"
}

finding() { # <key> <summary>
  [[ -n "${SECURITY_FINDINGS_OUT:-}" ]] || return 0
  printf '%s\t%s\n' "$1" "$2" >>"${SECURITY_FINDINGS_OUT}"
}

broken() { # <message>
  printf '  \033[1;31m%s\033[0m\n' "$*" >&2
  bad=1
}

# A date's day number, or nothing if it is not a real YYYY-MM-DD date.
day() { # <YYYY-MM-DD>
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  [[ "$(date -u -d "$1" +%F 2>/dev/null)" == "$1" ]] || return 0
  echo $(( $(date -u -d "$1" +%s) / 86400 ))
}

# "<line> <id> <effectiveUntil> <ignoreUntil> <reason>" per entry, separated by
# US (\037): a tab is IFS whitespace, so `read` would merge an empty field. Refuses
# (rc 2) anything but [[IgnoredVulns]] blocks of one-line keys.
entries() { # <ledger>
  awk '
    function flush() { if (inblk) printf "%d\037%s\037%s\037%s\037%s\n", start, id, until, legacy, reason; id = until = legacy = reason = "" }
    function die(msg) { printf "ERROR: %s:%d: %s\n", FILENAME, NR, msg > "/dev/stderr"; failed = 1; exit 2 }
    /^[[:space:]]*(#.*)?$/ { next }
    /^[[:space:]]*\[\[IgnoredVulns\]\][[:space:]]*(#.*)?$/ { flush(); inblk = 1; start = NR; next }
    /^[[:space:]]*\[/ { die("only [[IgnoredVulns]] entries belong in the ledger") }
    {
      if (!inblk) die("a key outside an [[IgnoredVulns]] entry")
      if (!match($0, /^[[:space:]]*[A-Za-z]+[[:space:]]*=[[:space:]]*/)) die("not a `key = value` line")
      key = substr($0, 1, RLENGTH); val = substr($0, RLENGTH + 1)
      gsub(/[[:space:]=]/, "", key)
      sub(/[[:space:]]+(#[^"]*)?$/, "", val)
      if (key == "id" || key == "reason") {
        if (val !~ /^"([^"\\]|\\.)*"$/) die(key " must be a one-line \"string\"")
        val = substr(val, 2, length(val) - 2)
        if (key == "id") id = val; else reason = val
      } else if (key == "effectiveUntil" || key == "ignoreUntil") {
        if (val !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) die(key " must be a UTC datetime, YYYY-MM-DDTHH:MM:SSZ")
        if (key == "effectiveUntil") until = val; else legacy = val
      } else die("unknown key `" key "` (osv-scanner refuses it too)")
    }
    END { if (!failed) flush() }
  ' "$1"
}

# ignore = [...] ids of audit.toml, comments stripped.
audit_ignores() { # <audit.toml>
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

# file:line of each osv-scanner scan without --offline.
online_scans() { # <repo root>
  local root="$1" f
  {
    find "${root}/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find "${root}/scripts/ci" -type f -name '*.sh' 2>/dev/null
  } | sort | while read -r f; do
    awk -v f="${f#"${root}/"}" '
      { if (buf == "") start = NR; buf = buf $0 }
      /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, " ", buf); next }
      {
        l = buf; buf = ""
        if (l ~ /^[[:space:]]*#/) next
        if (l ~ /(^|[[:space:]"\047\/])osv-scanner["\047]?[[:space:]]+(scan|fix|-)/ \
            && l !~ /osv-scanner["\047]?[[:space:]]+(--version|-v|--help|-h)([[:space:]]|$)/ \
            && l !~ /--offline([[:space:]"\047]|$)/)
          printf "%s:%d\n", f, start
      }
    ' "${f}"
  done
}

# check <mode: static|pr|full> [<unfiltered osv json> [<watcher matches>]]
check() {
  local mode="$1" osv="${2:-}" watcher="${3:-}" ledger="${REPO_ROOT}/${LEDGER_REL}"
  local today today_n bad=0
  today="${LEDGER_TODAY:-$(date -u +%F)}"
  today_n="$(day "${today}")"
  [[ -n "${today_n}" ]] || { echo "ERROR: today '${today}' is not a YYYY-MM-DD date" >&2; return 2; }
  [[ -f "${ledger}" ]] || { echo "ERROR: ${LEDGER_REL} not found" >&2; return 2; }

  local rows
  rows="$(entries "${ledger}")" || return 2
  [[ -n "${rows}" ]] || { echo "ERROR: ${LEDGER_REL} holds no [[IgnoredVulns]] entry — parser rot, or every one was lifted (then keep the file and this rule's header, and drop the audit.toml mirror)" >&2; return 2; }

  local line id until legacy reason decided d_n u_n left
  local -a valid=() seen=()
  while IFS=$'\037' read -r line id until legacy reason; do
    local ok=1
    if [[ ! "${id}" =~ ^(RUSTSEC-[0-9]{4}-[0-9]{4}|GHSA(-[23456789cfghjmpqrvwx]{4}){3}|CVE-[0-9]{4}-[0-9]{4,})$ ]]; then
      broken "${LEDGER_REL}:${line}: id '${id}' is not a RUSTSEC, GHSA or CVE id (malicious packages are never acknowledged)"; ok=0
    fi
    if [[ " ${seen[*]} " == *" ${id} "* ]]; then
      broken "${LEDGER_REL}:${line}: ${id} is acknowledged twice; osv-scanner uses the first entry only"; ok=0
    fi
    seen+=("${id}")
    [[ -z "${legacy}" ]] || { broken "${LEDGER_REL}:${line}: ${id} uses the deprecated ignoreUntil; write effectiveUntil"; ok=0; }
    decided=''
    [[ "${reason}" =~ owner-decision:\ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] && decided="${BASH_REMATCH[1]}"
    d_n="$(day "${decided}")"
    if [[ -z "${d_n}" ]]; then
      broken "${LEDGER_REL}:${line}: ${id}'s reason carries no valid 'owner-decision: YYYY-MM-DD'"; ok=0
    elif (( d_n > today_n )); then
      broken "${LEDGER_REL}:${line}: ${id}'s owner decision (${decided}) is dated after today (${today})"; ok=0
    fi
    [[ "${reason/owner-decision: ${decided}/}" =~ [[:alpha:]] ]] \
      || { broken "${LEDGER_REL}:${line}: ${id}'s reason says nothing beyond the decision date"; ok=0; }
    u_n="$(day "${until:0:10}")"
    if [[ -z "${until}" || -z "${u_n}" ]]; then
      broken "${LEDGER_REL}:${line}: ${id} has no valid effectiveUntil; an acknowledgement without one never ends"; ok=0
    else
      left=$(( u_n - today_n ))
      if (( left <= 0 )); then
        broken "${LEDGER_REL}:${line}: ${id} expired on ${until:0:10}; fix the dependency, or re-decide and re-date the entry"
        finding "ledger-expired:${id}" "acknowledgement of ${id} expired on ${until:0:10}"
        ok=0
      elif (( left > MAX_DAYS )); then
        broken "${LEDGER_REL}:${line}: ${id} runs ${left} days, past the ${MAX_DAYS}-day limit"; ok=0
      elif (( left <= WARN_DAYS )); then
        printf 'warning: %s expires in %d day(s), on %s\n' "${id}" "${left}" "${until:0:10}"
        finding "ledger-expiring:${id}" "acknowledgement of ${id} expires on ${until:0:10}"
      fi
    fi
    (( ok )) && valid+=("${id}")
  done <<<"${rows}"

  local audit="${REPO_ROOT}/${AUDIT_TOML_REL}" a
  [[ -f "${audit}" ]] || { echo "ERROR: ${AUDIT_TOML_REL} not found" >&2; return 2; }
  while read -r a; do
    [[ -n "${a}" ]] || continue
    [[ " ${valid[*]} " == *" ${a} "* ]] \
      || broken "${AUDIT_TOML_REL} ignores ${a}, which has no valid entry in ${LEDGER_REL} — the ledger is what gives a cargo-audit ignore its expiry"
  done < <(audit_ignores "${audit}")

  local hit
  while read -r hit; do
    [[ -n "${hit}" ]] && broken "${hit}: an osv-scanner scan without --offline sends every package name and version to osv.dev"
  done < <(online_scans "${REPO_ROOT}")

  if [[ "${mode}" != static ]]; then
    if [[ ! -f "${osv}" ]] || ! jq -e '(.results | type) == "array"' "${osv}" >/dev/null 2>&1; then
      echo "ERROR: --osv-json '${osv}' is not an osv-scanner JSON report" >&2; return 2
    fi
    if [[ "${mode}" == full ]]; then
      [[ -r "${watcher}" ]] || { echo "ERROR: --mode full needs --watcher-matches (the upstream-advisory watcher runs in full mode)" >&2; return 2; }
    fi
    local known
    known="$(jq -r '.results[].packages[] | (.vulnerabilities // [])[] | .id, (.aliases // [])[]' "${osv}"
             [[ -z "${watcher}" ]] || cut -f1 "${watcher}")"
    while IFS=$'\037' read -r line id _; do
      grep -qxF -- "${id}" <<<"${known}" && continue
      finding "ledger-stale:${id}" "acknowledgement of ${id} matches no advisory any scanner reports"
      if [[ "${mode}" == full ]]; then
        broken "${LEDGER_REL}:${line}: ${id} matches no advisory in any committed lockfile or upstream advisory; delete the entry (and its audit.toml mirror)"
      else
        printf 'warning: %s matches no osv-scanner advisory (the upstream watcher, which may match it, runs nightly and at release)\n' "${id}"
      fi
    done <<<"${rows}"
  fi

  if (( bad )); then
    printf '\033[1;31m[check_ledger] FAIL:\033[0m %s breaks the rules above (see the header of scripts/ci/check_ledger.sh).\n' "${LEDGER_REL}" >&2
    return 1
  fi
  log "OK: $(grep -c . <<<"${rows}") acknowledgement(s) in ${LEDGER_REL} hold (${mode})."
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is a repository tree: a ledger, an audit.toml, and a
# workflow plus a script that run osv-scanner. The scan report is real
# unfiltered osv-scanner v2.7.1 JSON (see run_osv_gate.sh's self-test).
# ---------------------------------------------------------------------------
self_test() {
  local fx="${REPO_ROOT}/scripts/ci/fixtures/dependency-security" tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local osv="${fx}/osv-unfiltered.json"

  _entry() { # <id> [<effectiveUntil> [<reason>]]
    printf '\n[[IgnoredVulns]]\nid = "%s"\neffectiveUntil = %s\nreason = "%s"\n' \
      "$1" "${2:-2027-02-09T00:00:00Z}" "${3:-owner-decision: 2026-10-30. reachable nowhere; lift when fixed.}"
  }
  _tree() { # <name> <ledger text> [<audit ids...>] -> a fixture root
    local r="${tmp}/$1"; shift
    mkdir -p "${r}/haven-core/.cargo" "${r}/.github/workflows" "${r}/scripts/ci"
    printf '%s\n' "$1" >"${r}/${LEDGER_REL}"; shift
    { printf '[advisories]\nignore = [\n'; printf '  "%s",  # why\n' "$@"; printf ']\n'; } >"${r}/${AUDIT_TOML_REL}"
    cp "${fx}/osv-offline.yml.txt" "${r}/.github/workflows/audit.yml"
    cp "${fx}/osv-offline.sh.txt" "${r}/scripts/ci/run_osv_gate.sh"
    printf '%s' "${r}"
  }
  _case() { # <label> <want-rc> <needle|-> <root> <check args...>
    local label="$1" want="$2" needle="$3" root="$4" got=0; shift 4
    checked=$(( checked + 1 ))
    : >"${tmp}/findings"
    ( REPO_ROOT="${root}" LEDGER_TODAY=2026-11-12 SECURITY_FINDINGS_OUT="${tmp}/findings" check "$@" ) >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]] && { [[ "${needle}" == - ]] || grep -qF -- "${needle}" "${tmp}/out" "${tmp}/findings"; }; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d%s)\n' "${label}" "${want}" "${got}" "$([[ "${needle}" == - ]] || printf ', want output containing %q' "${needle}")" >&2
      sed 's/^/      /' "${tmp}/out" >&2
      fails=1
    fi
  }

  echo "check_ledger.sh --self-test"
  local AUD=(RUSTSEC-2024-0384 RUSTSEC-2026-0387) good
  good="$(_entry RUSTSEC-2024-0384)$(_entry RUSTSEC-2026-0387)$(_entry RUSTSEC-2026-0459)"
  local r
  r="$(_tree good "${good}" "${AUD[@]}")"
  _case "a valid ledger mirroring audit.toml passes" 0 - "${r}" static
  _case "every entry live in the unfiltered scan passes full mode" 0 - "${r}" full "${osv}" /dev/null

  r="$(_tree noid "$(printf '\n[[IgnoredVulns]]\neffectiveUntil = 2027-02-09T00:00:00Z\nreason = "owner-decision: 2026-10-30. x"\n')$(_entry RUSTSEC-2024-0384)$(_entry RUSTSEC-2026-0387)" "${AUD[@]}")"
  _case "an entry without an id fails" 1 "id '' is not" "${r}" static

  r="$(_tree mal "${good}$(_entry MAL-2026-0001)" "${AUD[@]}")"
  _case "a malicious-package id is never acknowledgeable" 1 'MAL-2026-0001' "${r}" static

  r="$(_tree dup "${good}$(_entry RUSTSEC-2026-0459)" "${AUD[@]}")"
  _case "an id acknowledged twice fails" 1 'acknowledged twice' "${r}" static

  r="$(_tree nodecision "${good}$(_entry RUSTSEC-2026-0330 '' 'unreachable; lift when fixed.')" "${AUD[@]}")"
  _case "a reason without an owner decision fails" 1 "RUSTSEC-2026-0330's reason carries no valid" "${r}" static

  r="$(_tree baddate "${good}$(_entry RUSTSEC-2026-0330 '' 'owner-decision: 2026-02-30. x')" "${AUD[@]}")"
  _case "an owner decision on no real date fails" 1 "RUSTSEC-2026-0330's reason carries no valid" "${r}" static

  r="$(_tree future "${good}$(_entry RUSTSEC-2026-0330 '' 'owner-decision: 2026-11-13. x')" "${AUD[@]}")"
  _case "an owner decision dated after today fails" 1 'dated after today' "${r}" static

  r="$(_tree bare "${good}$(_entry RUSTSEC-2026-0330 '' 'owner-decision: 2026-11-01')" "${AUD[@]}")"
  _case "a reason that is only the decision date fails" 1 'says nothing beyond' "${r}" static

  r="$(_tree nountil "${good}$(printf '\n[[IgnoredVulns]]\nid = "RUSTSEC-2026-0330"\nreason = "owner-decision: 2026-10-30. x"\n')" "${AUD[@]}")"
  _case "an entry without effectiveUntil fails" 1 'has no valid effectiveUntil' "${r}" static

  r="$(_tree legacy "${good}$(printf '\n[[IgnoredVulns]]\nid = "RUSTSEC-2026-0330"\nignoreUntil = 2027-01-01T00:00:00Z\nreason = "owner-decision: 2026-10-30. x"\n')" "${AUD[@]}")"
  _case "the deprecated ignoreUntil fails" 1 'deprecated ignoreUntil' "${r}" static

  r="$(_tree expired "${good}$(_entry RUSTSEC-2026-0330 2026-11-12T00:00:00Z)" "${AUD[@]}")"
  _case "an entry expiring today has expired, and files ledger-expired" 1 "$(printf 'ledger-expired:RUSTSEC-2026-0330\t')" "${r}" static

  r="$(_tree long "${good}$(_entry RUSTSEC-2026-0330 2027-02-11T00:00:00Z)" "${AUD[@]}")"
  _case "an entry running 91 days fails" 1 'runs 91 days' "${r}" static

  r="$(_tree soon "${good}$(_entry RUSTSEC-2026-0330 2026-11-26T00:00:00Z)" "${AUD[@]}")"
  _case "an entry expiring within 14 days warns, passes, and files ledger-expiring" 0 "$(printf 'ledger-expiring:RUSTSEC-2026-0330\t')" "${r}" static

  r="$(_tree mirror "${good}" "${AUD[@]}" RUSTSEC-2026-0097)"
  _case "an audit.toml ignore with no ledger entry fails" 1 'ignores RUSTSEC-2026-0097, which has no valid entry' "${r}" static

  r="$(_tree pkgoverride "${good}$(printf '\n[[PackageOverrides]]\nname = "openmls"\nignore = true\n')" "${AUD[@]}")"
  _case "a PackageOverrides block is a misconfiguration" 2 'only [[IgnoredVulns]] entries' "${r}" static

  r="$(_tree unknownkey "${good}$(printf '\n[[IgnoredVulns]]\nid = "RUSTSEC-2026-0330"\neffectiveUntil = 2027-01-01T00:00:00Z\nowner = "me"\nreason = "owner-decision: 2026-10-30. x"\n')" "${AUD[@]}")"
  _case "an unknown key is a misconfiguration" 2 'unknown key `owner`' "${r}" static

  r="$(_tree online "${good}" "${AUD[@]}")"
  cp "${fx}/osv-online.yml.txt" "${r}/.github/workflows/nightly.yml"
  _case "an online scan, its flags continued over lines, fails" 1 '.github/workflows/nightly.yml:' "${r}" static
  rm "${r}/.github/workflows/nightly.yml"
  cp "${fx}/osv-online.sh.txt" "${r}/scripts/ci/scan.sh"
  _case "an online scan with no subcommand, through a quoted path, fails" 1 'scripts/ci/scan.sh:' "${r}" static

  r="$(_tree stale "${good}$(_entry RUSTSEC-2026-0001)" "${AUD[@]}")"
  _case "a stale entry fails full mode and files ledger-stale" 1 "$(printf 'ledger-stale:RUSTSEC-2026-0001\t')" "${r}" full "${osv}" /dev/null
  _case "a stale entry only warns in pr mode" 0 'RUSTSEC-2026-0001 matches no osv-scanner advisory' "${r}" pr "${osv}"

  r="$(_tree watcher "${good}$(_entry GHSA-gc79-23g3-8g52)" "${AUD[@]}")"
  printf 'GHSA-gc79-23g3-8g52\topenmls@0.8.1\n' >"${tmp}/matches.tsv"
  _case "an entry the upstream watcher matched is live in full mode" 0 - "${r}" full "${osv}" "${tmp}/matches.tsv"

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

main() {
  local mode='' osv='' watcher=''
  case "${1:-}" in
    --self-test) self_test; return ;;
    --static) check static; return ;;
  esac
  while (( $# )); do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 || { echo "ERROR: --mode needs pr|full" >&2; return 2; } ;;
      --osv-json) osv="${2:-}"; shift 2 || { echo "ERROR: --osv-json needs a path" >&2; return 2; } ;;
      --watcher-matches) watcher="${2:-}"; shift 2 || { echo "ERROR: --watcher-matches needs a path" >&2; return 2; } ;;
      *) echo "usage: $(basename "$0") --static | --mode pr|full --osv-json <file> [--watcher-matches <file>] | --self-test" >&2; return 2 ;;
    esac
  done
  [[ "${mode}" == pr || "${mode}" == full ]] || { echo "ERROR: --mode must be pr or full (got '${mode}')" >&2; return 2; }
  check "${mode}" "${osv}" "${watcher}"
}

main "$@"
