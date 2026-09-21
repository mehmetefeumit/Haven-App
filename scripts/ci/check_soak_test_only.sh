#!/usr/bin/env bash
#
# CI guard: the Tier-1 soak rig is a TEST INSTRUMENT and must stay one — and
# the one compile-time trap that keeps it out of a shipped build must stay
# armed.
#
# ## What the rig is, and why it needs a boundary
#
# `tooling/soak` builds `haven-soak`, which links haven-core with the
# `test-utils` feature ON. That feature is the door to the five probe seams
# (a typed ingest that returns the engine's own error, a stored-message probe,
# the live-sync processor, the circle rotation stamps, and direct read/delete
# of the OpenMLS group state inside the SQLCipher store) plus the
# unencrypted-store constructors. Every one of those exists so a harness can
# see state the product deliberately does not expose.
#
# It is also the door to a MUTATION seam, which is worse:
# `set_stored_message_write_fault_for_test` installs an abort trigger on the
# engine's stored-message table in a LIVE database, so the feature can make the
# product's own writes fail rather than merely observe them. A shipped build
# that carried any of this would ship a door into its own MLS store — and, with
# that one, a lever on it.
#
# haven-core defends that with a compile-time trap:
#
#     #[cfg(all(feature = "test-utils", not(debug_assertions)))] compile_error!(…)
#
# so a RELEASE build with the feature on cannot compile at all. That trap has
# exactly one disarming move — `debug-assertions = true` under any `[profile.*]`
# of a manifest that ships — and it is a one-line diff in a file nobody reads by
# default. Check 4 is that line's guard.
#
# ## The invariants
#
#   1. NO PRODUCTION REACH. No file under haven/lib, haven-core/src or
#      haven/rust_builder/src names the rig, its crate, its paths or its env
#      vars. The harness may (haven/integration_test and tooling/ are not
#      scanned).
#
#   2. NOT IN A BUILD PATH. No shipped manifest, pubspec, release wrapper or
#      cargokit config depends on `haven-soak` or on `tooling/soak`, and the
#      crate declares `publish = false`. Mirrors
#      check_wire_proxy_test_only.sh's check 2 for the same reason: a
#      harness-only crate that can enter an APK or an IPA is not harness-only.
#
#   3. `test-utils` STAYS A DEV EDGE. `haven/rust_builder/Cargo.toml` names
#      `haven-core = { …, features = ["test-utils"] }` as a DEV-dependency ON
#      PURPOSE — its own redaction tests need the assertion macros — so a bare
#      grep for the string is not the rule and never was. The rule is: the
#      feature appears in NO non-dev dependency table of that manifest
#      (`[dependencies]`, `[build-dependencies]`, `[target.*.dependencies]`,
#      `[target.*.build-dependencies]`), and nowhere at all in
#      `haven/pubspec.yaml`, `scripts/build_release.sh` or the cargokit config,
#      which is where a feature would be turned on for a real build.
#
#      A dependency table is not the only door. A `[features]` ALIAS is the
#      other one, and it is wider: `default = ["test-utils"]` in
#      haven-core/Cargo.toml turns the five probe seams on for every consumer
#      that does not opt out — every DEBUG build of the app included, since the
#      `compile_error!` fires only with `debug_assertions` off. Checks 2, 3 and
#      4 as first written all stay green through that one-word diff. So: no
#      manifest may list haven-core's feature (`"test-utils"` or
#      `"haven-core/test-utils"`) inside ANY `[features]` alias's array,
#      `default` first among them, and haven-core must still DECLARE its
#      `default` — the scan passes vacuously over a manifest that stopped
#      stating its posture. Another crate's own unrelated `test-utils`
#      (whitenoise-rs's `mdk-core/test-utils`) is not haven-core's and is not
#      matched.
#
#   4. THE COMPILE-TIME TRAP STAYS ARMED. `[profile.soak]` exists in
#      `tooling/soak/Cargo.toml` and in no other manifest, and NO manifest
#      outside `tooling/soak` sets `debug-assertions = true` under any
#      `[profile.*]`. The soak profile is the repository's first custom cargo
#      profile; it is release-with-debug-assertions precisely so the rig can
#      compile the feature, and that is a property of one crate that never
#      ships, not of the tree.
#
#   5. NO `{:?}` OF A FOREIGN TYPE. Nothing under `tooling/soak` (src AND
#      tests), and nothing in the haven-core seam test, may render a
#      `haven_core`/`cgka_*`/`nostr*`/`openmls` value through the Debug format
#      family (`{:?}`, `{:#?}`, `{x:?}`, `{:x?}`) or `dbg!`. Those Debug impls
#      print a real MLS group id and absolute epochs (`EngineError::ForkedEpoch`
#      carries `group_id`, `last_stable` and `conflicting_epoch`), and the rig's
#      own crate-local Debug test cannot see a rendering of a type it does not
#      define. The engine's typed errors are MATCHED here, never formatted.
#
#      What a per-invocation scan cannot see, stated so nobody reads more into
#      a green run: a foreign value bound to a local name (`let e = …;
#      println!("{e:?}")` with no foreign path on the line) is outside this
#      check. A reviewed exception says why on the line, as everywhere else:
#      `// log-scan-ok: <reason>`.
#
#   6. THE TIMELINE FIELD-CLASS TEST EXISTS AND PINS ITS COUNT. Rule 15 over
#      the rig's own output rests on `tests/timeline_fields.rs` giving EVERY
#      timeline field a privacy class, and on a field with no class failing —
#      because a field named `epoch` passes a name allowlist and still violates
#      the pillar. A test whose case list can shrink silently is what makes
#      such a test worthless, so the file carries a pinned count and asserts
#      against it.
#
#      The six classes are named in §3.10 of the rig's own design: tag, bucket,
#      delta, duration, measurement, literal.
#
# ## Absent crate
#
# Checks 1–4 are about the SHIPPED side and hold whether or not the rig exists;
# they always run. Checks 5 and 6 are about the crate, and while
# `tooling/soak/src` (check 5) or `tooling/soak/src/timeline.rs` (check 6) is
# not in the tree they print that they are inert and return 0 — a guard that
# reds on a repository where its subject has not landed yet is a guard somebody
# deletes. The moment the subject exists they enforce.
#
# Pure grep/awk, no toolchain — belongs in repo-guards.yml.
#
# Usage:
#   bash scripts/ci/check_soak_test_only.sh
#   bash scripts/ci/check_soak_test_only.sh --self-test
#
# Exit codes:
#   0  all invariants hold
#   1  an invariant is violated
#   2  expected paths missing (misconfiguration) or the self-test failed

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SELF_NAME='check_soak_test_only'

readonly SOAK_DIR='tooling/soak'
readonly SOAK_MANIFEST='tooling/soak/Cargo.toml'
readonly FFI_MANIFEST='haven/rust_builder/Cargo.toml'
readonly CORE_MANIFEST='haven-core/Cargo.toml'
readonly TIMELINE_TEST='tooling/soak/tests/timeline_fields.rs'
readonly SEAM_TEST='haven-core/tests/test_utils_seams.rs'
# Equality pin: a fixture added or removed without moving this line is a
# self-test that no longer says what it runs.
readonly SELF_TEST_FIXTURES=38

# Trees that ship. `haven/integration_test` and `tooling/` are deliberately
# absent: that is the harness, and it is where the rig belongs.
readonly PRODUCTION_TREES=(
  'haven/lib'
  'haven-core/src'
  'haven/rust_builder/src'
)

# Every name that would betray the rig having been wired into the app. The env
# vars are here for the same reason the wire proxy's are: a shipped app able to
# read HAVEN_SOAK_SEED would be an app whose behaviour a harness variable can
# change.
readonly FORBIDDEN_TOKENS=(
  'haven-soak'
  'haven_soak'
  'tooling/soak'
  'HAVEN_SOAK_PROFILE'
  'HAVEN_SOAK_SEED'
  'HAVEN_SOAK_DRIVE_TIMEOUT'
)

# What decides what enters a shipped artifact.
readonly BUILD_MANIFESTS=(
  'haven-core/Cargo.toml'
  'haven/rust_builder/Cargo.toml'
  'haven/pubspec.yaml'
  'scripts/build_release.sh'
  'haven/rust_builder/cargokit/cmake/cargokit.cmake'
)
# Where turning the feature on would reach a real build.
readonly FEATURE_FREE_FILES=(
  'haven/pubspec.yaml'
  'scripts/build_release.sh'
  'haven/rust_builder/cargokit/cmake/cargokit.cmake'
)

# Foreign crates and the re-exported types whose Debug prints a real MLS group
# id, absolute epochs or key material.
#
# Both are written with BRACKET expressions rather than backslash escapes: they
# are handed to awk through `-v`, which consumes a backslash before the regex
# engine ever sees it (check_no_identifier_logging.sh's header records the same
# trap), and a bare `{` in an ERE starts an interval.
readonly FOREIGN_RE='haven_core::|haven-core|cgka_session::|cgka_traits::|cgka_engine::|nostr::|nostr_sdk::|nostr_relay_builder::|nostr_database::|openmls|SessionError|EngineError|IngestOutcome|StaleReason|ScreenedIngest|MessageState|StoredMessageProbe|EpochId|GroupId|CircleRotationState|StopOutcome|LiveSyncEvent|OpenMlsGroupKey'
readonly DEBUG_FMT_RE='[{][A-Za-z0-9_]*:[#]?x?[?][}]|dbg![(]'

FAILED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
log()  { printf '[%s] %s\n' "${SELF_NAME}" "$*"; }

# ---------------------------------------------------------------------------
# Checks. Each takes an explicit root so --self-test can point it at a fixture.
# ---------------------------------------------------------------------------

# 1. No production file names the rig. A flat token ban, comments included:
#    prose that needs to mention it can say "the Tier-1 soak rig", and a flat
#    ban needs no comment parsing a rewording could sidestep.
check_no_production_reach() {
  local root="$1" rc=0 tree token hits
  for tree in "${PRODUCTION_TREES[@]}"; do
    [[ -d "${root}/${tree}" ]] || continue
    for token in "${FORBIDDEN_TOKENS[@]}"; do
      hits="$(grep -rlF -- "${token}" "${root}/${tree}" 2>/dev/null)"
      if [[ -n "${hits}" ]]; then
        printf '%s\n' "${hits}" >&2
        fail "'${token}' appears under ${tree}. The soak rig links haven-core with test-utils on — the five probe seams and the unencrypted-store constructors — and must be unreachable from the shipped app."
        rc=1
      fi
    done
  done
  return "${rc}"
}

# 2. No shipped manifest, wrapper or cargokit config pulls the crate in.
check_not_in_build_path() {
  local root="$1" rc=0 manifest f
  for manifest in "${BUILD_MANIFESTS[@]}"; do
    f="${root}/${manifest}"
    [[ -f "${f}" ]] || continue
    if grep -qE -- 'haven-soak|haven_soak|tooling/soak' "${f}"; then
      fail "${manifest} references the soak crate. A harness-only crate must never be part of a build that ships."
      rc=1
    fi
  done
  f="${root}/${SOAK_MANIFEST}"
  if [[ -f "${f}" ]] && ! grep -qE '^[[:space:]]*publish[[:space:]]*=[[:space:]]*false' "${f}"; then
    fail "${SOAK_MANIFEST} no longer declares publish = false."
    rc=1
  fi
  return "${rc}"
}

# Prints the non-dev dependency tables of a Cargo manifest that mention a
# feature, as `<line>:<table>`. Comments are stripped first, so documenting the
# rule does not trip it.
non_dev_feature_hits() { # non_dev_feature_hits <manifest> <feature>
  awk -v want="$2" '
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*\[/) {
        table = line
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", table)
        # A dev table is any whose LAST segment is dev-dependencies, so a bare
        # [dev-dependencies] and a target-scoped one are both excluded, while
        # [dependencies] and [build-dependencies] are not.
        isdep = (table ~ /(^|\.)(dependencies|build-dependencies)$/)
        isdev = (table ~ /(^|\.)dev-dependencies$/)
        next
      }
      if (isdep && !isdev && index(line, want)) print NR ":" table
    }
  ' "$1"
}

# Prints `<line>:<alias>` for every [features] alias whose array pulls in
# haven-core's test-utils — one line or several. Comments are stripped first.
feature_alias_hits() { # feature_alias_hits <manifest>
  awk '
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (!open && line ~ /^[[:space:]]*\[/) {
        table = line
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", table)
        infeat = (table == "features")
        next
      }
      if (!infeat) next
      if (!open) {
        if (line !~ /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*\[/) next
        alias = line
        sub(/[[:space:]]*=.*$/, "", alias)
        gsub(/^[[:space:]]+/, "", alias)
        start = NR; buf = line; open = 1
      } else {
        buf = buf " " line
      }
      if (index(buf, "]")) {
        open = 0
        if (buf ~ /"(haven-core\/)?test-utils"/) print start ":" alias
      }
    }
  ' "$1"
}

# The `default = [...]` line a manifest declares under [features], or nothing.
feature_default_decl() { # feature_default_decl <manifest>
  awk '
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*\[/) {
        table = line
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", table)
        infeat = (table == "features")
        next
      }
      if (infeat && line ~ /^[[:space:]]*default[[:space:]]*=[[:space:]]*\[/) print NR ":" line
    }
  ' "$1"
}

# 3. `test-utils` stays a DEV edge of rust_builder, and reaches no build path.
check_test_utils_is_dev_only() {
  local root="$1" rc=0 f hits
  f="${root}/${FFI_MANIFEST}"
  if [[ ! -f "${f}" ]]; then
    fail "${FFI_MANIFEST} not found — the manifest whose dev/non-dev split this check reads."
    return 1
  fi
  hits="$(non_dev_feature_hits "${f}" 'test-utils')"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" >&2
    fail "${FFI_MANIFEST} names the test-utils feature in a NON-DEV dependency table. That feature opens haven-core's probe seams; rust_builder may have it as a dev-dependency (its own redaction tests need the macros) and nowhere else."
    rc=1
  fi
  local rel
  for rel in "${FEATURE_FREE_FILES[@]}"; do
    f="${root}/${rel}"
    [[ -f "${f}" ]] || continue
    if grep -qF -- 'test-utils' "${f}"; then
      fail "${rel} names the test-utils feature. This file decides what a REAL build compiles; the feature has no business here in any form."
      rc=1
    fi
  done

  # The wider door: a [features] alias, which no dependency-table rule sees.
  local m
  while IFS= read -r m; do
    [[ -n "${m}" ]] || continue
    hits="$(feature_alias_hits "${m}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "${m#"${root}/"} pulls haven-core's test-utils into a [features] alias (line:alias above). An alias is not a dev edge: \`default = [\"test-utils\"]\` opens the five probe seams for every consumer that does not opt out, and haven-core's compile_error! only fires with debug_assertions OFF — so every DEBUG build of the app would carry them while checks 2-4 stayed green."
      rc=1
    fi
  done < <(other_manifests "${root}")

  # ...and the posture is STATED. A manifest that stopped declaring `default`
  # is the one shape the scan above passes over vacuously.
  f="${root}/${CORE_MANIFEST}"
  if [[ -f "${f}" ]] && [[ -z "$(feature_default_decl "${f}")" ]]; then
    fail "${CORE_MANIFEST} declares no \`default = [...]\` under [features]. The empty default is what keeps the probe seams off for every consumer; unstated, there is nothing for the alias scan above to read."
    rc=1
  fi
  return "${rc}"
}

# Prints `<file>:<line>` for every `[profile.*]` table that sets
# debug-assertions = true, and for every `[profile.soak]` header.
profile_table_hits() { # profile_table_hits <manifest> <what:soak|debugassert>
  awk -v what="$2" '
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*\[/) {
        table = line
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", table)
        inprofile = (table ~ /^profile\./)
        if (what == "soak" && table == "profile.soak") print FILENAME ":" NR
        next
      }
      if (what == "debugassert" && inprofile \
          && line ~ /^[[:space:]]*debug-assertions[[:space:]]*=[[:space:]]*true/) print FILENAME ":" NR
    }
  ' "$1"
}

# Every Cargo manifest in the tree except the soak crate's own, and except the
# build outputs and vendored sources under target/ and .cargo/.
other_manifests() { # other_manifests <root>
  find "$1" -name Cargo.toml \
    -not -path '*/target/*' -not -path '*/.cargo/*' -not -path '*/.git/*' \
    -not -path "*/${SOAK_DIR}/*" | sort
}

# 4. The compile-time trap stays armed.
check_profile_trap_is_armed() {
  local root="$1" rc=0 m hits n=0
  while IFS= read -r m; do
    [[ -n "${m}" ]] || continue
    n=$(( n + 1 ))
    hits="$(profile_table_hits "${m}" soak)"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "${m#"${root}/"} declares [profile.soak]. That profile exists for one crate that never ships; a second one is a shipped build inheriting a release profile with debug assertions on."
      rc=1
    fi
    hits="$(profile_table_hits "${m}" debugassert)"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "${m#"${root}/"} sets debug-assertions = true under a [profile.*] table. That single line disarms haven-core's compile_error! trap — the one thing that stops a RELEASE build compiling the test-utils seams into a shipped artifact."
      rc=1
    fi
  done < <(other_manifests "${root}")
  if (( n == 0 )); then
    fail "no Cargo manifest found outside ${SOAK_DIR} — this check would pass vacuously."
    return 1
  fi
  # The soak crate itself must HAVE the profile, or the rig is being built
  # some other way and the reasoning above is about nothing.
  local soak="${root}/${SOAK_MANIFEST}"
  if [[ -f "${soak}" ]] && [[ -z "$(profile_table_hits "${soak}" soak)" ]]; then
    fail "${SOAK_MANIFEST} no longer declares [profile.soak]. The rig needs release-with-debug-assertions to compile haven-core's test-utils at all; if the profile moved, this guard's reasoning moved with it."
    rc=1
  fi
  return "${rc}"
}

# Prints `<file>:<line>` for every Debug-format rendering of a foreign value.
# Full-line comments are dropped; a line (or the line above it) carrying
# `// log-scan-ok: <reason>` is a reviewed exception. The reason is mandatory.
debug_format_hits() { # debug_format_hits <file>
  awk -v fmt="${DEBUG_FMT_RE}" -v foreign="${FOREIGN_RE}" '
    {
      raw = $0
      line = $0
      sub(/^[[:space:]]*\/\/.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) { prev_ok = (raw ~ /\/\/[[:space:]]*log-scan-ok:[[:space:]]*[^[:space:]]/); next }
      ok = (raw ~ /\/\/[[:space:]]*log-scan-ok:[[:space:]]*[^[:space:]]/) || prev_ok
      if (!ok && line ~ fmt && line ~ foreign) print FILENAME ":" NR
      prev_ok = (raw ~ /\/\/[[:space:]]*log-scan-ok:[[:space:]]*[^[:space:]]/)
    }
  ' "$1"
}

# 5. No `{:?}` of a foreign type anywhere in the rig or in the seam test.
check_no_foreign_debug_format() {
  local root="$1" rc=0 f hits n=0
  local -a files=()
  if [[ -d "${root}/${SOAK_DIR}/src" ]]; then
    while IFS= read -r f; do files+=("${f}"); done \
      < <(find "${root}/${SOAK_DIR}/src" "${root}/${SOAK_DIR}/tests" -name '*.rs' 2>/dev/null | sort)
  fi
  [[ -f "${root}/${SEAM_TEST}" ]] && files+=("${root}/${SEAM_TEST}")
  if (( ${#files[@]} == 0 )); then
    log "check 5 is inert: neither ${SOAK_DIR}/src nor ${SEAM_TEST} is in the tree yet."
    return 0
  fi
  for f in "${files[@]}"; do
    n=$(( n + 1 ))
    hits="$(debug_format_hits "${f}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "${f#"${root}/"} renders a haven_core/cgka/nostr/openmls value through the Debug format family. Those impls print a real MLS group id and absolute epochs; match the typed error, never format it. A reviewed exception says why on the line: // log-scan-ok: <reason>."
      rc=1
    fi
  done
  log "check 5: ${n} rig/seam source file(s) read for a foreign Debug rendering."
  return "${rc}"
}

# 6. The timeline field-class test exists and pins its count.
check_timeline_field_test_is_pinned() {
  local root="$1" f="${root}/${TIMELINE_TEST}" pin
  # Inert until the timeline itself exists. The subject of this check is the
  # classification of the TIMELINE's fields, so while `src/timeline.rs` is not
  # in the tree it would be demanding a test for code that does not exist —
  # which is how a guard gets an exemption rather than a fix. The moment the
  # timeline lands, its field-class test is required with it.
  if [[ ! -f "${root}/${SOAK_DIR}/src/timeline.rs" ]]; then
    log "check 6 is inert: ${SOAK_DIR}/src/timeline.rs is not in the tree yet."
    return 0
  fi
  if [[ ! -f "${f}" ]]; then
    fail "${TIMELINE_TEST} not found. Rule 15 over the rig's own output rests on every timeline field being classified tag/bucket/delta/duration/measurement/literal — a field named \`epoch\` passes a name allowlist and still leaks."
    return 1
  fi
  # A count pinned by EQUALITY, and asserted. A test whose field list can shrink
  # silently reports coverage it does not have.
  pin="$(grep -oE 'const[[:space:]]+[A-Z_]*(FIELDS|CASES)[A-Z_]*[[:space:]]*:[[:space:]]*usize[[:space:]]*=[[:space:]]*[0-9]+' "${f}" | head -1)"
  if [[ -z "${pin}" ]]; then
    fail "${TIMELINE_TEST} declares no \`const …FIELDS/…CASES: usize = <n>\` pin. The field-class table is only worth what its count pins: a class dropped with its field is a test that still passes."
    return 1
  fi
  local name="${pin#const }"; name="${name%%[^A-Za-z_]*}"
  if ! grep -qE "assert[_a-z]*!\(.*${name}" "${f}"; then
    fail "${TIMELINE_TEST} declares ${name} but never asserts against it. An unasserted pin is a comment."
    return 1
  fi
  log "check 6: ${TIMELINE_TEST} pins its field-class count (${name}) and asserts it."
  return 0
}

run_all() {
  local root="$1"
  check_no_production_reach "${root}"
  check_not_in_build_path "${root}"
  check_test_utils_is_dev_only "${root}"
  check_profile_trap_is_armed "${root}"
  check_no_foreign_debug_format "${root}"
  check_timeline_field_test_is_pinned "${root}"
}

# ---------------------------------------------------------------------------
# Self-test. Every check has a fixture in BOTH directions — the shape that must
# pass and the exact regression that must fail — plus the routes by which each
# could rot into a rubber stamp (an extractor that matches nothing, a tree with
# nothing to read).
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <fn> <root>
    local label="$1" want="$2" fn="$3" root="$4" got=0
    checked=$(( checked + 1 ))
    ( FAILED=0; "${fn}" "${root}" >/dev/null 2>&1 ) || got=1
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _mk() { # _mk <root> — a minimal tree in the shape the guard expects
    local r="$1"
    mkdir -p "${r}/haven/lib/src" "${r}/haven-core/src" "${r}/haven-core/tests" \
             "${r}/haven/rust_builder/src" "${r}/haven/rust_builder/cargokit/cmake" \
             "${r}/haven/integration_test" "${r}/scripts" \
             "${r}/${SOAK_DIR}/src" "${r}/${SOAK_DIR}/tests"
    printf 'void main() {}\n' > "${r}/haven/lib/src/app.dart"
    printf 'pub fn x() {}\n'   > "${r}/haven-core/src/lib.rs"
    printf 'pub fn y() {}\n'   > "${r}/haven/rust_builder/src/api.rs"
    # The harness names everything freely; it is never scanned.
    printf 'const s = "HAVEN_SOAK_SEED"; // tooling/soak\n' \
      > "${r}/haven/integration_test/harness.dart"

    # The posture check 3 reads: an EMPTY default, the seams behind their own
    # feature, and nothing aliasing one to the other.
    printf '[package]\nname = "haven-core"\n\n[features]\ndefault = []\ntest-utils = []\n' \
      > "${r}/haven-core/Cargo.toml"
    cat > "${r}/${FFI_MANIFEST}" <<'TOML'
[package]
name = "rust_lib_haven"

[dependencies]
haven-core = { path = "../../haven-core" }

[dev-dependencies]
# DEV-ONLY on purpose: a shipped build must not carry the test seams.
haven-core = { path = "../../haven-core", features = ["test-utils"] }

[target.'cfg(target_os = "ios")'.dev-dependencies]
haven-core = { path = "../../haven-core", features = ["test-utils"] }
TOML
    printf 'name: haven\n' > "${r}/haven/pubspec.yaml"
    printf '#!/usr/bin/env bash\nflutter build apk\n' > "${r}/scripts/build_release.sh"
    printf '# cargokit\nset(CARGOKIT_ROOT)\n' \
      > "${r}/haven/rust_builder/cargokit/cmake/cargokit.cmake"

    cat > "${r}/${SOAK_MANIFEST}" <<'TOML'
[package]
name = "haven-soak"
publish = false

[dependencies]
haven-core = { path = "../../haven-core", features = ["test-utils"] }

[profile.soak]
inherits = "release"
debug-assertions = true
overflow-checks = true
TOML
    printf 'pub fn rig() {}\n' > "${r}/${SOAK_DIR}/src/lib.rs"
    printf 'pub struct TimelineRecord;\n' > "${r}/${SOAK_DIR}/src/timeline.rs"
    cat > "${r}/${SOAK_DIR}/tests/timeline_fields.rs" <<'RS'
const DECLARED_FIELDS: usize = 12;

#[test]
fn every_timeline_field_has_a_privacy_class() {
    assert_eq!(classified().len(), DECLARED_FIELDS);
}
RS
    printf '#[test]\nfn seams() {}\n' > "${r}/${SEAM_TEST}"
  }

  echo "[${SELF_NAME}] self-test"

  local ok="${tmp}/ok"; _mk "${ok}"
  _case "a correct tree passes check 1" 0 check_no_production_reach "${ok}"
  _case "a correct tree passes check 2" 0 check_not_in_build_path "${ok}"
  _case "a correct tree passes check 3" 0 check_test_utils_is_dev_only "${ok}"
  _case "a correct tree passes check 4" 0 check_profile_trap_is_armed "${ok}"
  _case "a correct tree passes check 5" 0 check_no_foreign_debug_format "${ok}"
  _case "a correct tree passes check 6" 0 check_timeline_field_test_is_pinned "${ok}"

  # --- check 1, both directions and each token shape.
  local reach="${tmp}/reach"; _mk "${reach}"
  printf 'const rig = "haven-soak";\n' >> "${reach}/haven/lib/src/app.dart"
  _case "a production Dart file naming the crate fails" 1 check_no_production_reach "${reach}"

  local envreach="${tmp}/envreach"; _mk "${envreach}"
  printf 'let p = std::env::var("HAVEN_SOAK_PROFILE");\n' >> "${envreach}/haven-core/src/lib.rs"
  _case "a production Rust file reading a rig env var fails" 1 check_no_production_reach "${envreach}"

  local pathreach="${tmp}/pathreach"; _mk "${pathreach}"
  printf 'const p = "tooling/soak/profiles/pr.toml";\n' >> "${pathreach}/haven/rust_builder/src/api.rs"
  _case "a production file naming a rig path fails" 1 check_no_production_reach "${pathreach}"

  # --- check 2.
  local dep="${tmp}/dep"; _mk "${dep}"
  printf 'haven-soak = { path = "../../tooling/soak" }\n' >> "${dep}/${FFI_MANIFEST}"
  _case "a shipped manifest depending on the crate fails" 1 check_not_in_build_path "${dep}"

  local ck="${tmp}/ck"; _mk "${ck}"
  printf 'set(EXTRA "tooling/soak")\n' >> "${ck}/haven/rust_builder/cargokit/cmake/cargokit.cmake"
  _case "a cargokit config naming the crate path fails" 1 check_not_in_build_path "${ck}"

  local nopub="${tmp}/nopub"; _mk "${nopub}"
  sed -i 's/^publish = false$//' "${nopub}/${SOAK_MANIFEST}"
  _case "the crate dropping publish = false fails" 1 check_not_in_build_path "${nopub}"

  # --- check 3: THE ARM THAT MUST PASS is the dev-dependency, and the whole
  #     reason this is not a bare grep.
  local devdep="${tmp}/devdep"; _mk "${devdep}"
  _case "test-utils as a DEV-dependency passes" 0 check_test_utils_is_dev_only "${devdep}"

  local realdep="${tmp}/realdep"; _mk "${realdep}"
  cat >> "${realdep}/${FFI_MANIFEST}" <<'TOML'

[dependencies]
haven-core = { path = "../../haven-core", features = ["test-utils"] }
TOML
  _case "test-utils as a normal dependency fails" 1 check_test_utils_is_dev_only "${realdep}"

  local builddep="${tmp}/builddep"; _mk "${builddep}"
  cat >> "${builddep}/${FFI_MANIFEST}" <<'TOML'

[build-dependencies]
haven-core = { path = "../../haven-core", features = ["test-utils"] }
TOML
  _case "test-utils in a build-dependency table fails" 1 check_test_utils_is_dev_only "${builddep}"

  local targdev="${tmp}/targdev"; _mk "${targdev}"
  cat >> "${targdev}/${FFI_MANIFEST}" <<'TOML'

[target.'cfg(target_os = "android")'.dependencies]
haven-core = { path = "../../haven-core", features = ["test-utils"] }
TOML
  _case "test-utils in a target-specific NON-dev table fails" 1 check_test_utils_is_dev_only "${targdev}"

  local comment="${tmp}/comment"; _mk "${comment}"
  # shellcheck disable=SC2016
  printf '\n[dependencies]\n# never enable test-utils here\nserde = "1"\n' >> "${comment}/${FFI_MANIFEST}"
  _case "a comment naming the feature in a real table passes" 0 check_test_utils_is_dev_only "${comment}"

  local wrapper="${tmp}/wrapper"; _mk "${wrapper}"
  printf 'cargo build --features test-utils\n' >> "${wrapper}/scripts/build_release.sh"
  _case "the release wrapper naming the feature fails" 1 check_test_utils_is_dev_only "${wrapper}"

  # --- check 3, the OTHER door: a [features] alias. Every shape below leaves
  #     checks 2 and 4 green, and the first one alone would open the probe
  #     seams on every debug build of the app.
  local defaulton="${tmp}/defaulton"; _mk "${defaulton}"
  sed -i 's/^default = \[\]$/default = ["test-utils"]/' "${defaulton}/${CORE_MANIFEST}"
  _case "test-utils inside haven-core's default feature fails" 1 check_test_utils_is_dev_only "${defaulton}"

  local aliased="${tmp}/aliased"; _mk "${aliased}"
  printf 'full = [\n  "serde",\n  "test-utils",\n]\n' >> "${aliased}/${CORE_MANIFEST}"
  _case "test-utils inside another alias, over several lines, fails" 1 check_test_utils_is_dev_only "${aliased}"

  local ffialias="${tmp}/ffialias"; _mk "${ffialias}"
  printf '\n[features]\ndefault = ["haven-core/test-utils"]\n' >> "${ffialias}/${FFI_MANIFEST}"
  _case "a consumer aliasing haven-core/test-utils into its default fails" 1 check_test_utils_is_dev_only "${ffialias}"

  local foreignfeat="${tmp}/foreignfeat"; _mk "${foreignfeat}"
  printf 'integration-tests = ["clap", "mdk-core/test-utils"]\n' >> "${foreignfeat}/${CORE_MANIFEST}"
  _case "another crate's own test-utils feature is not haven-core's and passes" \
    0 check_test_utils_is_dev_only "${foreignfeat}"

  local nodefault="${tmp}/nodefault"; _mk "${nodefault}"
  sed -i '/^default = \[\]$/d' "${nodefault}/${CORE_MANIFEST}"
  _case "haven-core no longer declaring a default fails" 1 check_test_utils_is_dev_only "${nodefault}"

  # --- check 4: the disarming line, in every shape.
  local disarm="${tmp}/disarm"; _mk "${disarm}"
  printf '\n[profile.release]\ndebug-assertions = true\n' >> "${disarm}/haven-core/Cargo.toml"
  _case "a shipped manifest enabling debug-assertions fails" 1 check_profile_trap_is_armed "${disarm}"

  local second="${tmp}/second"; _mk "${second}"
  printf '\n[profile.soak]\ninherits = "release"\n' >> "${second}/${FFI_MANIFEST}"
  _case "a second [profile.soak] fails" 1 check_profile_trap_is_armed "${second}"

  local dropped="${tmp}/dropped"; _mk "${dropped}"
  sed -i 's/^\[profile.soak\]$/[profile.dev]/' "${dropped}/${SOAK_MANIFEST}"
  _case "the crate losing [profile.soak] fails" 1 check_profile_trap_is_armed "${dropped}"

  local commented="${tmp}/commented"; _mk "${commented}"
  printf '\n[profile.release]\n# debug-assertions = true would disarm the trap\n' \
    >> "${commented}/haven-core/Cargo.toml"
  _case "documenting the ban in a comment passes" 0 check_profile_trap_is_armed "${commented}"

  local nomanifest="${tmp}/nomanifest"; mkdir -p "${nomanifest}"
  _case "a tree with no manifest at all is BROKEN, not clean" 1 check_profile_trap_is_armed "${nomanifest}"

  # --- check 5.
  local dbgfmt="${tmp}/dbgfmt"; _mk "${dbgfmt}"
  printf 'fn f(e: SessionError) { log::warn!("{e:?}"); }\n' >> "${dbgfmt}/${SOAK_DIR}/src/lib.rs"
  _case "a {e:?} of a re-exported engine error fails" 1 check_no_foreign_debug_format "${dbgfmt}"

  local dbgmacro="${tmp}/dbgmacro"; _mk "${dbgmacro}"
  printf 'fn f(g: GroupId) { dbg!(g); }\n' >> "${dbgmacro}/${SOAK_DIR}/tests/timeline_fields.rs"
  _case "a dbg! of a foreign type in a test fails" 1 check_no_foreign_debug_format "${dbgmacro}"

  local seamfmt="${tmp}/seamfmt"; _mk "${seamfmt}"
  printf 'fn f(o: IngestOutcome) { panic!("{:#?}", o); }\n' >> "${seamfmt}/${SEAM_TEST}"
  _case "the haven-core seam test is scanned too" 1 check_no_foreign_debug_format "${seamfmt}"

  local local_dbg="${tmp}/localdbg"; _mk "${local_dbg}"
  printf 'fn f(t: SimTag) { println!("{t:?}"); }\n' >> "${local_dbg}/${SOAK_DIR}/src/lib.rs"
  _case "a Debug rendering of the rig's OWN type passes" 0 check_no_foreign_debug_format "${local_dbg}"

  local marked="${tmp}/marked"; _mk "${marked}"
  printf 'fn f(e: SessionError) { log::warn!("{e:?}"); } // log-scan-ok: fixture, never compiled\n' \
    >> "${marked}/${SOAK_DIR}/src/lib.rs"
  _case "a reviewed exception with a reason passes" 0 check_no_foreign_debug_format "${marked}"

  # --- check 6.
  local nopin="${tmp}/nopin"; _mk "${nopin}"
  printf 'const DECLARED_FIELDS: usize = 12;\nfn t() {}\n' \
    > "${nopin}/${SOAK_DIR}/tests/timeline_fields.rs"
  _case "a pin that nothing asserts fails" 1 check_timeline_field_test_is_pinned "${nopin}"

  local notest="${tmp}/notest"; _mk "${notest}"
  rm -f "${notest}/${SOAK_DIR}/tests/timeline_fields.rs"
  _case "a crate with no field-class test at all fails" 1 check_timeline_field_test_is_pinned "${notest}"

  local nocrate="${tmp}/nocrate"; _mk "${nocrate}"
  rm -rf "${nocrate}/${SOAK_DIR}"
  _case "checks 5 and 6 are inert while the crate is absent" 0 check_timeline_field_test_is_pinned "${nocrate}"
  _case "...and check 5 reads nothing rather than reporting clean" 0 check_no_foreign_debug_format "${nocrate}"

  # The landing window: a crate with sources and even a tests/ directory, but
  # no timeline yet. Inert for check 6, because the subject of that check is the
  # TIMELINE's fields — and ENFORCING again the moment src/timeline.rs exists,
  # which the `notest` fixture above is.
  local landing="${tmp}/landing"; _mk "${landing}"
  rm -f "${landing}/${SOAK_DIR}/src/timeline.rs"
  _case "check 6 is inert while the crate has no timeline yet" 0 check_timeline_field_test_is_pinned "${landing}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
  return 0
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
  fi
  if [[ $# -gt 0 ]]; then
    echo "usage: $(basename "$0") [--self-test]" >&2
    exit 2
  fi
  local required
  for required in "${FFI_MANIFEST}" 'haven-core/src' 'haven/lib'; do
    [[ -e "${REPO_ROOT}/${required}" ]] || {
      echo "ERROR: ${required} not found under ${REPO_ROOT}" >&2
      exit 2
    }
  done

  run_all "${REPO_ROOT}"

  if (( FAILED )); then
    echo >&2
    echo "The Tier-1 soak rig links haven-core with test-utils on: the five probe" >&2
    echo "seams and the unencrypted-store constructors. It must stay out of the" >&2
    echo "shipped app and out of every build path, and the compile-time trap that" >&2
    echo "enforces that must stay armed. See the header of this script and" >&2
    echo "docs/SOAK_LANE.md." >&2
    exit 1
  fi
  log "OK — no production reach, no build-path dependency, test-utils is a dev edge only and no [features] alias pulls it in, the compile_error! trap is armed, no foreign Debug rendering in the rig, the timeline field-class pin holds."
}

main "$@"
