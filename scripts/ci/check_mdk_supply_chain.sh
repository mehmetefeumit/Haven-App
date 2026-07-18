#!/usr/bin/env bash
# CI guard: MDK "Dark Matter" supply-chain shape (haven-core/Cargo.lock).
#
# Haven depends on exactly five crates from marmot-protocol/mdk v0.9.4 —
# cgka-session, cgka-engine, cgka-traits, storage-sqlite,
# transport-nostr-peeler — pinned to the release rev (migration plan §5.1).
# Everything else the mdk workspace ships is deliberately OUT of Haven's
# graph: the uniffi/app/account layers duplicate Haven's own FFI + identity
# planes, the QUIC transports and agent crates pull large unaudited surface,
# and the legacy mdk-core stack must never resurrect alongside the new one
# (two MLS stacks = divergent group state and duplicate storage). The
# lockfile is the ground truth for what actually ships, so this gate greps
# haven-core/Cargo.lock directly — no cargo invocation, no network (security
# finding F8c).
#
# Matching is anchored to lockfile `name = "<crate>"` lines so a path,
# comment, or feature string can never false-positive.
#
# Checks:
#   1. No forbidden mdk-workspace/uniffi crate is present (list below).
#   2. All five required Dark Matter crates are present.
#   3. `libsqlite3-sys` resolves to a SINGLE version — it is a
#      `links = "sqlite3"` crate, so SQLCipher symbols must come from exactly
#      one vendored build; a second version means a dependency drifted off
#      storage-sqlite's rusqlite line.
#   4. No legacy mdk-* crate (mdk-core / mdk-sqlite-storage /
#      mdk-storage-traits) remains.
#
# Exit codes:
#   0  all checks pass
#   1  the dependency graph violates the supply-chain shape
#   2  expected files missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCKFILE="${REPO_ROOT}/haven-core/Cargo.lock"

# Crates from the mdk workspace (or its uniffi surface) that must NEVER enter
# Haven's graph. `uniffi` itself is listed because any uniffi binding layer
# would drag it in as its top-level marker.
readonly -a FORBIDDEN_CRATES=(
  marmot-uniffi
  marmot-app
  marmot-account
  transport-nostr-adapter
  transport-quic-stream
  transport-quic-broker
  agent-control
  agent-stream-compose
  agent-connector
  cgka-conformance-simulator
  incident-replay
  uniffi
)

# The five crates Haven's Dark Matter port names directly (plan §5.1).
readonly -a REQUIRED_CRATES=(
  cgka-session
  cgka-engine
  cgka-traits
  storage-sqlite
  transport-nostr-peeler
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

[[ -f "${LOCKFILE}" ]] || { echo "ERROR: ${LOCKFILE} not found" >&2; exit 2; }

# crate_count <name>: number of lockfile `name = "<name>"` lines (exact match).
crate_count() {
  grep -cE "^name = \"$1\"\$" "${LOCKFILE}" || true
}

# ---------------------------------------------------------------------------
# Check 1: no forbidden mdk-workspace/uniffi crate in the graph.
# ---------------------------------------------------------------------------
log "Checking for forbidden mdk-workspace/uniffi crates ..."
for crate in "${FORBIDDEN_CRATES[@]}"; do
  if grep -qE "^name = \"${crate}\"\$" "${LOCKFILE}"; then
    fail "forbidden crate '${crate}' is in haven-core/Cargo.lock — Haven's graph must contain ONLY the five Dark Matter crates from marmot-protocol/mdk, never the uniffi/app/account/QUIC/agent/simulator layers (plan §5.1 / security F8c)"
  fi
done

# ---------------------------------------------------------------------------
# Check 2: all five required Dark Matter crates present.
# ---------------------------------------------------------------------------
log "Checking the five required Dark Matter crates are present ..."
missing=""
for crate in "${REQUIRED_CRATES[@]}"; do
  grep -qE "^name = \"${crate}\"\$" "${LOCKFILE}" || missing+=" ${crate}"
done
if [[ -n "${missing}" ]]; then
  fail "required Dark Matter crate(s) missing from haven-core/Cargo.lock:${missing} — Haven names all five directly (cgka-session imports engine types without re-exporting them, so cgka-engine must be a direct dependency; plan §5.1)"
fi

# ---------------------------------------------------------------------------
# Check 3: libsqlite3-sys is single-version (links-crate invariant).
# ---------------------------------------------------------------------------
log "Checking libsqlite3-sys resolves to a single version ..."
sqlite_count="$(crate_count libsqlite3-sys)"
if (( sqlite_count == 0 )); then
  # Unreachable while storage-sqlite passes check 2 (it depends on rusqlite →
  # libsqlite3-sys); zero hits means a truncated/corrupt lockfile.
  echo "ERROR: no 'name = \"libsqlite3-sys\"' line in ${LOCKFILE} — lockfile looks truncated" >&2
  exit 2
fi
if (( sqlite_count > 1 )); then
  grep -nE '^name = "libsqlite3-sys"$' "${LOCKFILE}" >&2 || true
  fail "libsqlite3-sys appears ${sqlite_count} times in haven-core/Cargo.lock — it is a links = \"sqlite3\" crate and must resolve to ONE version (a dependency drifted off storage-sqlite's rusqlite line, breaking the single-SQLCipher-build invariant)"
fi

# ---------------------------------------------------------------------------
# Check 4: no legacy pre-Dark-Matter mdk-* crate remains.
# ---------------------------------------------------------------------------
log "Checking no legacy pre-Dark-Matter mdk-* crate remains ..."
for crate in "${LEGACY_CRATES[@]}"; do
  if grep -qE "^name = \"${crate}\"\$" "${LOCKFILE}"; then
    fail "legacy crate '${crate}' is still in haven-core/Cargo.lock — the pre-Dark-Matter mdk stack was fully replaced by the five-crate v0.9.4 set and must not resurrect alongside it (two MLS stacks = divergent group state)"
  fi
done

log "OK: MDK supply chain holds its shape — five Dark Matter crates, no forbidden layers, no legacy mdk-*, single libsqlite3-sys."
