#!/usr/bin/env bash
# CI guard: the Rule-14 "session busy" marker is a LOG token, never a routing
# input.
#
# `SESSION_BUSY_MARKER` ("HAVEN_E_SESSION_BUSY") is embedded in the error
# `LiveSessionGuard::acquire` returns when a live MLS session already holds the
# database. Its ONLY purpose is to make that one condition greppable in a log or
# a bug report.
#
# It must never drive a decision, because Haven's FFI errors are flattened prose
# and several of them interpolate REMOTE-AUTHORED text. Concretely: a circle
# admin controls the group's routing relay list, the live-sync relay gate
# formats a rejected URL into its error message, and `redact_hex_sequences` only
# collapses long hex runs — so it preserves a planted marker as faithfully as a
# genuine one. A relay of `ws://host/HAVEN_E_SESSION_BUSY` would therefore make
# a substring test read an unrelated failure as "session busy", handing a remote
# party a one-bit control channel over a local recovery decision. In the
# Android foreground service that decision tears down the foreground's live-sync
# engine, so the result is a remotely-triggerable, silent loss of location
# receive in a safety app.
#
# The supported way to ask "is the Rule-14 guard held?" is the registry lookup
# `is_session_live` (haven-core) / `isSessionLive` (Dart), which reads
# process-local state that no remote party can write.
#
# Checks:
#   1. Dart must never spell the marker literal. Dart routes via `isSessionLive`
#      and has no legitimate reason to know the token; a copy would also be a
#      drifting duplicate of a Rust constant.
#   2. No Rust `contains`/`starts_with`/`ends_with`/`find`/`matches` over the
#      marker (by constant name or literal) outside the guard's own definition
#      and its log-shape test — that is the prose-routing pattern itself.
#
# Pure-grep gate (no toolchain) so it runs in seconds alongside the other repo
# guards.

set -euo pipefail

cd "$(dirname "$0")/../.."

MARKER='HAVEN_E_SESSION_BUSY'
CONST='SESSION_BUSY_MARKER'
status=0

# --- 1. Hand-written Dart must not carry the literal --------------------------
# `haven/lib/src/rust/` is excluded: flutter_rust_bridge copies Rust doc
# comments verbatim into the generated bindings, so the doc EXPLAINING this ban
# would otherwise trip it. Generated code is not hand-written routing logic, and
# it is rewritten wholesale by `scripts/regenerate_frb.sh`, so a literal there
# is never a decision — it is a copied sentence.
if dart_hits=$(grep -rn --include='*.dart' -- "$MARKER" haven/lib haven/test \
    haven/integration_test 2>/dev/null | grep -v '^haven/lib/src/rust/'); then
  echo "ERROR: the session-busy marker literal appears in Dart:"
  echo "$dart_hits"
  echo
  echo "Dart must not know this token. Ask the registry instead:"
  echo "    await isSessionLive(dataDir: dir)"
  echo "which cannot be influenced by any error string. See"
  echo "haven-core/src/nostr/mls/storage.rs (SESSION_BUSY_MARKER) for why."
  status=1
fi

# --- 2. No Rust string-matching over the marker ------------------------------
# Allowed: the const definition, the `format!` that embeds it, doc/comment prose,
# and the one test asserting the LOG shape (`flattened.contains(...)`).
ALLOWED_RE='^haven-core/src/nostr/mls/storage.rs:'

if rust_hits=$(grep -rnE --include='*.rs' \
    "(contains|starts_with|ends_with|find|matches)\s*\(\s*[^)]*($CONST|\"$MARKER\")" \
    haven-core/src haven/rust_builder/src 2>/dev/null \
    | grep -vE "$ALLOWED_RE" || true); [ -n "$rust_hits" ]; then
  echo "ERROR: Rust code matches on the session-busy marker to make a decision:"
  echo "$rust_hits"
  echo
  echo "This is the remotely-influenceable pattern this guard exists to ban."
  echo "Use the registry lookup instead:"
  echo "    haven_core::nostr::mls::storage::is_session_live(&db_path)"
  status=1
fi

# --- 3. Self-check: the marker and the supported query must both still exist --
# Without this the guard passes vacuously if either is renamed away.
if ! grep -q "pub const $CONST" haven-core/src/nostr/mls/storage.rs; then
  echo "ERROR: $CONST is gone from haven-core/src/nostr/mls/storage.rs."
  echo "If the marker was deliberately removed, delete this guard too —"
  echo "do not leave it passing over nothing."
  status=1
fi
if ! grep -q 'pub fn is_session_live' haven-core/src/nostr/mls/storage.rs; then
  echo "ERROR: is_session_live is gone from haven-core/src/nostr/mls/storage.rs."
  echo "It is the supported alternative this guard redirects callers to;"
  echo "without it the guidance above is a dead end."
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "OK: session-busy marker is log-only; liveness is queried from the registry."
fi
exit "$status"
