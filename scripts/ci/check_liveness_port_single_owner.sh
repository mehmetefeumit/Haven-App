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
OWNER='haven/lib/src/services/foreground_liveness_probe.dart'

# `initCommunicationPort()` must be reachable ONLY through the helper, so the
# port and the responder are always installed together. Calling it directly
# elsewhere is how an entrypoint ends up with a port and no responder — or, from
# a second isolate, steals the port outright.
port_sites=$(grep -rln --include='*.dart' 'initCommunicationPort()' haven/lib || true)
if [ "$port_sites" != "$OWNER" ]; then
  echo "ERROR: initCommunicationPort() must be called only from $OWNER,"
  echo "inside ensureForegroundTaskComms(). Found in:"
  echo "${port_sites:-  (nowhere)}"
  echo
  echo "Calling it directly risks a port with no responder; from a second"
  echo "isolate it takes the port name over entirely. Either way the foreground"
  echo "service reads the resulting silence as a dead UI isolate and releases"
  echo "its MLS session."
  status=1
fi

# The helper must install both halves, or the port exists with nothing to
# answer on it.
if ! grep -q 'registerForegroundLivenessResponder()' "$OWNER"; then
  echo "ERROR: ensureForegroundTaskComms() must install the liveness responder"
  echo "alongside the port, or every probe times out against a healthy isolate."
  status=1
fi

# Every UI entrypoint must call the helper. `main()` alone is not enough: an
# entrypoint that builds the app itself (an integration-test target) never runs
# it, and CI run 30786149786 showed the foreground service then reclaim a live
# session on exactly that path.
for entry in haven/lib/main.dart haven/lib/src/pages/map_shell.dart; do
  if ! grep -q 'ensureForegroundTaskComms()' "$entry"; then
    echo "ERROR: $entry does not call ensureForegroundTaskComms()."
    echo "An entrypoint without it leaves the channel unregistered, and"
    echo "sendDataToMain is a silent no-op when nothing is registered."
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "OK: the port is installed only with its responder, from every UI entrypoint."
fi
exit "$status"
