#!/usr/bin/env bash
# CI guard: MDK supply-chain shape, in every lockfile that builds haven-core
# (haven-core, haven/rust_builder — the one that ships — and tooling/soak).
#
# Haven depends on exactly six crates from marmot-protocol/mdk —
# cgka-session, cgka-engine, cgka-traits, storage-sqlite,
# transport-nostr-peeler, transport-nostr-adapter (for its kind-30443
# KeyPackage event template and, behind its one feature `sdk`, its relay
# client) — pinned to the release rev in scripts/ci/mdk_pins.env (migration
# plan §5.1).
# Everything else the mdk workspace ships is deliberately OUT of Haven's
# graph: the uniffi/app/account layers duplicate Haven's own FFI + identity
# planes, the QUIC transports and agent crates pull large unaudited surface,
# and the legacy mdk-core stack must never resurrect alongside the new one
# (two MLS stacks = divergent group state and duplicate storage). The
# lockfile is the ground truth for what actually ships, so this gate reads
# the lockfiles directly — no cargo invocation, no network (security
# finding F8c). Whether the three lockfiles agree with EACH OTHER is
# check_lockfile_universe.sh's question.
#
# Matching is anchored to lockfile `name = "<crate>"` lines so a path,
# comment, or feature string can never false-positive.
#
# Checks, per lockfile:
#   1. No forbidden mdk-workspace/uniffi crate is present (list below).
#   2. All six required Dark Matter crates are present, each resolved from
#      exactly HAVEN_MDK_SOURCE (the pinned rev).
#   3. `libsqlite3-sys` has exactly ONE entry, with HAVEN_LIBSQLITE3_VERSION
#      and HAVEN_LIBSQLITE3_SOURCE — it is a `links = "sqlite3"` crate, so
#      SQLCipher symbols must come from exactly one vendored build, and the
#      one it comes from is pinned.
#   4. No legacy mdk-* crate (mdk-core / mdk-sqlite-storage /
#      mdk-storage-traits) remains.
#   5. `transport-nostr-adapter` depends on exactly ADAPTER_DEPS. `nostr-sdk`
#      among them is what its `sdk` feature looks like in a lockfile; anything
#      more is a feature nobody reviewed, and `nostr-sdk` missing from one
#      lockfile is a root that builds another adapter than the one Haven's
#      fanout calls.
#
# A feature that only gates code adds no dependency, so the lockfile cannot
# show it. `--adapter-features` asks cargo instead: in each of the three roots
# the adapter's enabled features must be exactly `default` and `sdk`. It needs
# cargo and the resolved sources, so it runs in rust-check.yml, not in the
# pure-grep guard job; its parsing is covered by the self-test.
#
# Usage:
#   bash scripts/ci/check_mdk_supply_chain.sh
#   bash scripts/ci/check_mdk_supply_chain.sh --adapter-features
#   bash scripts/ci/check_mdk_supply_chain.sh --self-test
#
# Exit codes:
#   0  all checks pass (or the self-test passed)
#   1  the dependency graph violates the supply-chain shape (or the self-test
#      failed)
#   2  expected files missing, or cargo could not print the tree
#      (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly -a LOCKFILES=(haven-core/Cargo.lock haven/rust_builder/Cargo.lock tooling/soak/Cargo.lock)

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=18

# What the adapter links with `sdk` on and nothing else (its Cargo.toml at the
# pinned rev: every non-optional dependency, plus `nostr-sdk`).
readonly ADAPTER_DEPS='async-trait cgka-traits hex nostr nostr-sdk serde serde_json sha2 tokio tracing transport-nostr-peeler'
readonly ADAPTER_FEATURES='default sdk'

# Crates from the mdk workspace (or its uniffi surface) that must NEVER enter
# Haven's graph. `uniffi` itself is listed because any uniffi binding layer
# would drag it in as its top-level marker.
readonly -a FORBIDDEN_CRATES=(
  marmot-uniffi
  marmot-app
  marmot-account
  transport-quic-stream
  transport-quic-broker
  agent-control
  agent-stream-compose
  agent-connector
  cgka-conformance-simulator
  incident-replay
  uniffi
)

# The six crates Haven's Dark Matter port names directly (plan §5.1).
readonly -a REQUIRED_CRATES=(
  cgka-session
  cgka-engine
  cgka-traits
  storage-sqlite
  transport-nostr-peeler
  transport-nostr-adapter
)

# Legacy pre-Dark-Matter crates; any survivor means the old MLS stack is
# still in the graph next to the new one.
readonly -a LEGACY_CRATES=(
  mdk-core
  mdk-sqlite-storage
  mdk-storage-traits
)

log() {
  printf '\033[1;34m[check_mdk_supply_chain]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_mdk_supply_chain] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

# One `version source` row per [[package]] block named <crate>; a path
# dependency has no `source` line and reads as `path`.
entries() { # <lockfile> <crate>
  awk -v c="$2" '
    function flush() { if (pkg && n == c) print v " " s }
    /^\[/ { flush(); pkg = ($0 == "[[package]]"); n = ""; v = ""; s = "path"; next }
    pkg && /^name = /    { n = $3; gsub(/"/, "", n) }
    pkg && /^version = / { v = $3; gsub(/"/, "", v) }
    pkg && /^source = /  { s = $3; gsub(/"/, "", s) }
    END { flush() }
  ' "$1"
}

# The dependency NAMES of <crate>'s one [[package]] block, sorted, on one line.
# A lockfile writes `"sha2 0.10.9"` when two versions share a name.
dep_names() { # <lockfile> <crate>
  awk -v c="$2" '
    /^\[/ { pkg = ($0 == "[[package]]"); n = ""; deps = 0; next }
    pkg && /^name = / { n = $3; gsub(/"/, "", n) }
    pkg && n == c && /^dependencies = \[/ { deps = 1; next }
    deps && /^\]/ { deps = 0 }
    deps { d = $1; gsub(/[",]/, "", d); print d }
  ' "$1" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

# stdin: `cargo tree -e features -i transport-nostr-adapter`. Prints the
# adapter's enabled features, sorted, on one line.
adapter_features() {
  { grep -oE 'transport-nostr-adapter feature "[^"]+"' || true; } \
    | sed -E 's/.*"([^"]+)"/\1/' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

# stdin as adapter_features; <label> names the root in the message.
judge_adapter_features() { # <label>
  local got
  got="$(adapter_features)"
  if [[ "${got}" != "${ADAPTER_FEATURES}" ]]; then
    fail "transport-nostr-adapter is built with feature(s) '${got}' in $1, not exactly '${ADAPTER_FEATURES}'. \`sdk\` is its relay client, which Haven's fanout hands the publish client; any other feature is MDK code nobody reviewed for Security Rules 15 and 16, and without \`sdk\` that root builds an adapter the fanout cannot call."
  fi
}

check_lockfile() { # <repo-relative lockfile>
  local rel="$1" lockfile="${REPO_ROOT}/$1" crate got
  [[ -f "${lockfile}" ]] || { echo "ERROR: ${lockfile} not found" >&2; exit 2; }

  # Check 1: no forbidden mdk-workspace/uniffi crate in the graph.
  for crate in "${FORBIDDEN_CRATES[@]}"; do
    if grep -qE "^name = \"${crate}\"\$" "${lockfile}"; then
      fail "forbidden crate '${crate}' is in ${rel} — Haven's graph must contain ONLY the six Dark Matter crates from marmot-protocol/mdk, never the uniffi/app/account/QUIC/agent/simulator layers (plan §5.1 / security F8c)"
    fi
  done

  # Check 2: all six required Dark Matter crates present, on the pinned rev.
  local missing=""
  for crate in "${REQUIRED_CRATES[@]}"; do
    got="$(entries "${lockfile}" "${crate}")"
    if [[ -z "${got}" ]]; then
      missing+=" ${crate}"
    elif [[ "${got#* }" != "${HAVEN_MDK_SOURCE}" ]]; then
      fail "${crate} in ${rel} resolves from '${got//$'\n'/; }', not the pinned MDK source '${HAVEN_MDK_SOURCE}' (scripts/ci/mdk_pins.env) — move the pin and every manifest rev together, to a released tag"
    fi
  done
  if [[ -n "${missing}" ]]; then
    fail "required Dark Matter crate(s) missing from ${rel}:${missing} — Haven names all six directly (cgka-session imports engine types without re-exporting them, so cgka-engine must be a direct dependency; plan §5.1)"
  fi

  # Check 3: exactly one libsqlite3-sys, from the pinned source (links-crate
  # invariant).
  got="$(entries "${lockfile}" libsqlite3-sys)"
  if [[ -z "${got}" ]]; then
    # Unreachable while storage-sqlite passes check 2 (it depends on rusqlite →
    # libsqlite3-sys); zero hits means a truncated/corrupt lockfile.
    echo "ERROR: no libsqlite3-sys package in ${lockfile} — lockfile looks truncated" >&2
    exit 2
  fi
  if [[ "${got}" == *$'\n'* ]]; then
    fail "libsqlite3-sys appears $(grep -c . <<<"${got}") times in ${rel} (${got//$'\n'/; }) — it is a links = \"sqlite3\" crate and must resolve to ONE build (a dependency drifted off storage-sqlite's rusqlite line, breaking the single-SQLCipher-build invariant)"
  fi
  if [[ "${got}" != "${HAVEN_LIBSQLITE3_VERSION} ${HAVEN_LIBSQLITE3_SOURCE}" ]]; then
    fail "libsqlite3-sys in ${rel} is '${got}', not the pinned '${HAVEN_LIBSQLITE3_VERSION} ${HAVEN_LIBSQLITE3_SOURCE}' (scripts/ci/mdk_pins.env) — the SQLCipher Haven ships must be the one it pins"
  fi

  # Check 4: no legacy pre-Dark-Matter mdk-* crate remains.
  for crate in "${LEGACY_CRATES[@]}"; do
    if grep -qE "^name = \"${crate}\"\$" "${lockfile}"; then
      fail "legacy crate '${crate}' is still in ${rel} — the pre-Dark-Matter mdk stack was fully replaced by the six-crate set and must not resurrect alongside it (two MLS stacks = divergent group state)"
    fi
  done

  # Check 5: the adapter links its relay client and nothing unreviewed.
  got="$(dep_names "${lockfile}" transport-nostr-adapter)"
  if [[ "${got}" != "${ADAPTER_DEPS}" ]]; then
    fail "transport-nostr-adapter in ${rel} depends on '${got}', not exactly '${ADAPTER_DEPS}'. \`nostr-sdk\` there is its \`sdk\` feature — the relay client Haven's fanout publishes through; a missing one is a root building a different adapter, and anything extra is a feature or an MDK change nobody reviewed (re-derive ADAPTER_DEPS from its Cargo.toml when the pin moves)."
  fi
}

run_adapter_features() {
  local rel tree
  for rel in "${LOCKFILES[@]}"; do
    log "Asking cargo for the adapter's features in ${rel%/Cargo.lock} ..."
    if ! tree="$(cd "${REPO_ROOT}/${rel%/Cargo.lock}" && cargo tree --locked -e features -i transport-nostr-adapter)"; then
      echo "ERROR: cargo could not print the adapter's feature tree in ${rel%/Cargo.lock}" >&2
      exit 2
    fi
    judge_adapter_features "${rel%/Cargo.lock}" <<<"${tree}"
  done
  log "OK: transport-nostr-adapter is built with exactly '${ADAPTER_FEATURES}' in ${#LOCKFILES[@]} roots."
}

run_check() {
  local pins="${REPO_ROOT}/scripts/ci/mdk_pins.env" rel
  [[ -f "${pins}" ]] || { echo "ERROR: ${pins} not found" >&2; exit 2; }
  # shellcheck source=mdk_pins.env
  source "${pins}"
  for rel in "${LOCKFILES[@]}"; do
    log "Checking ${rel} ..."
    check_lockfile "${rel}"
  done
  log "OK: MDK supply chain holds its shape in ${#LOCKFILES[@]} lockfiles — six Dark Matter crates on the pinned rev, no forbidden layers, no legacy mdk-*, one libsqlite3-sys from the pinned source, the adapter linking its relay client and nothing else."
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is a whole tree (three lockfiles and a pin file) run
# through the real entry point. One plant per direction of every check, placed
# in a lockfile other than haven-core's wherever the check is per-lockfile, so
# a guard that silently went back to reading one lockfile fails here.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local REG='registry+https://github.com/rust-lang/crates.io-index'
  local REV='e391adc133a9b60e420da7a0446f014a180ac8d2' OTHER='fcc85edd8dbd07c8293c899ee52230f72c54c897'
  local MDK="git+https://github.com/marmot-protocol/mdk?rev=${REV}#${REV}"

  _lock() { # <file> <name|version|source[|dependency ...]>...
    local file="$1" spec name version source deps dep; shift
    mkdir -p "$(dirname "${file}")"
    printf '# This file is automatically @generated by Cargo.\nversion = 4\n' >"${file}"
    for spec in "$@"; do
      IFS='|' read -r name version source deps <<<"${spec}"
      printf '\n[[package]]\nname = "%s"\nversion = "%s"\nsource = "%s"\n' "${name}" "${version}" "${source}" >>"${file}"
      if [[ -n "${deps}" ]]; then
        printf 'dependencies = [\n' >>"${file}"
        # `sha2` is written with its version, as in the real lockfiles.
        for dep in ${deps}; do printf ' "%s",\n' "${dep/#sha2/sha2 0.10.9}" >>"${file}"; done
        printf ']\n' >>"${file}"
      fi
    done
  }
  local -a GOOD=()
  local c; for c in "${REQUIRED_CRATES[@]:0:5}"; do GOOD+=("${c}|0.9.4|${MDK}"); done
  GOOD+=("transport-nostr-adapter|0.9.4|${MDK}|${ADAPTER_DEPS}")
  GOOD+=("libsqlite3-sys|0.30.1|${REG}" "rusqlite|0.32.1|${REG}")
  _tree() { # <tree> <spec>... — every lockfile GOOD, the soak one GOOD + <spec>...
    local t="$1" rel; shift
    mkdir -p "${t}/scripts/ci"
    printf 'HAVEN_MDK_REV=%s\nHAVEN_MDK_SOURCE="git+https://github.com/marmot-protocol/mdk?rev=${HAVEN_MDK_REV}#${HAVEN_MDK_REV}"\nHAVEN_LIBSQLITE3_SOURCE="%s"\nHAVEN_LIBSQLITE3_VERSION=0.30.1\n' \
      "${REV}" "${REG}" >"${t}/scripts/ci/mdk_pins.env"
    for rel in "${LOCKFILES[@]}"; do _lock "${t}/${rel}" "${GOOD[@]}"; done
    _lock "${t}/tooling/soak/Cargo.lock" "${GOOD[@]}" "$@"
  }
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

  echo "check_mdk_supply_chain.sh --self-test"
  local t="${tmp}/ok"; _tree "${t}"
  _case "the pinned six-crate shape passes in all three lockfiles" 0 "${t}"

  t="${tmp}/forbidden-builder"; _tree "${t}"
  _lock "${t}/haven/rust_builder/Cargo.lock" "${GOOD[@]}" "marmot-account|0.9.4|${MDK}"
  _case "a forbidden crate in the SHIPPED lockfile alone fails" 1 "${t}"

  t="${tmp}/forbidden-soak"; _tree "${t}" "uniffi|0.29.0|${REG}"
  _case "a forbidden crate in the soak lockfile alone fails" 1 "${t}"

  t="${tmp}/missing"; _tree "${t}"
  _lock "${t}/haven/rust_builder/Cargo.lock" "${GOOD[@]:1}"
  _case "a required crate missing from one lockfile fails" 1 "${t}"

  t="${tmp}/rev"; _tree "${t}"
  _lock "${t}/tooling/soak/Cargo.lock" "${GOOD[@]:0:4}" \
    "transport-nostr-peeler|0.10.4|git+https://github.com/marmot-protocol/mdk?rev=${OTHER}#${OTHER}" "${GOOD[@]:5}"
  _case "a required crate off the pinned rev fails" 1 "${t}"

  t="${tmp}/adapter-rev"; _tree "${t}"
  _lock "${t}/haven/rust_builder/Cargo.lock" "${GOOD[@]:0:5}" \
    "transport-nostr-adapter|0.10.4|git+https://github.com/marmot-protocol/mdk?rev=${OTHER}#${OTHER}" "${GOOD[@]:6}"
  _case "the adapter off the pinned rev fails" 1 "${t}"

  # Check 5, both directions, each in a lockfile other than haven-core's.
  t="${tmp}/adapter-no-sdk"; _tree "${t}"
  _lock "${t}/haven/rust_builder/Cargo.lock" "${GOOD[@]:0:5}" \
    "transport-nostr-adapter|0.9.4|${MDK}|${ADAPTER_DEPS/ nostr-sdk/}" "${GOOD[@]:6}"
  _case "the adapter without its relay client in the SHIPPED lockfile fails" 1 "${t}"

  t="${tmp}/adapter-extra"; _tree "${t}"
  _lock "${t}/tooling/soak/Cargo.lock" "${GOOD[@]:0:5}" \
    "transport-nostr-adapter|0.9.4|${MDK}|${ADAPTER_DEPS} tracing-subscriber" "${GOOD[@]:6}"
  _case "the adapter with a dependency nobody reviewed fails" 1 "${t}"

  t="${tmp}/two-sqlite"; _tree "${t}" "libsqlite3-sys|0.28.0|${REG}"
  _case "two libsqlite3-sys entries fail" 1 "${t}"

  t="${tmp}/sqlite-source"; _tree "${t}"
  _lock "${t}/haven/rust_builder/Cargo.lock" "${GOOD[@]:0:6}" \
    "libsqlite3-sys|0.30.1|git+https://github.com/rusqlite/rusqlite.git?rev=5ae7fdf83085c595fd54f977b3a56ccacabaf16b#5ae7fdf83085c595fd54f977b3a56ccacabaf16b" "${GOOD[@]:7}"
  _case "one libsqlite3-sys from a source other than the pinned one fails" 1 "${t}"

  t="${tmp}/legacy"; _tree "${t}" "mdk-core|0.7.1|${REG}"
  _case "a legacy mdk-* crate fails" 1 "${t}"

  # Name anchoring: the forbidden name inside another crate's name or a
  # dependency list is not the crate.
  t="${tmp}/anchored"; _tree "${t}" "marmot-account-docs|0.1.0|${REG}"
  printf 'dependencies = [\n "marmot-account",\n]\n' >>"${t}/tooling/soak/Cargo.lock"
  _case "a forbidden name that is not a package name passes" 0 "${t}"

  t="${tmp}/no-lock"; _tree "${t}"
  rm "${t}/tooling/soak/Cargo.lock"
  _case "a missing lockfile is a misconfiguration" 2 "${t}"

  t="${tmp}/no-pins"; _tree "${t}"
  rm "${t}/scripts/ci/mdk_pins.env"
  _case "a missing pin file is a misconfiguration" 2 "${t}"

  # --adapter-features: the judgement over real `cargo tree -e features -i
  # transport-nostr-adapter` output (haven/rust_builder, 2026-10-06), and over
  # that output with the relay client off and with a feature added.
  local TREE='transport-nostr-adapter v0.10.4 (https://github.com/marmot-protocol/mdk?rev=fcc85edd8dbd07c8293c899ee52230f72c54c897#fcc85edd)
├── transport-nostr-adapter feature "default"
│   └── haven-core v0.1.0 (/work/haven-core)
│       ├── haven-core feature "default"
│       │   └── rust_lib_haven v0.1.0 (/work/haven/rust_builder)
│       └── haven-core feature "test-utils"
│           [dev-dependencies]
│           └── rust_lib_haven v0.1.0 (/work/haven/rust_builder) (*)
└── transport-nostr-adapter feature "sdk"
    └── haven-core v0.1.0 (/work/haven-core) (*)'
  _features() { # <label> <want-rc> <tree text>
    local label="$1" want="$2" got=0
    checked=$(( checked + 1 ))
    ( judge_adapter_features fixture <<<"$3" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }
  _features "features: default and sdk pass" 0 "${TREE}"
  _features "features: the relay client off fails" 1 "$(grep -v 'feature "sdk"' <<<"${TREE}")"
  _features "features: a feature nobody reviewed fails" 1 "${TREE}
└── transport-nostr-adapter feature \"quic\""
  _features "features: a tree that names no adapter feature fails" 1 'error: package ID specification `transport-nostr-adapter` did not match any packages'

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
  --adapter-features) run_adapter_features ;;
  '') run_check ;;
  *) echo "usage: $(basename "$0") [--adapter-features | --self-test]" >&2; exit 2 ;;
esac
