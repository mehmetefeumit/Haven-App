#!/usr/bin/env bash
# Release/nightly gate: no git-pinned dependency, and no Flutter or Dart SDK
# release, is in range of an advisory its upstream repository published.
#
# No scanner can see these. cargo-audit skips every package that is not from
# crates.io, and a repository security advisory reaches the GitHub Advisory
# Database (and so OSV) only if GitHub reviews it into an ecosystem. On
# 2026-11-12 OpenMLS had four published advisories against the 0.8 line that
# no database carried, while Haven shipped openmls 0.8.1 from the
# erskingardner fork, behind all four fixes. So this reads the advisories at
# the source.
#
# Watched: every `git+https://github.com/<owner>/<repo>` source in a committed
# Cargo.lock, and that repository's fork parent — a fork inherits its parent's
# bugs, not its advisories; plus flutter/flutter and dart-lang/sdk, at the
# current stable Flutter release and its Dart SDK, which is what release-build
# compiles with. For a Cargo repository, a vulnerability entry counts when its
# package name equals a package locked from that repository or from a fork of
# it, and is evaluated against each locked version. For an SDK repository every
# entry is about the SDK, whatever name it gives.
#
# Ranges are GitHub's `vulnerable_version_range` comparator lists ("< 0.8.2",
# ">= 0.9.0, < 0.9.1", "= 1.2.3", "<= 1.0", a bare version). Versions compare
# numerically by release; build metadata is ignored; when the releases are
# equal and either side is a pre-release, the comparator counts as met, so a
# pre-release is never let through on a guess. A range, package or version
# this cannot read is a finding (fail closed). Only published advisories that
# were never withdrawn count. An advisory the ledger (osv-scanner.toml)
# acknowledges, by GHSA or CVE id, until a date after today, passes; an
# expired acknowledgement does not.
#
# Network: GitHub's REST API through `gh` (GH_TOKEN; public advisory reads) and
# Flutter's release manifest. Run in audit.yml's `full` mode only — nightly and
# inside every release — because it calls third-party services.
#
# Usage:
#   bash scripts/ci/check_upstream_advisories.sh [--matches-out <file>] [--no-sdk] [<Cargo.lock>...]
#       defaults to every committed Cargo.lock. --matches-out writes
#       `<id>\t<pkg>@<ver>` for every in-range advisory, acknowledged or not,
#       GHSA and CVE ids alike, for check_ledger.sh's liveness rule. --no-sdk
#       watches the git pins alone: the release-tag scan's, since the SDK
#       advisories are about today's stable, which main's scan already reports,
#       and a second report would be a second issue.
#   bash scripts/ci/check_upstream_advisories.sh --self-test   # stubbed gh and curl
#
# SECURITY_FINDINGS_OUT, when set, gets one `watcher:<GHSA>:<pkg>@<ver>\t<summary>`
# line per unacknowledged in-range or unreadable entry.
#
# Exit codes:
#   0  nothing in range beyond acknowledged advisories (or the self-test passed)
#   1  an unacknowledged advisory in range, or one that cannot be evaluated
#      (or the self-test failed)
#   2  misconfiguration: an API or manifest that did not answer, an unreadable
#      lockfile or ledger

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly LEDGER_REL='osv-scanner.toml'
readonly FLUTTER_RELEASES='https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json'
readonly VERSION_RE='^v?([0-9]+(\.[0-9]+)*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=15
WATCH_SDK=1

log() {
  printf '\033[1;34m[check_upstream_advisories]\033[0m %s\n' "$*"
}

finding() { # <key> <summary>
  [[ -n "${SECURITY_FINDINGS_OUT:-}" ]] || return 0
  printf '%s\t%s\n' "$1" "$2" >>"${SECURITY_FINDINGS_OUT}"
}

# -1, 0 or 1; `?` when only a pre-release tag tells them apart; rc 2 when
# either is not a version.
vercmp() { # <a> <b>
  [[ "$1" =~ ${VERSION_RE} ]] || return 2
  local a="${BASH_REMATCH[1]}" apre="${BASH_REMATCH[3]}"
  [[ "$2" =~ ${VERSION_RE} ]] || return 2
  local b="${BASH_REMATCH[1]}" bpre="${BASH_REMATCH[3]}" i x y
  local -a as bs
  IFS=. read -r -a as <<<"${a}"
  IFS=. read -r -a bs <<<"${b}"
  for (( i = 0; i < ${#as[@]} || i < ${#bs[@]}; i++ )); do
    x=$(( 10#${as[i]:-0} )); y=$(( 10#${bs[i]:-0} ))
    (( x < y )) && { echo -1; return; }
    (( x > y )) && { echo 1; return; }
  done
  if [[ -z "${apre}" && -z "${bpre}" ]]; then echo 0; else echo '?'; fi
}

# Whether <version> is in <range>: rc 0 in, 1 out, 2 unreadable.
in_range() { # <version> <range>
  local version="$1" comp op v c
  local -a comps
  [[ -n "${2//[[:space:]]/}" ]] || return 2
  IFS=, read -r -a comps <<<"$2"
  for comp in "${comps[@]}"; do
    comp="${comp#"${comp%%[![:space:]]*}"}"; comp="${comp%"${comp##*[![:space:]]}"}"
    [[ "${comp}" =~ ^(>=|<=|>|<|=)?[[:space:]]*([^[:space:]]+)$ ]] || return 2
    op="${BASH_REMATCH[1]:-=}"; v="${BASH_REMATCH[2]}"
    c="$(vercmp "${version}" "${v}")" || return 2
    [[ "${c}" == '?' ]] && continue
    case "${op}" in
      '<')  (( c < 0 )) ;;
      '<=') (( c <= 0 )) ;;
      '>')  (( c > 0 )) ;;
      '>=') (( c >= 0 )) ;;
      '=')  (( c == 0 )) ;;
    esac || return 1
  done
}

# "<owner/repo>\t<package>\t<version>" for each git-sourced GitHub package.
git_packages() { # <Cargo.lock>...
  awk '
    /^\[\[package\]\]/ { name = ver = "" }
    /^name = / { name = $3; gsub(/"/, "", name) }
    /^version = / { ver = $3; gsub(/"/, "", ver) }
    /^source = "git\+https:\/\/github\.com\// {
      repo = $3; gsub(/"/, "", repo); sub(/^git\+https:\/\/github\.com\//, "", repo); sub(/[?#].*$/, "", repo); sub(/\.git$/, "", repo)
      print tolower(repo) "\t" name "\t" ver
    }
  ' "$@" | sort -u
}

# "<id>\t<effectiveUntil date>" per ledger entry.
acknowledged() { # <ledger>
  awk '
    /^\[\[IgnoredVulns\]\]/ { if (id != "") print id "\t" until; id = until = "" }
    /^[[:space:]]*id[[:space:]]*=/ { id = $0; sub(/^[^"]*"/, "", id); sub(/".*$/, "", id) }
    /^[[:space:]]*effectiveUntil[[:space:]]*=/ { until = $0; sub(/^[^=]*=[[:space:]]*/, "", until); until = substr(until, 1, 10) }
    END { if (id != "") print id "\t" until }
  ' "$1"
}

check() { # <matches-out|""> <Cargo.lock>...
  local matches="$1"; shift
  local ledger="${REPO_ROOT}/${LEDGER_REL}" today tmp
  today="${LEDGER_TODAY:-$(date -u +%F)}"
  [[ -f "${ledger}" ]] || { echo "ERROR: ${LEDGER_REL} not found" >&2; return 2; }
  (( $# > 0 )) || { echo "ERROR: no Cargo.lock to read" >&2; return 2; }
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  [[ -z "${matches}" ]] || : >"${matches}"

  local lock
  for lock in "$@"; do [[ -f "${lock}" ]] || { echo "ERROR: ${lock} not found" >&2; return 2; }; done
  git_packages "$@" >"${tmp}/git"
  [[ -s "${tmp}/git" ]] || { echo "ERROR: no git-sourced GitHub package in $* — the watcher would watch nothing" >&2; return 2; }

  # "<watched repo>\t<package>\t<version>"; an SDK repo's package is `*`.
  local repo pkg ver parent
  while IFS=$'\t' read -r repo pkg ver; do
    printf '%s\t%s\t%s\n' "${repo}" "${pkg}" "${ver}"
  done <"${tmp}/git" >"${tmp}/watch"
  while read -r repo; do
    parent="$(gh api "repos/${repo}" --jq '.parent.full_name // empty')" \
      || { echo "ERROR: GitHub did not answer for repos/${repo}" >&2; return 2; }
    [[ -z "${parent}" ]] && continue
    awk -F'\t' -v r="${repo}" -v p="$(tr '[:upper:]' '[:lower:]' <<<"${parent}")" '$1 == r { print p "\t" $2 "\t" $3 }' "${tmp}/git" >>"${tmp}/watch"
  done < <(cut -f1 "${tmp}/git" | sort -u)

  local flutter='' dart=''
  if (( WATCH_SDK )); then
    curl -fsS --retry 3 --retry-all-errors "${FLUTTER_RELEASES}" -o "${tmp}/releases.json" \
      || { echo "ERROR: Flutter's release manifest did not answer" >&2; return 2; }
    flutter="$(jq -r '.current_release.stable as $h | .releases[] | select(.hash == $h) | .version' "${tmp}/releases.json" 2>/dev/null | head -1)"
    dart="$(jq -r '.current_release.stable as $h | .releases[] | select(.hash == $h) | .dart_sdk_version' "${tmp}/releases.json" 2>/dev/null | head -1)"
    dart="${dart%% *}"
    [[ "${flutter}" =~ ${VERSION_RE} && "${dart}" =~ ${VERSION_RE} ]] \
      || { echo "ERROR: no current stable Flutter and Dart version in Flutter's release manifest" >&2; return 2; }
    printf 'flutter/flutter\t*flutter\t%s\ndart-lang/sdk\t*dart\t%s\n' "${flutter}" "${dart}" >>"${tmp}/watch"
  fi
  sort -u -o "${tmp}/watch" "${tmp}/watch"

  local acks bad=0 n=0 rc adv ghsa cve summary vrange vname target tver id until
  acks="$(acknowledged "${ledger}")"
  while read -r repo; do
    gh api --paginate "repos/${repo}/security-advisories?state=published&per_page=100" --jq '.[] | tojson' >"${tmp}/adv" \
      || { echo "ERROR: GitHub did not answer for repos/${repo}/security-advisories" >&2; return 2; }
    while read -r adv; do
      [[ -n "${adv}" ]] || continue
      jq -e '.state == "published" and .withdrawn_at == null' <<<"${adv}" >/dev/null || continue
      n=$(( n + 1 ))
      ghsa="$(jq -r '.ghsa_id' <<<"${adv}")"; cve="$(jq -r '.cve_id // empty' <<<"${adv}")"
      summary="$(jq -r '.summary | gsub("[\t\n]"; " ")' <<<"${adv}")"
      # US-separated: a tab is IFS whitespace, so an empty name would vanish.
      while IFS=$'\037' read -r vname vrange; do
        while IFS=$'\t' read -r _ target tver; do
          if [[ "${target}" == \** ]]; then
            target="${target#\*}"
          elif [[ "${vname}" != "${target}" ]]; then
            [[ -n "${vname}" ]] || {
              printf '\033[1;31m  %s in %s names no package\033[0m\n' "${ghsa}" "${repo}" >&2
              finding "watcher:${ghsa}:${target}@${tver}" "${repo} ${ghsa} names no package (${summary})"
              bad=1
            }
            continue
          fi
          rc=0
          in_range "${tver}" "${vrange}" || rc=$?
          if (( rc == 2 )); then
            printf '\033[1;31m  %s (%s) range %q cannot be evaluated against %s %s\033[0m\n' "${ghsa}" "${repo}" "${vrange}" "${target}" "${tver}" >&2
            finding "watcher:${ghsa}:${target}@${tver}" "${repo} ${ghsa}: unreadable range for ${target} ${tver} (${summary})"
            bad=1; continue
          fi
          (( rc == 0 )) || continue
          if [[ -n "${matches}" ]]; then
            printf '%s\t%s@%s\n' "${ghsa}" "${target}" "${tver}" >>"${matches}"
            [[ -z "${cve}" ]] || printf '%s\t%s@%s\n' "${cve}" "${target}" "${tver}" >>"${matches}"
          fi
          for id in "${ghsa}" ${cve:+"${cve}"}; do
            until="$(awk -F'\t' -v i="${id}" '$1 == i { print $2; exit }' <<<"${acks}")"
            if [[ -n "${until}" && "${until}" > "${today}" ]]; then
              log "acknowledged until ${until}: ${ghsa} ${target} ${tver} (${repo})"
              continue 2
            fi
          done
          printf '\033[1;31m  %s %s %s is in range %q of %s (%s): %s\033[0m\n' "${ghsa}" "${target}" "${tver}" "${vrange}" "${repo}" "${cve:-no CVE}" "${summary}" >&2
          finding "watcher:${ghsa}:${target}@${tver}" "${repo} ${ghsa}: ${target} ${tver} in ${vrange} (${summary})"
          bad=1
        done < <(awk -F'\t' -v r="${repo}" '$1 == r' "${tmp}/watch")
      done < <(jq -r '(.vulnerabilities // [])[] | [(.package.name // ""), (.vulnerable_version_range // "")] | join("\u001f")' <<<"${adv}")
    done <"${tmp}/adv"
  done < <(cut -f1 "${tmp}/watch" | sort -u)

  if (( bad )); then
    printf '\033[1;31m[check_upstream_advisories] FAIL:\033[0m an upstream advisory above applies to what Haven ships. Move to a release that fixes it; an owner-decided, expiring entry in %s is the only other way past it.\n' "${LEDGER_REL}" >&2
    return 1
  fi
  log "OK: $(cut -f1 "${tmp}/watch" | sort -u | wc -l) upstream repositories, ${n} published advisories; nothing unacknowledged in range ($( (( WATCH_SDK )) && echo "Flutter ${flutter}, Dart ${dart}" || echo 'SDKs not watched'))."
}

committed_cargo_locks() {
  git -C "${REPO_ROOT}" ls-files -co --exclude-standard -- '*Cargo.lock' | while read -r rel; do
    [[ -f "${REPO_ROOT}/${rel}" ]] && printf '%s\n' "${REPO_ROOT}/${rel}"
  done
}

# ---------------------------------------------------------------------------
# Self-test. The advisories are shaped field for field like GitHub's
# `repository-advisory` schema (github/rest-api-description, 2026-11-12); their
# ids and ranges are fixtures except GHSA-gc79-23g3-8g52's "< 0.8.2". gh and
# curl are stubs serving them, so nothing touches the network.
# ---------------------------------------------------------------------------
self_test() {
  local fx="${REPO_ROOT}/scripts/ci/fixtures/dependency-security/watcher" tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/bin" "${tmp}/serve" "${tmp}/root"
  local lock="${fx}/git-pins.Cargo.lock.txt"
  # gh api [--paginate] <path> --jq <expr>: <path> served from serve/, through
  # the real jq, printing strings raw as gh does.
  cat >"${tmp}/bin/gh" <<EOF
#!/usr/bin/env bash
[[ "\$1" == api ]] || exit 4
shift; path='' expr='.'
while (( \$# )); do case "\$1" in --paginate) shift ;; --jq) expr="\$2"; shift 2 ;; *) path="\$1"; shift ;; esac; done
path="\${path%%\\?*}"
case "\${path}" in
  repos/*/*/security-advisories) f="${tmp}/serve/advisories.\$(cut -d/ -f2 <<<"\${path}")__\$(cut -d/ -f3 <<<"\${path}").json" ;;
  repos/*/*) f="${fx}/repo.\$(cut -d/ -f2 <<<"\${path}")__\$(cut -d/ -f3 <<<"\${path}").json" ;;
  *) exit 4 ;;
esac
[[ -f "\${f}" ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
jq -r "\${expr}" "\${f}"
EOF
  cat >"${tmp}/bin/curl" <<EOF
#!/usr/bin/env bash
out=''
while (( \$# )); do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[[ -f "${tmp}/serve/releases_linux.json" ]] || exit 22
cp "${tmp}/serve/releases_linux.json" "\${out}"
EOF
  chmod +x "${tmp}/bin/gh" "${tmp}/bin/curl"

  # serve <openmls advisory ids...>: every watched repository answers, with
  # openmls/openmls publishing only the named advisories.
  _serve() {
    local ids; ids="$(printf '"%s",' "$@")"
    for r in marmot-protocol__mdk erskingardner__openmls; do printf '[]\n' >"${tmp}/serve/advisories.${r}.json"; done
    printf '[]\n' >"${tmp}/serve/advisories.flutter__flutter.json"
    printf '[]\n' >"${tmp}/serve/advisories.dart-lang__sdk.json"
    cp "${fx}/advisories.rusqlite__rusqlite.json" "${tmp}/serve/"
    jq "map(select(.ghsa_id as \$g | [${ids%,}] | index(\$g)))" "${fx}/advisories.openmls__openmls.json" >"${tmp}/serve/advisories.openmls__openmls.json"
    cp "${fx}/releases_linux.json" "${tmp}/serve/"
  }
  _ledger() { # [<id> <effectiveUntil date>]
    : >"${tmp}/root/${LEDGER_REL}"
    (( $# )) && printf '[[IgnoredVulns]]\nid = "%s"\neffectiveUntil = %sT00:00:00Z\nreason = "owner-decision: 2026-11-12. fixture"\n' "$1" "$2" >"${tmp}/root/${LEDGER_REL}"
    return 0
  }
  _case() { # <label> <want-rc> <needle|-> <cmd>...
    local label="$1" want="$2" needle="$3" got=0; shift 3
    checked=$(( checked + 1 ))
    : >"${tmp}/findings"; : >"${tmp}/matches"
    ( PATH="${tmp}/bin:${PATH}" REPO_ROOT="${tmp}/root" LEDGER_TODAY=2026-11-12 SECURITY_FINDINGS_OUT="${tmp}/findings" "$@" ) >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]] && { [[ "${needle}" == - ]] || grep -qF -- "${needle}" "${tmp}/out" "${tmp}/findings" "${tmp}/matches"; }; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d%s)\n' "${label}" "${want}" "${got}" "$([[ "${needle}" == - ]] || printf ', want output containing %q' "${needle}")" >&2
      sed 's/^/      /' "${tmp}/out" >&2
      fails=1
    fi
  }

  # The flag through main, as the release-tag scan passes it.
  _no_sdk() {
    local rc=0
    main --no-sdk "$@" || rc=$?
    ! grep -qF ':dart@' "${SECURITY_FINDINGS_OUT}" || return 3
    return "${rc}"
  }

  echo "check_upstream_advisories.sh --self-test"
  # <version>|<range>|<rc: 0 in, 1 out, 2 unreadable>
  _table() {
    local row v r want got
    for row in '0.8.1|< 0.8.2|0' '0.8.2|< 0.8.2|1' '0.9.0|>= 0.9.0, < 0.9.1|0' '0.9.1|>= 0.9.0, < 0.9.1|1' \
               '0.8.1|>= 0.9.0, < 0.9.1|1' '1.2.3|= 1.2.3|0' '1.2.4|= 1.2.3|1' '1.0.0|<= 1.0|0' '1.2.3|1.2.3|0' \
               '2.0.1|> 2|0' '10.0.0|< 9.0.0|1' '300.5.5+3.5.5|< 300.5.6|0' '0.9.0-rc.1|>= 0.9.0, < 0.9.1|0' \
               '0.8.2-pre.1|< 0.8.2|0' '0.8.1|~> 0.8|2' '0.8.1||2' '0.8.1|< latest|2' 'abc|< 1.0|2'; do
      IFS='|' read -r v r want <<<"${row}"
      got=0; in_range "${v}" "${r}" || got=$?
      [[ "${got}" == "${want}" ]] || { echo "in_range '${v}' '${r}' = ${got}, want ${want}"; return 1; }
    done
  }
  _case "ranges evaluate GitHub's comparator forms; a pre-release tie counts as in range" 0 - _table

  _serve GHSA-gc79-23g3-8g52; _ledger
  _case "a fork's parent advisory in range of the locked fork version fails" 1 \
    "$(printf 'watcher:GHSA-gc79-23g3-8g52:openmls@0.8.1\topenmls/openmls GHSA-gc79-23g3-8g52: openmls 0.8.1 in < 0.8.2')" \
    check "${tmp}/matches" "${lock}"

  _serve GHSA-2222-3333-4444; _ledger
  _case "an advisory out of range of the locked version passes" 0 - check "${tmp}/matches" "${lock}"

  _serve GHSA-3333-4444-5555; _ledger GHSA-3333-4444-5555 2027-01-15
  _case "an acknowledged in-range advisory passes and is reported as matched" 0 "$(printf 'GHSA-3333-4444-5555\topenmls@0.8.1')" \
    check "${tmp}/matches" "${lock}"

  _serve GHSA-3333-4444-5555; _ledger CVE-2026-0001 2027-01-15
  _case "an acknowledgement by the advisory's CVE id counts too" 0 "$(printf 'CVE-2026-0001\topenmls@0.8.1')" \
    check "${tmp}/matches" "${lock}"

  _serve GHSA-3333-4444-5555; _ledger GHSA-3333-4444-5555 2026-11-12
  _case "an expired acknowledgement does not" 1 'watcher:GHSA-3333-4444-5555:openmls@0.8.1' check "${tmp}/matches" "${lock}"

  _serve GHSA-4444-5555-6666; _ledger
  _case "a withdrawn advisory is ignored" 0 - check "${tmp}/matches" "${lock}"

  _serve GHSA-5555-6666-7777; _ledger
  _case "an advisory for a crate not locked from that source is ignored (here, and the registry rusqlite)" 0 - \
    check "${tmp}/matches" "${lock}"

  _serve GHSA-6666-7777-8888; _ledger
  _case "an unreadable range fails closed" 1 'watcher:GHSA-6666-7777-8888:openmls@0.8.1' check "${tmp}/matches" "${lock}"

  _serve GHSA-7777-8888-9999; _ledger
  _case "an entry with no range fails closed" 1 'watcher:GHSA-7777-8888-9999:openmls@0.8.1' check "${tmp}/matches" "${lock}"

  _serve GHSA-8888-9999-cccc; _ledger
  _case "an entry naming no package fails closed" 1 'GHSA-8888-9999-cccc in openmls/openmls names no package' \
    check "${tmp}/matches" "${lock}"

  _serve; cp "${fx}/advisories.dart-lang__sdk.json" "${tmp}/serve/"; _ledger
  _case "an SDK advisory in range of the current stable Dart fails, whatever package it names" 1 \
    'watcher:GHSA-cccc-ffff-gggg:dart@3.14.0' check "${tmp}/matches" "${lock}"

  _serve; rm "${tmp}/serve/advisories.marmot-protocol__mdk.json"; _ledger
  _case "a repository GitHub does not answer for is a misconfiguration" 2 'did not answer for repos/marmot-protocol/mdk/security-advisories' \
    check "${tmp}/matches" "${lock}"

  _serve; rm "${tmp}/serve/releases_linux.json"; _ledger
  _case "an unreachable Flutter release manifest is a misconfiguration" 2 "release manifest did not answer" \
    check "${tmp}/matches" "${lock}"

  _serve GHSA-gc79-23g3-8g52; rm "${tmp}/serve/releases_linux.json"; cp "${fx}/advisories.dart-lang__sdk.json" "${tmp}/serve/"; _ledger
  _case "--no-sdk reads no release manifest and no SDK advisory, and still the git pins'" 1 \
    'watcher:GHSA-gc79-23g3-8g52:openmls@0.8.1' _no_sdk "${lock}"

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
  local matches=''
  [[ "${1:-}" != --self-test ]] || { self_test; return; }
  while (( $# )); do
    case "$1" in
      --matches-out) matches="${2:?--matches-out needs a path}"; shift 2 ;;
      --no-sdk) WATCH_SDK=0; shift ;;
      *) break ;;
    esac
  done
  (( $# > 0 )) || mapfile -t LOCKS < <(committed_cargo_locks)
  (( $# > 0 )) && LOCKS=("$@")
  check "${matches}" "${LOCKS[@]}"
}

main "$@"
