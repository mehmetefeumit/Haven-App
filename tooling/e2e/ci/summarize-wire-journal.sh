#!/usr/bin/env bash
#
# Produces the UPLOAD-SAFE form of a wire journal, and refuses to hand back
# anything it could not verify.
#
# ## Why the raw journal is never uploaded
#
# The journal is a complete transcript of relay traffic: full event JSON
# (ciphertext, ephemeral pubkeys, ids, signatures), REQ filters carrying
# long-term identity pubkeys, bounded previews of anything unparseable, and a
# `relay_url` on every line mapping all of it to named endpoints. CI artifacts
# live for 14 days on a public repository. A privacy INSTRUMENT that leaves a
# durable copy of everything it observed is a privacy HAZARD, so:
#
#   * the raw `*.ndjson` journal stays on the runner and dies with it, and
#   * this script emits a redacted summary, which is what a lane uploads.
#
# `scripts/ci/check_wire_proxy_test_only.sh` fails CI if any workflow puts a
# `.ndjson` path in an upload-artifact step, so the decision is enforced rather
# than merely documented.
#
# ## What survives redaction
#
# Redaction is an ALLOWLIST inside the binary (see src/summarize.rs), not a
# filter, so a future journal field cannot leak by default. Kept: wire_seq,
# conn_id, dir, type, relay_url, listen, raw_len, event KIND, tag NAMES,
# content LENGTH, REQ filter KEY names and `kinds` values, the OK boolean.
# Dropped: every id, pubkey, signature, content, tag VALUE and filter VALUE,
# every subscription id, all NOTICE/CLOSED text, and the raw_preview (length
# only).
#
# ## "Nothing to summarize" is not "nothing to report"
#
# An absent or empty journal exits non-zero: the proxy either never ran or
# recorded nothing, so the run carries NO wire evidence — which is a finding,
# not a pass. Same reasoning, and the same exit-code convention, as
# scan-logs-for-secrets.sh.
#
# Usage:
#   bash tooling/e2e/ci/summarize-wire-journal.sh <journal.ndjson> <out.log>
#
# Exit codes:
#   0 = summary written and it scanned clean
#   1 = the secret scan flagged the SUMMARY (a redaction bug; nothing uploaded)
#   2 = usage error, or the journal was absent/empty/unreadable

set -uo pipefail

readonly RC_CLEAN=0
readonly RC_LEAK=1
readonly RC_USAGE=2

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <journal.ndjson> <out.log>" >&2
  exit "${RC_USAGE}"
fi

readonly JOURNAL="$1"
readonly OUT="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CRATE_DIR="${SCRIPT_DIR}/../local-relay"
readonly BIN="${CRATE_DIR}/target/release/haven-wire-proxy"

if [[ ! -f "${BIN}" ]]; then
  cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml" --bin haven-wire-proxy || {
    echo "ERROR: could not build haven-wire-proxy; no summary produced." >&2
    exit "${RC_USAGE}"
  }
fi

if ! "${BIN}" --summarize "${JOURNAL}" --out "${OUT}"; then
  echo "ERROR: the wire journal at '${JOURNAL}' could not be summarized." >&2
  echo "       An absent or empty journal is NOT a clean run: the proxy either" >&2
  echo "       never started or recorded nothing, so this lane produced no wire" >&2
  echo "       evidence at all." >&2
  exit "${RC_USAGE}"
fi

# Belt to the allowlist's suspenders. The summary is built field-by-field so it
# CANNOT carry an identifier by construction — but a redaction bug is exactly
# the kind of thing that ships quietly, and this is the repo's existing
# instrument for catching key material in a file about to become an artifact.
if ! bash "${SCRIPT_DIR}/scan-logs-for-secrets.sh" "${OUT}"; then
  rc=$?
  echo "ERROR: the REDACTED wire summary did not scan clean (rc=${rc})." >&2
  echo "       That is a redaction bug in src/summarize.rs, not a lane failure." >&2
  echo "       Removing the summary so it cannot be uploaded." >&2
  rm -f "${OUT}"
  exit "${RC_LEAK}"
fi

echo "wire-journal summary written to ${OUT} (redacted, scanned clean)."
exit "${RC_CLEAN}"
