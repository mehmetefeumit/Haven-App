#!/usr/bin/env bash
# CI guard: no Rust log sink the app does not control (Security Rule 15).
#
# MDK logs through `tracing`, and its events carry values Rule 15 forbids in a
# log — exact counts among them (v0.10.4 `cgka-session/src/lib.rs:382-389`
# reports how many KeyPackages it retired and kept). Today those events reach
# nothing: `tracing` is resolved without its `log` dependency and Haven installs
# no subscriber. That protection is an accident of the graph. One crate that
# turns on `tracing/log` forwards every MDK event into Haven's `log` pipeline,
# and one subscriber crate hands them a sink of their own. So:
#
#   L1  in every Cargo root's lockfile, no `tracing` package lists `log` among
#       its dependencies. A lockfile records an optional dependency only when a
#       feature activates it (`log` appears exactly when `tracing/log` or
#       `log-always` is on — the self-test's fixture is a real
#       `cargo generate-lockfile` probe of both states).
#   L2  no subscriber or bridge crate is in any lockfile (list below).
#   S1  no Haven Rust source names `tracing::`, `tracing_subscriber`,
#       `set_global_default` or `config_log` (rusqlite's SQLite log hook, which
#       storage-sqlite uses only in its own tests). A flat ban, comments
#       included: prose can say "the tracing crate".
#
# Pure grep/awk, no toolchain.
#
# Usage:
#   bash scripts/ci/check_no_tracing_sink.sh
#   bash scripts/ci/check_no_tracing_sink.sh --self-test
#
# Exit codes:
#   0  no sink (or the self-test passed)
#   1  a sink or bridge is present (or the self-test failed)
#   2  a lockfile or source root is missing, or no `tracing` package was found
#      in any lockfile (parser rot — or `tracing` left the graph, in which case
#      L1 goes in the same change)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly -a CARGO_ROOTS=(haven-core haven/rust_builder tooling/soak tooling/logscan tooling/e2e/local-relay)
readonly -a SOURCE_ROOTS=(haven-core/src haven-core/tests haven/rust_builder/src tooling/soak/src tooling/soak/tests)
readonly -a SINK_CRATES=(tracing-subscriber tracing-log tracing-android tracing-oslog tracing-appender
                         tracing-journald tracing-opentelemetry console-subscriber test-log)
readonly SOURCE_TOKENS='tracing::|tracing_subscriber|set_global_default|config_log'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=19

log() {
  printf '\033[1;34m[check_no_tracing_sink]\033[0m %s\n' "$*"
}

# The dependency names of every `tracing` package block, one per line. A
# dependency entry is `"log"`, or `"log 0.4.29"` when two versions resolve.
tracing_deps() { # <lockfile>
  awk '
    /^\[/ { pkg = ($0 == "[[package]]"); name = ""; deps = 0; next }
    pkg && /^name = / { name = $3; gsub(/"/, "", name); if (name == "tracing") print "#block" }
    pkg && name == "tracing" && /^dependencies = \[/ { deps = 1; next }
    deps && /^\]/ { deps = 0; next }
    deps { d = $1; gsub(/[",]/, "", d); print d }
  ' "$1"
}

run_check() {
  local root lock crate blocks=0 hits
  local -a violations=()
  for root in "${CARGO_ROOTS[@]}"; do
    lock="${REPO_ROOT}/${root}/Cargo.lock"
    [[ -f "${lock}" ]] || { echo "ERROR: ${lock} not found" >&2; return 2; }
    local deps; deps="$(tracing_deps "${lock}")"
    blocks=$(( blocks + $(grep -cx '#block' <<<"${deps}" || true) ))
    grep -qx 'log' <<<"${deps}" \
      && violations+=("L1 ${root}/Cargo.lock: \`tracing\` depends on \`log\` — some crate enabled tracing/log (or log-always), which forwards every MDK tracing event into Haven's log pipeline")
    for crate in "${SINK_CRATES[@]}"; do
      grep -qE "^name = \"${crate}\"\$" "${lock}" \
        && violations+=("L2 ${root}/Cargo.lock: \`${crate}\` is in the graph — a tracing subscriber or bridge gives MDK's events a sink Haven does not control")
    done
  done
  if (( blocks == 0 )); then
    echo "ERROR: no \`tracing\` package in any of ${CARGO_ROOTS[*]} — the parser rotted, or tracing left the graph (then retire L1 in the same change)" >&2
    return 2
  fi

  for root in "${SOURCE_ROOTS[@]}"; do
    [[ -d "${REPO_ROOT}/${root}" ]] || { echo "ERROR: ${REPO_ROOT}/${root} not found" >&2; return 2; }
  done
  hits="$(cd "${REPO_ROOT}" && grep -rnE "${SOURCE_TOKENS}" "${SOURCE_ROOTS[@]}" 2>/dev/null || true)"
  [[ -z "${hits}" ]] || violations+=("S1 a Haven source installs or names a tracing sink or the SQLite log hook:"$'\n'"${hits}")

  if (( ${#violations[@]} > 0 )); then
    printf '  %s\n' "${violations[@]}" >&2
    printf '\033[1;31m[check_no_tracing_sink] FAIL:\033[0m MDK logs through tracing with values Rule 15 forbids in a log; nothing may give those events a sink.\n' >&2
    return 1
  fi
  log "OK: no tracing->log bridge, no subscriber crate, no sink installed (${#CARGO_ROOTS[@]} lockfiles, ${#SOURCE_ROOTS[@]} source roots)."
}

# ---------------------------------------------------------------------------
# Self-test. The two `tracing` blocks are copied verbatim from a
# `cargo generate-lockfile` probe over `tracing = "=0.1.44"` with and without
# `features = ["log"]` (2026-09-28).
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local QUIET='[[package]]
name = "tracing"
version = "0.1.44"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "63e71662fa4b2a2c3a26f570f037eb95bb1f85397f3cd8076caed2f026a6d100"
dependencies = [
 "pin-project-lite",
 "tracing-attributes",
 "tracing-core",
]'
  local BRIDGED='[[package]]
name = "tracing"
version = "0.1.44"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "63e71662fa4b2a2c3a26f570f037eb95bb1f85397f3cd8076caed2f026a6d100"
dependencies = [
 "log",
 "pin-project-lite",
 "tracing-attributes",
 "tracing-core",
]'
  # Another crate depending on `log` is Haven's ordinary logger, not a bridge.
  local LOGGER='[[package]]
name = "nostr-relay-pool"
version = "0.44.3"
source = "registry+https://github.com/rust-lang/crates.io-index"
dependencies = [
 "log",
 "tracing",
]'

  _tree() { # <tree> — every root clean, every source root present
    local t="$1" r
    for r in "${CARGO_ROOTS[@]}"; do
      mkdir -p "${t}/${r}"
      printf 'version = 4\n\n%s\n\n%s\n' "${LOGGER}" "${QUIET}" >"${t}/${r}/Cargo.lock"
    done
    for r in "${SOURCE_ROOTS[@]}"; do mkdir -p "${t}/${r}"; printf 'fn f() { log::debug!("x"); }\n' >"${t}/${r}/lib.rs"; done
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

  echo "check_no_tracing_sink.sh --self-test"
  local t i crate
  t="${tmp}/ok"; _tree "${t}"
  _case "tracing without log, and crates that use log themselves, pass" 0 "${t}"

  t="${tmp}/bridged"; _tree "${t}"
  printf 'version = 4\n\n%s\n' "${BRIDGED}" >"${t}/tooling/soak/Cargo.lock"
  _case "L1: the probed tracing/log lockfile block fails (soak lockfile)" 1 "${t}"

  t="${tmp}/bridged-versioned"; _tree "${t}"
  printf 'version = 4\n\n%s\n' "${BRIDGED/ \"log\",/ \"log 0.4.29\",}" >"${t}/haven/rust_builder/Cargo.lock"
  _case "L1: a versioned \"log 0.4.29\" entry fails (shipped lockfile)" 1 "${t}"

  # Each sink crate, each in a different root, so every root is proven read.
  i=0
  for crate in "${SINK_CRATES[@]}"; do
    t="${tmp}/sink-${crate}"; _tree "${t}"
    printf '\n[[package]]\nname = "%s"\nversion = "0.1.0"\n' "${crate}" \
      >>"${t}/${CARGO_ROOTS[$(( i % ${#CARGO_ROOTS[@]} ))]}/Cargo.lock"
    _case "L2: ${crate} in ${CARGO_ROOTS[$(( i % ${#CARGO_ROOTS[@]} ))]} fails" 1 "${t}"
    i=$(( i + 1 ))
  done

  t="${tmp}/s1-macro"; _tree "${t}"
  printf 'fn f(n: usize) { tracing::info!(n, "retired"); }\n' >"${t}/haven-core/tests/t.rs"
  _case "S1: a tracing:: macro in haven-core/tests fails" 1 "${t}"

  t="${tmp}/s1-init"; _tree "${t}"
  printf 'fn main() { tracing_subscriber::fmt().init(); }\n' >"${t}/tooling/soak/src/main.rs"
  _case "S1: a tracing_subscriber init in tooling/soak/src fails" 1 "${t}"

  t="${tmp}/s1-global"; _tree "${t}"
  printf 'fn f() { let _ = set_global_default(sub); }\n' >"${t}/haven/rust_builder/src/api.rs"
  _case "S1: set_global_default in rust_builder fails" 1 "${t}"

  t="${tmp}/s1-hook"; _tree "${t}"
  printf 'fn f() { unsafe { rusqlite::trace::config_log(Some(cb)) }; }\n' >"${t}/tooling/soak/tests/t.rs"
  _case "S1: rusqlite's config_log hook fails" 1 "${t}"

  t="${tmp}/no-tracing"; _tree "${t}"
  for crate in "${CARGO_ROOTS[@]}"; do printf 'version = 4\n\n%s\n' "${LOGGER}" >"${t}/${crate}/Cargo.lock"; done
  _case "no tracing package anywhere is a misconfiguration, not a pass" 2 "${t}"

  t="${tmp}/no-lock"; _tree "${t}"; rm "${t}/tooling/logscan/Cargo.lock"
  _case "a missing lockfile is a misconfiguration" 2 "${t}"

  t="${tmp}/no-src"; _tree "${t}"; rm -r "${t}/tooling/soak/tests"
  _case "a missing source root is a misconfiguration" 2 "${t}"

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
