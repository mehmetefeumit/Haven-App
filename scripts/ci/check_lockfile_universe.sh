#!/usr/bin/env bash
# CI guard: one MLS universe across every Cargo root that builds haven-core.
#
# haven-core, haven/rust_builder (the graph that SHIPS) and tooling/soak (the
# graph the soak rig tests) each carry their own Cargo.lock, and nothing in
# cargo makes them agree. Two openmls builds in one binary are two type graphs
# that still compile; a shipped root that lost a `[patch]` quietly builds a
# different SQLCipher than the one tested. The step this replaces (soak job,
# rust-check.yml) compared VERSIONS parsed from `cargo tree`, and version alone
# cannot see either trap: a git fork of openmls and the crates.io release both
# report 0.8.1, and so can a patched libsqlite3-sys and the registry one. This
# compares the full `(version, source)` pair, straight from the lockfile text —
# no cargo, no network.
#
# For every crate in the universe U below:
#   1. haven-core resolves at most one (version, source) pair;
#   2. each dependent root resolves at most one, and it is one haven-core has;
#   3. the MDK crates, and anything else resolved from the MDK repository,
#      carry exactly HAVEN_MDK_SOURCE; the openmls crates carry
#      HAVEN_OPENMLS_SOURCE;
#   4. libsqlite3-sys is present in all three with HAVEN_LIBSQLITE3_VERSION and
#      HAVEN_LIBSQLITE3_SOURCE.
# The pins live in scripts/ci/mdk_pins.env. A path dependency has no `source`
# line and is recorded as `path`. Which crates must be PRESENT is
# check_mdk_supply_chain.sh's question, not this one's.
#
# Usage:
#   bash scripts/ci/check_lockfile_universe.sh
#   bash scripts/ci/check_lockfile_universe.sh --self-test
#
# Exit codes:
#   0  one universe (or the self-test passed)
#   1  a root diverges or a pin is broken (or the self-test failed)
#   2  a lockfile or the pin file is missing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly CORE='haven-core'
readonly -a DEPENDENT_ROOTS=(haven/rust_builder tooling/soak)
readonly -a OPENMLS_CRATES=(openmls openmls_traits openmls_rust_crypto openmls_basic_credential
                            openmls_memory_storage openmls_serialization_helpers)
readonly -a MDK_CRATES=(cgka-session cgka-engine cgka-traits storage-sqlite transport-nostr-peeler
                        transport-nostr-adapter)
readonly -a UNIVERSE=("${OPENMLS_CRATES[@]}" "${MDK_CRATES[@]}" libsqlite3-sys rusqlite
                      nostr nostr-sdk nostr-relay-pool nostr-database)
readonly MDK_REPO_PREFIX='git+https://github.com/marmot-protocol/mdk'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=20

log() {
  printf '\033[1;34m[check_lockfile_universe]\033[0m %s\n' "$*"
}

# One `name<TAB>version<TAB>source` row per [[package]] block. Only package
# blocks count: `[[patch.unused]]` carries the same keys and is not resolved.
pairs() { # <lockfile>
  awk '
    function flush() { if (pkg && n != "") printf "%s\t%s\t%s\n", n, v, s }
    /^\[/ { flush(); pkg = ($0 == "[[package]]"); n = ""; v = ""; s = "path"; next }
    pkg && /^name = /    { n = $3; gsub(/"/, "", n) }
    pkg && /^version = / { v = $3; gsub(/"/, "", v) }
    pkg && /^source = /  { s = $3; gsub(/"/, "", s) }
    END { flush() }
  ' "$1"
}

# The distinct `version source` pairs one root resolves for one crate.
entries() { # <pairs-file> <crate>
  awk -F'\t' -v c="$2" '$1 == c { print $2 " " $3 }' "$1" | sort -u
}

run_check() {
  local pins="${REPO_ROOT}/scripts/ci/mdk_pins.env" root lock
  [[ -f "${pins}" ]] || { echo "ERROR: ${pins} not found" >&2; return 2; }
  # shellcheck source=mdk_pins.env
  source "${pins}"

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  for root in "${CORE}" "${DEPENDENT_ROOTS[@]}"; do
    lock="${REPO_ROOT}/${root}/Cargo.lock"
    [[ -f "${lock}" ]] || { echo "ERROR: ${lock} not found" >&2; return 2; }
    pairs "${lock}" >"${tmp}/${root//\//_}"
  done

  local -a violations=()
  local crate core_e dep_e n pair want
  for crate in "${UNIVERSE[@]}"; do
    core_e="$(entries "${tmp}/${CORE}" "${crate}")"
    n="$(grep -c . <<<"${core_e}" || true)"
    (( n <= 1 )) || violations+=("${CORE}: ${crate} resolves ${n} (version, source) pairs: ${core_e//$'\n'/; }")
    for root in "${DEPENDENT_ROOTS[@]}"; do
      dep_e="$(entries "${tmp}/${root//\//_}" "${crate}")"
      [[ -n "${dep_e}" ]] || continue
      n="$(grep -c . <<<"${dep_e}")"
      if (( n > 1 )); then
        violations+=("${root}: ${crate} resolves ${n} (version, source) pairs: ${dep_e//$'\n'/; }")
        continue
      fi
      grep -qxF -- "${dep_e}" <<<"${core_e}" \
        || violations+=("${root}: ${crate} ${dep_e} is not what ${CORE} resolves (${core_e:-absent})")
    done
  done

  for root in "${CORE}" "${DEPENDENT_ROOTS[@]}"; do
    local f="${tmp}/${root//\//_}"
    for crate in "${MDK_CRATES[@]}"; do
      while read -r pair; do
        [[ -n "${pair}" ]] || continue
        [[ "${pair#* }" == "${HAVEN_MDK_SOURCE}" ]] \
          || violations+=("${root}: ${crate} resolves from '${pair#* }', not the pinned MDK source '${HAVEN_MDK_SOURCE}'")
      done <<<"$(entries "${f}" "${crate}")"
    done
    while IFS=$'\t' read -r crate _ want; do
      [[ "${want}" == "${HAVEN_MDK_SOURCE}" ]] \
        || violations+=("${root}: ${crate} resolves from MDK source '${want}', not the pinned '${HAVEN_MDK_SOURCE}'")
    done < <(awk -F'\t' -v p="${MDK_REPO_PREFIX}" 'index($3, p) == 1' "${f}")
    for crate in "${OPENMLS_CRATES[@]}"; do
      while read -r pair; do
        [[ -n "${pair}" ]] || continue
        [[ "${pair#* }" == "${HAVEN_OPENMLS_SOURCE}" ]] \
          || violations+=("${root}: ${crate} resolves from '${pair#* }', not the pinned openmls source '${HAVEN_OPENMLS_SOURCE}'")
      done <<<"$(entries "${f}" "${crate}")"
    done
    want="${HAVEN_LIBSQLITE3_VERSION} ${HAVEN_LIBSQLITE3_SOURCE}"
    [[ "$(entries "${f}" libsqlite3-sys)" == "${want}" ]] \
      || violations+=("${root}: libsqlite3-sys is '$(entries "${f}" libsqlite3-sys | tr '\n' ';')', not the pinned '${want}'")
  done

  if (( ${#violations[@]} > 0 )); then
    printf '  %s\n' "${violations[@]}" >&2
    printf '\033[1;31m[check_lockfile_universe] FAIL:\033[0m the Cargo roots that build haven-core do not resolve one MLS universe from the pinned sources (scripts/ci/mdk_pins.env). Re-lock the diverging root, or move the pin and every manifest together.\n' >&2
    return 1
  fi
  log "OK: ${CORE}, ${DEPENDENT_ROOTS[*]} resolve one (version, source) per universe crate, on the pinned sources."
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is a whole tree (three lockfiles and a pin file) run
# through the real entry point, so the parser, the pin loading and every check
# are exercised together. Plants (a)-(d) are the four ways the version-only
# step it replaces could pass while its title claimed "one source".
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local REG='registry+https://github.com/rust-lang/crates.io-index'
  local R0='e391adc133a9b60e420da7a0446f014a180ac8d2' R1='fcc85edd8dbd07c8293c899ee52230f72c54c897'
  local FORK='git+https://github.com/erskingardner/openmls.git?rev=59e7d3b27a7e95237879dd5478de1fd90eff7ada#59e7d3b27a7e95237879dd5478de1fd90eff7ada'
  local SQLC='git+https://github.com/rusqlite/rusqlite.git?rev=5ae7fdf83085c595fd54f977b3a56ccacabaf16b#5ae7fdf83085c595fd54f977b3a56ccacabaf16b'
  mdk() { printf '%s?rev=%s#%s' "${MDK_REPO_PREFIX}" "$1" "$1"; }

  # _lock <file> <name|version|source>... — `path` writes no source line.
  _lock() {
    local file="$1" spec name version source; shift
    mkdir -p "$(dirname "${file}")"
    printf '# This file is automatically @generated by Cargo.\nversion = 4\n' >"${file}"
    for spec in "$@"; do
      IFS='|' read -r name version source <<<"${spec}"
      printf '\n[[package]]\nname = "%s"\nversion = "%s"\n' "${name}" "${version}" >>"${file}"
      [[ "${source}" == path ]] || printf 'source = "%s"\n' "${source}" >>"${file}"
    done
  }
  _pins() { # <tree> <mdk-rev> <openmls-source> <sqlite-source> <sqlite-version>
    mkdir -p "$1/scripts/ci"
    printf 'HAVEN_MDK_REV=%s\nHAVEN_MDK_SOURCE="%s?rev=${HAVEN_MDK_REV}#${HAVEN_MDK_REV}"\nHAVEN_OPENMLS_SOURCE="%s"\nHAVEN_LIBSQLITE3_SOURCE="%s"\nHAVEN_LIBSQLITE3_VERSION=%s\n' \
      "$2" "${MDK_REPO_PREFIX}" "$3" "$4" "$5" >"$1/scripts/ci/mdk_pins.env"
  }
  # A tree whose three roots all resolve <specs>, pinned to <pins...>.
  _tree() { # <tree> <mdk-rev> <openmls-source> <sqlite-source> <sqlite-version> -- <spec>...
    local t="$1" r
    _pins "$1" "$2" "$3" "$4" "$5"; shift 6
    for r in "${CORE}" "${DEPENDENT_ROOTS[@]}"; do _lock "${t}/${r}/Cargo.lock" "$@"; done
  }
  local -a TODAY=("haven-core|0.1.0|path" "cgka-session|0.9.4|$(mdk "${R0}")" "cgka-engine|0.9.4|$(mdk "${R0}")"
                  "storage-sqlite|0.9.4|$(mdk "${R0}")" "openmls|0.8.1|${REG}" "openmls_traits|0.5.0|${REG}"
                  "libsqlite3-sys|0.30.1|${REG}" "nostr|0.44.7|${REG}" "serde|1.0.228|${REG}")
  local -a BUMP=("haven-core|0.1.0|path" "cgka-session|0.10.4|$(mdk "${R1}")" "cgka-engine|0.10.4|$(mdk "${R1}")"
                 "marmot-forensics|0.10.4|$(mdk "${R1}")" "openmls|0.8.1|${FORK}" "openmls_traits|0.5.0|${FORK}"
                 "libsqlite3-sys|0.38.1|${SQLC}" "nostr|0.44.7|${REG}")
  local -a TODAY_PINS=("${R0}" "${REG}" "${REG}" 0.30.1) BUMP_PINS=("${R1}" "${FORK}" "${SQLC}" 0.38.1)

  _case() { # _case <label> <want-rc> <tree>
    local label="$1" want="$2" got=0
    checked=$(( checked + 1 ))
    REPO_ROOT_OVERRIDE="$3" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }
  # _swap <tree> <root> <crate> <source> — re-source one entry in one root.
  _swap() { sed -i "/^name = \"$3\"\$/{n;n;s|.*|source = \"$4\"|}" "$1/$2/Cargo.lock"; }

  echo "check_lockfile_universe.sh --self-test"
  local t r

  t="${tmp}/today"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _case "today's v0.9.4 shape passes" 0 "${t}"

  t="${tmp}/bump"; _tree "${t}" "${BUMP_PINS[@]}" -- "${BUMP[@]}"
  _case "the v0.10.4 shape (fork openmls, patched libsqlite3-sys) passes under its pins" 0 "${t}"

  t="${tmp}/a"; _tree "${t}" "${BUMP_PINS[@]}" -- "${BUMP[@]}"
  _swap "${t}" tooling/soak openmls "${REG}"
  _case "(a) soak registry openmls 0.8.1 against haven-core's fork 0.8.1 fails" 1 "${t}"

  t="${tmp}/b"; _tree "${t}" "${BUMP_PINS[@]}" -- "${BUMP[@]}"
  _swap "${t}" haven/rust_builder libsqlite3-sys "${REG}"
  _case "(b) rust_builder on registry libsqlite3-sys 0.38.1 (a lost [patch]) fails" 1 "${t}"

  t="${tmp}/c"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _swap "${t}" tooling/soak cgka-engine "$(mdk "${R1}")"
  _case "(c) one MDK crate on a different rev fails" 1 "${t}"

  t="${tmp}/d"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _lock "${t}/${CORE}/Cargo.lock" "${TODAY[@]}" "libsqlite3-sys|0.32.0|${REG}"
  _case "(d) two libsqlite3-sys entries fail" 1 "${t}"

  t="${tmp}/subset"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _lock "${t}/tooling/soak/Cargo.lock" "${TODAY[@]}" "nostr-database|0.44.0|${REG}"
  _case "a dependent root resolving a universe crate haven-core does not fails" 1 "${t}"

  t="${tmp}/twover"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _lock "${t}/haven/rust_builder/Cargo.lock" "${TODAY[@]}" "nostr|0.44.8|${REG}"
  _case "a dependent root resolving two nostr versions fails" 1 "${t}"

  # rusqlite and nostr carry no source pin, so only the cross-root comparison
  # sees them split.
  t="${tmp}/nostr-fork"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _swap "${t}" tooling/soak nostr 'git+https://github.com/rust-nostr/nostr?rev=0000000#0000000'
  _case "a nostr from another source at the same version fails" 1 "${t}"

  t="${tmp}/core-twover"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _lock "${t}/${CORE}/Cargo.lock" "${TODAY[@]}" "nostr|0.44.8|${REG}"
  _case "haven-core resolving two nostr versions fails" 1 "${t}"

  t="${tmp}/adapter-ok"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}" "transport-nostr-adapter|0.9.4|$(mdk "${R0}")"
  _case "transport-nostr-adapter on the pinned rev passes" 0 "${t}"

  t="${tmp}/adapter-rev"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}" "transport-nostr-adapter|0.9.4|$(mdk "${R1}")"
  _case "transport-nostr-adapter on another rev fails" 1 "${t}"

  t="${tmp}/mdk-fork"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  for r in "${CORE}" "${DEPENDENT_ROOTS[@]}"; do
    _swap "${t}" "${r}" cgka-engine "git+https://github.com/someone/mdk?rev=${R0}#${R0}"
  done
  _case "an MDK crate from a fork at the pinned rev fails in every root alike" 1 "${t}"

  t="${tmp}/unnamed-mdk"; _tree "${t}" "${BUMP_PINS[@]}" -- "${BUMP[@]}"
  _swap "${t}" "${CORE}" marmot-forensics "$(mdk "${R0}")"
  _swap "${t}" haven/rust_builder marmot-forensics "$(mdk "${R0}")"
  _swap "${t}" tooling/soak marmot-forensics "$(mdk "${R0}")"
  _case "an unnamed MDK-repo crate off the pinned rev fails in every root alike" 1 "${t}"

  t="${tmp}/no-sqlite"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _lock "${t}/tooling/soak/Cargo.lock" "${TODAY[@]:0:6}" "${TODAY[@]:7}"
  _case "libsqlite3-sys missing from a dependent root fails" 1 "${t}"

  t="${tmp}/sqlite-ver"; _tree "${t}" "${R0}" "${REG}" "${REG}" 0.30.2 -- "${TODAY[@]}"
  _case "libsqlite3-sys agreeing everywhere but off the pinned version fails" 1 "${t}"

  t="${tmp}/no-fork"; _tree "${t}" "${BUMP_PINS[@]}" -- "${BUMP[@]}"
  for r in "${CORE}" "${DEPENDENT_ROOTS[@]}"; do _swap "${t}" "${r}" openmls "${REG}"; done
  _case "openmls agreeing everywhere but off the pinned fork fails" 1 "${t}"

  t="${tmp}/outside-u"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  _lock "${t}/tooling/soak/Cargo.lock" "${TODAY[@]:0:8}" "serde|1.0.219|${REG}"
  _case "a crate outside the universe diverging between roots passes" 0 "${t}"

  t="${tmp}/no-lock"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  rm "${t}/haven/rust_builder/Cargo.lock"
  _case "a missing lockfile is a misconfiguration" 2 "${t}"

  t="${tmp}/no-pins"; _tree "${t}" "${TODAY_PINS[@]}" -- "${TODAY[@]}"
  rm "${t}/scripts/ci/mdk_pins.env"
  _case "a missing pin file is a misconfiguration" 2 "${t}"

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
  '') run_check ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
