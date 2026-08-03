#!/usr/bin/env bash
# CI guard: exactly one isolate may own the foreground-task communication port.
#
# `FlutterForegroundTask.initCommunicationPort()` does
# `IsolateNameServer.removePortNameMapping(<name>)` and then registers ITS OWN
# port under that name. It is a takeover, not a join.
#
# Haven runs three isolates in one VM: the UI isolate, the foreground-service
# task isolate, and the WorkManager catch-up worker. Only the UI isolate calls
# `initCommunicationPort()`, and only the UI isolate installs the liveness
# responder (`registerForegroundLivenessResponder`) that answers the foreground
# service's "are you still alive?" probes.
#
# If a second isolate ever called `initCommunicationPort()` — the natural thing
# to copy-paste when adding worker->UI messaging — it would silently steal the
# port name. Every probe would then route to an isolate with no responder, both
# probes would time out, and the foreground service would conclude the UI
# isolate is GONE and force-release its live-sync session on a schedule. That is
# the one same-process way to force the dangerous verdict, and it is silent:
# nothing logs a stolen port, and the reclaim looks like normal operation.
#
# Checks:
#   1. `initCommunicationPort()` is called from exactly one file, `main.dart`.
#   2. `registerForegroundLivenessResponder()` is called from that same file, so
#      the port owner is always the isolate that can answer.
#
# Pure-grep gate (no toolchain).

set -euo pipefail

cd "$(dirname "$0")/../.."

status=0
OWNER='haven/lib/main.dart'

port_sites=$(grep -rln --include='*.dart' 'initCommunicationPort()' haven/lib || true)
if [ "$port_sites" != "$OWNER" ]; then
  echo "ERROR: initCommunicationPort() must be called from exactly $OWNER."
  echo "Found in:"
  echo "${port_sites:-  (nowhere)}"
  echo
  echo "A second call takes the port name over. Probes would then reach an"
  echo "isolate with no liveness responder, and the foreground service would"
  echo "read the silence as a dead UI isolate and reclaim its MLS session."
  status=1
fi

if ! grep -q 'registerForegroundLivenessResponder()' "$OWNER"; then
  echo "ERROR: $OWNER owns the communication port but does not install the"
  echo "liveness responder. The port owner MUST be able to answer probes, or"
  echo "every probe times out and the reclaim fires against a healthy isolate."
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "OK: one isolate owns the communication port, and it answers probes."
fi
exit "$status"
