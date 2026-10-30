#!/usr/bin/env bash
# CI guard: SQLCipher's native logger and its statement tracer are compiled out
# of every shipped binary (Security Rule 15).
#
# SQLCipher logs to logcat (tag `sqlcipher`), os_log or stderr, beneath every
# Haven log filter, and its lines carry page numbers, pointers, error codes and
# database filenames. `-DSQLCIPHER_OMIT_LOG` removes the logger's code and its
# format strings (libsqlite3-sys-0.30.1 sqlcipher/sqlite3.c:106863,109827,
# 109915), so no later `PRAGMA cipher_log` can switch it back on. Its
# `cipher_profile` tracer writes every statement's SQL to the same sinks; it
# sits behind SQLite's own trace guard, so `-DSQLITE_OMIT_TRACE` removes it and
# the pragma then fails (sqlite3.c:109769-109817; 5ae7fdf :113244-113292).
#
# The flags reach the build two ways, and this guard holds both:
#   * the root .cargo/config.toml `[env]`, which cargo finds from the working
#     directory — every cargo run inside this repository;
#   * haven/rust_builder/cargokit.yaml, because cargokit runs cargo from a
#     temporary directory (Xcode's TARGET_TEMP_DIR on iOS) where the root config
#     is not discovered. Proved on a host build from outside the tree: the root
#     config's value did not reach the build script, the `--config` flags did.
#
# The device lanes provide the stimulus the runtime scanner's S-SQLC rule needs:
# `e2e_combined.dart` makes a wrong-key SQLCipher open inside the app
# (`_lib/sqlcipher_wrong_key.dart`), and the Android and iOS lanes that drive it
# run their captured device logs through the log-privacy gate, where one
# SQLCipher line from Haven's process is a finding no allowlist can name.
#
# Modes:
#   (no arguments)   the two sources carry the same value, with `force`, and
#                    it holds both flags; the drive target makes the wrong-key open; both lanes drive
#                    that target with the log-privacy gate on.
#   <path>...        one built artifact (files and/or directories, searched
#                    whole): the pragma name `cipher_log_level`, which lives
#                    outside the omit guards, must be present somewhere — it
#                    proves the scan read a binary that contains SQLCipher —
#                    and the logger-only and tracer-only literals must be
#                    absent everywhere.
#   --self-test      plants each failure shape.
#
# Pure grep, no toolchain.
#
# Exit codes:
#   0  clean (or the self-test passed)
#   1  a flag is missing or differs, or an artifact carries the logger or tracer
#   2  a path is missing, or an artifact holds no SQLCipher (a vacuous scan)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CARGO_CONFIG="${REPO_ROOT}/.cargo/config.toml"
CARGOKIT_YAML="${REPO_ROOT}/haven/rust_builder/cargokit.yaml"
STIMULUS_TARGET="${REPO_ROOT}/haven/integration_test/e2e/e2e_combined.dart"
STIMULUS_LANES=("${REPO_ROOT}/.github/workflows/e2e-android.yml" "${REPO_ROOT}/.github/workflows/e2e-ios.yml")
FLAGS=('-DSQLCIPHER_OMIT_LOG' '-DSQLITE_OMIT_TRACE')
POSITIVE_CONTROL='cipher_log_level'
# A call-site format (removed with the `sqlcipher_log` macro), the logger
# body's own timestamp format (removed with the function) and the tracer's
# format (removed with `sqlcipher_profile_callback`): three guard sites.
PROBES=('hmac check failed for pgno=' '%s.%03d: ' 'Elapsed time:%.3f ms - %s')

log() {
  printf '\033[1;34m[check_sqlcipher_logger_omitted]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_sqlcipher_logger_omitted] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  rc_of() { set +e; "$@" >/dev/null 2>&1; echo $?; set -e; }
  self() { bash "${BASH_SOURCE[0]}" "$@"; }
  wiring() { REPO_ROOT_OVERRIDE="$1" bash "${BASH_SOURCE[0]}"; }

  value='-DSQLCIPHER_OMIT_LOG -DSQLCIPHER_OMIT_DEFAULT_LOGGING -DSQLITE_OMIT_TRACE'
  write_tree() { # <root> <config value> <cargokit value> <cargokit force>
    mkdir -p "$1/.cargo" "$1/haven/rust_builder" "$1/haven/integration_test/e2e" "$1/.github/workflows"
    printf 'void main() {\n  setUpAll(() async {\n    await provokeSqlcipherWrongKeyOpen();\n  });\n}\n' \
      > "$1/haven/integration_test/e2e/e2e_combined.dart"
    for lane in e2e-android e2e-ios; do
      printf 'jobs:\n  lane:\n    env:\n      HAVEN_LOGSCAN: "true"\n    steps:\n      - run: drive integration_test/e2e/e2e_combined.dart\n' \
        > "$1/.github/workflows/${lane}.yml"
    done
    printf '[env]\nLIBSQLITE3_FLAGS = { value = "%s", force = true }\n' "$2" > "$1/.cargo/config.toml"
    printf 'cargo:\n' > "$1/haven/rust_builder/cargokit.yaml"
    for configuration in debug profile release; do
      printf '  %s:\n    extra_flags:\n      - --config\n      - env.LIBSQLITE3_FLAGS.value="%s"\n      - --config\n      - env.LIBSQLITE3_FLAGS.force=%s\n' \
        "${configuration}" "$3" "$4" >> "$1/haven/rust_builder/cargokit.yaml"
    done
  }
  write_tree "${tmp}/ok" "${value}" "${value}" true
  [[ "$(rc_of wiring "${tmp}/ok")" == 0 ]] || fail "self-test: matching sources must pass"
  write_tree "${tmp}/drift" "${value}" '-DSQLCIPHER_OMIT_DEFAULT_LOGGING' true
  [[ "$(rc_of wiring "${tmp}/drift")" == 1 ]] || fail "self-test: a cargokit value that differs must exit 1"
  for flag in "${FLAGS[@]}"; do
    without="${value/${flag} /}"
    without="${without/ ${flag}/}"
    write_tree "${tmp}/noflag" "${without}" "${without}" true
    [[ "$(rc_of wiring "${tmp}/noflag")" == 1 ]] || fail "self-test: equal values without ${flag} must exit 1"
  done
  write_tree "${tmp}/noforce" "${value}" "${value}" false
  [[ "$(rc_of wiring "${tmp}/noforce")" == 1 ]] || fail "self-test: cargokit without force must exit 1"
  write_tree "${tmp}/oneconf" "${value}" "${value}" true
  sed -i '/^  profile:/,/force=true/d' "${tmp}/oneconf/haven/rust_builder/cargokit.yaml"
  [[ "$(rc_of wiring "${tmp}/oneconf")" == 1 ]] || fail "self-test: a build configuration without the flag must exit 1"
  write_tree "${tmp}/cfgforce" "${value}" "${value}" true
  sed -i 's/, force = true//' "${tmp}/cfgforce/.cargo/config.toml"
  [[ "$(rc_of wiring "${tmp}/cfgforce")" == 1 ]] || fail "self-test: the root config without force must exit 1"
  write_tree "${tmp}/nocall" "${value}" "${value}" true
  sed -i 's#^    await provokeSqlcipherWrongKeyOpen();#    // await provokeSqlcipherWrongKeyOpen();#' "${tmp}/nocall/haven/integration_test/e2e/e2e_combined.dart"
  [[ "$(rc_of wiring "${tmp}/nocall")" == 1 ]] || fail "self-test: a drive target whose wrong-key open is commented out must exit 1"
  write_tree "${tmp}/noscan" "${value}" "${value}" true
  sed -i 's/HAVEN_LOGSCAN: "true"/HAVEN_LOGSCAN: "false"/' "${tmp}/noscan/.github/workflows/e2e-ios.yml"
  [[ "$(rc_of wiring "${tmp}/noscan")" == 1 ]] || fail "self-test: a lane that does not scan its logs must exit 1"
  write_tree "${tmp}/nodrive" "${value}" "${value}" true
  sed -i 's|^      - run: drive integration_test/e2e/e2e_combined.dart|      # - run: drive integration_test/e2e/e2e_combined.dart|' "${tmp}/nodrive/.github/workflows/e2e-android.yml"
  [[ "$(rc_of wiring "${tmp}/nodrive")" == 1 ]] || fail "self-test: a lane that no longer drives the stimulus target must exit 1"
  rm "${tmp}/ok/haven/rust_builder/cargokit.yaml"
  [[ "$(rc_of wiring "${tmp}/ok")" == 2 ]] || fail "self-test: a missing source must exit 2"

  mkdir -p "${tmp}/art/clean" "${tmp}/art/dirty"
  printf 'ELF\0%s\0other\0' "${POSITIVE_CONTROL}" > "${tmp}/art/clean/lib.so"
  [[ "$(rc_of self "${tmp}/art/clean/lib.so")" == 0 ]] || fail "self-test: an artifact with only the pragma name must pass"
  [[ "$(rc_of self "${tmp}/art/clean")" == 0 ]] || fail "self-test: a directory is searched whole"
  for probe in "${PROBES[@]}"; do
    printf 'ELF\0%s\0' "${POSITIVE_CONTROL}" > "${tmp}/art/dirty/lib.so"
    printf 'x\0sqlcipher_page_cipher: %s\0' "${probe}" > "${tmp}/art/dirty/other.bin"
    [[ "$(rc_of self "${tmp}/art/dirty")" == 1 ]] || fail "self-test: '${probe}' in any file of the artifact must exit 1"
  done
  printf 'ELF\0no sqlcipher here\0' > "${tmp}/art/vacuous.so"
  [[ "$(rc_of self "${tmp}/art/vacuous.so")" == 2 ]] || fail "self-test: an artifact without the pragma name is vacuous (exit 2)"
  [[ "$(rc_of self "${tmp}/art/absent.so")" == 2 ]] || fail "self-test: a missing artifact must exit 2"

  log "OK: self-test passed — wiring drift, each missing flag or force, a missing stimulus or lane scan, and each probe fail; a vacuous or missing artifact is a misconfiguration."
  exit 0
fi

if [[ $# -gt 0 ]]; then
  for path in "$@"; do
    [[ -e "${path}" ]] || { echo "ERROR: ${path} not found" >&2; exit 2; }
  done
  if ! LC_ALL=C grep -rqaF -- "${POSITIVE_CONTROL}" "$@"; then
    echo "ERROR: '${POSITIVE_CONTROL}' is in none of: $* — this artifact holds no SQLCipher, so its scan proves nothing" >&2
    exit 2
  fi
  for probe in "${PROBES[@]}"; do
    hits="$(LC_ALL=C grep -rlaF -- "${probe}" "$@" || true)"
    [[ -z "${hits}" ]] || fail "SQLCipher's logger or tracer is compiled into: ${hits} ('${probe}') — ${FLAGS[*]} did not reach this build"
  done
  log "OK: SQLCipher's logger and tracer are absent from $*."
  exit 0
fi

for source in "${CARGO_CONFIG}" "${CARGOKIT_YAML}" "${STIMULUS_TARGET}" "${STIMULUS_LANES[@]}"; do
  [[ -f "${source}" ]] || { echo "ERROR: ${source} not found" >&2; exit 2; }
done
config_value="$(sed -nE 's/^LIBSQLITE3_FLAGS = \{ value = "([^"]*)", force = true \}$/\1/p' "${CARGO_CONFIG}")"
[[ -n "${config_value}" ]] \
  || fail ".cargo/config.toml has no forced LIBSQLITE3_FLAGS"
for flag in "${FLAGS[@]}"; do
  [[ " ${config_value} " == *" ${flag} "* ]] \
    || fail ".cargo/config.toml's LIBSQLITE3_FLAGS lacks ${flag}"
done
for configuration in debug profile release; do
  block="$(sed -n "/^  ${configuration}:\$/,/^  [a-z]*:\$/p" "${CARGOKIT_YAML}")"
  grep -qxF "      - env.LIBSQLITE3_FLAGS.value=\"${config_value}\"" <<<"${block}" \
    || fail "cargokit.yaml's ${configuration} build does not pass the root config's LIBSQLITE3_FLAGS"
  grep -qxF '      - env.LIBSQLITE3_FLAGS.force=true' <<<"${block}" \
    || fail "cargokit.yaml's ${configuration} build does not force LIBSQLITE3_FLAGS"
done
grep -qxE '[[:space:]]+await provokeSqlcipherWrongKeyOpen\(\);' "${STIMULUS_TARGET}" \
  || fail "e2e_combined.dart no longer makes the wrong-key SQLCipher open, so S-SQLC scans a log that never exercised SQLCipher's failure path"
for lane in "${STIMULUS_LANES[@]}"; do
  code="$(grep -vE '^[[:space:]]*#' "${lane}")"
  grep -qF 'integration_test/e2e/e2e_combined.dart' <<<"${code}" \
    || fail "${lane#"${REPO_ROOT}/"} no longer drives e2e_combined.dart, the target that makes the wrong-key open"
  grep -qxE '[[:space:]]+HAVEN_LOGSCAN: "true"' <<<"${code}" \
    || fail "${lane#"${REPO_ROOT}/"} does not run its captured logs through the log-privacy gate"
done
log "OK: .cargo/config.toml and cargokit.yaml both force '${config_value}'; e2e_combined.dart makes the wrong-key open and both lanes scan it."
