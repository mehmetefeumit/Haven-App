#!/usr/bin/env bash
#
# CI network-egress guard: SECONDARY run-time layer against accidental
# EXTERNAL relay / CDN / Blossom HTTP egress during the hermetic E2E lanes
# (e2e_combined + e2e_profile_sharing).
#
# ## PRIMARY guarantee (build-time)
#
# The static grep-gate scripts/ci/check_profile_privacy_boundaries.sh proves
# at build time that no Dart file renders a picture via Image.network (profile
# pictures are downloaded by Rust with connect-time anti-SSRF IP filtering and
# rendered from bytes), that Blossom traffic is HTTPS-only, and that kind-0
# construction stays confined to the profile module. That static check is the
# load-bearing privacy guarantee.
#
# ## This script (run-time belt)
#
# Installs iptables OUTPUT rules on the GITHUB-HOSTED RUNNER HOST that reject
# outbound TCP port 80 and 443. The hermetic test's own traffic is loopback —
# the strfry WebSocket (ws://127.0.0.1:$STRFRY_PORT) and, for the profile lane,
# the local Blossom server (http://127.0.0.1:3000) — neither of which touches
# port 80/443, so both keep working. Any accidental EXTERNAL HTTP/HTTPS call
# (a real relay, CDN, or Blossom host) receives an immediate TCP RST, failing
# the test rather than silently succeeding.
#
# ## Scope / topology note
#
# The Android emulator uses QEMU SLIRP userspace networking: the emulator
# proxies guest TCP connections through host sockets. This means emulator
# outbound traffic appears as host socket traffic and IS subject to the
# host OUTPUT chain rules installed here. This is an empirical property of
# QEMU SLIRP on GitHub Actions ubuntu-latest runners; it is NOT enforced by
# a guest-side mechanism under our control.
#
# The rules reject:
#   TCP port 80  (plain HTTP)  → accidental Blossom / CDN upload RST
#   TCP port 443 (HTTPS)       → accidental CDN/REST call RST
#
# The rules permit:
#   loopback (lo)              → ADB on 5037, relay WebSocket, emulator
#                                control ports 5554-5585
#   Docker bridge 172.16/12   → strfry container startup DNS / internal
#   ESTABLISHED/RELATED        → return traffic for already-open sockets
#
# IMPORTANT: This script must be called AFTER strfry has successfully started
# (tooling/e2e/ci/start-strfry.sh) and BEFORE flutter drive runs. The strfry
# container's port is published on 127.0.0.1:$STRFRY_PORT; rejecting 80/443
# on the outbound host interface does not affect that loopback connection.
#
# Rollback: the rules are installed in a dedicated iptables chain
# HAVEN_E2E_GUARD; the last step in the workflow (stop-strfry.sh or a
# dedicated teardown) can flush it, but on GitHub-hosted ephemeral runners
# the whole environment is discarded after the job, so no rollback is needed.
#
# Usage:
#   bash tooling/e2e/ci/setup-network-guard.sh
#
# Optional env:
#   STRFRY_PORT   Host port strfry is listening on (default: 7777).
#   SKIP_GUARD    Set to "1" to skip guard installation (local dev override).

set -euo pipefail

readonly STRFRY_PORT="${STRFRY_PORT:-7777}"
readonly CHAIN="HAVEN_E2E_GUARD"

if [[ "${SKIP_GUARD:-}" == "1" ]]; then
  echo "[setup-network-guard] SKIP_GUARD=1 — skipping iptables rules (local dev mode)."
  exit 0
fi

# Verify iptables is available.
if ! command -v iptables >/dev/null 2>&1; then
  echo "ERROR: iptables not found; cannot install network guard." >&2
  exit 1
fi

echo "[setup-network-guard] Installing iptables egress guard (strfry port=${STRFRY_PORT})..."

# Create the dedicated chain (idempotent: flush if it already exists).
if sudo iptables -L "${CHAIN}" -n >/dev/null 2>&1; then
  sudo iptables -F "${CHAIN}"
else
  sudo iptables -N "${CHAIN}"
fi

# --- Rules inside HAVEN_E2E_GUARD (evaluated top-to-bottom) ---

# 1. Allow all traffic on the loopback interface (covers the relay WebSocket,
#    ADB server on :5037, and the emulator control ports :5554-5585).
sudo iptables -A "${CHAIN}" -o lo -j ACCEPT

# 2. Allow already-established or related connections (return traffic for
#    the strfry WebSocket connection the emulator/test process opens).
sudo iptables -A "${CHAIN}" -m state --state ESTABLISHED,RELATED -j ACCEPT

# 3. Allow traffic to the Docker bridge subnet (strfry container; the bridge
#    interface is docker0 by convention — use the subnet so the rule works
#    even if the interface name differs on the runner).
sudo iptables -A "${CHAIN}" -d 172.16.0.0/12 -j ACCEPT

# 4. REJECT outbound plain HTTP (port 80).  Any accidental Blossom / CDN
#    upload or HTTP fetch will receive a TCP RST and cause an immediate
#    connection error in the test — surfaced as a test failure, not a hang.
sudo iptables -A "${CHAIN}" -p tcp --dport 80 -j REJECT --reject-with tcp-reset

# 5. REJECT outbound HTTPS (port 443).  CDN/REST calls (S3, Cloudflare R2,
#    etc.) also receive an immediate RST.
sudo iptables -A "${CHAIN}" -p tcp --dport 443 -j REJECT --reject-with tcp-reset

# --- Jump from OUTPUT into our chain ---
# Remove any stale jump first so the install is idempotent on a reused runner.
sudo iptables -D OUTPUT -j "${CHAIN}" 2>/dev/null || true
sudo iptables -I OUTPUT 1 -j "${CHAIN}"

echo "[setup-network-guard] Rules installed:"
sudo iptables -L "${CHAIN}" -n -v --line-numbers

echo "[setup-network-guard] Done. Outbound TCP 80/443 will be rejected for the remainder of this job."
