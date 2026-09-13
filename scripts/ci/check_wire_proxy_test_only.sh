#!/usr/bin/env bash
#
# CI guard: the recording wire proxy is a TEST INSTRUMENT and must stay one.
#
# ## What it records, and why that is a hazard
#
# `tooling/e2e/local-relay` builds `haven-wire-proxy`, which sits between the
# app and the hermetic relay and writes an NDJSON journal of every WebSocket
# message in both directions: full event JSON (ciphertext, ephemeral pubkeys,
# ids, signatures), REQ filters carrying long-term identity pubkeys, bounded
# previews of anything unparseable, and a `relay_url` on every line mapping all
# of it to a named endpoint. That is a complete traffic-analysis corpus for
# whoever holds the file.
#
# It exists because the oracle it replaces was a forbid-list scoped to one
# circle's kind-445 stream, so a new kind or tag passed in silence. Recording
# EVERYTHING is what makes a closed-world assertion possible — and is exactly
# why the instrument needs a boundary of its own. Same shape as
# check_no_exporter_label_override.sh (a token that must appear nowhere) and
# check_m7_background_delivery_assertion.sh (a test hook that must not drift
# into the shipped app).
#
# ## The invariants
#
#   1. NO PRODUCTION REACH. No file under haven/lib, haven-core/src or
#      haven/rust_builder/src may name the proxy, its journal, its env vars or
#      its sentinel. The harness may (haven/integration_test is not scanned).
#
#   2. NOT IN A BUILD PATH. No shipped manifest may depend on either tooling
#      crate — the recorder (tooling/e2e/local-relay) or the runtime log
#      scanner (tooling/logscan) — so neither can enter an APK, an IPA or the
#      release wrapper, and both declare `publish = false`.
#
#   3. THE RAW EVIDENCE IS NEVER AN ARTIFACT. No workflow may name a `.ndjson`
#      path, or any `/tmp/haven-wire-*` path other than a `.log`, in an
#      upload-artifact step. CI artifacts are retained for days on a public
#      repository; the redacted summary
#      (tooling/e2e/ci/summarize-wire-journal.sh) is what a lane uploads. Nor
#      may an upload entry end in a bare wildcard — `/tmp/**`, `/tmp/haven*`,
#      `/tmp/logs/*` — a sweep that takes whatever sits beside the named files,
#      a relocated sidecar included; `/tmp/strfry-profile-*.log` stays legal
#      because its extension still bounds what it matches.
#
#      The prefix half of that ban exists for the MLS-GROUP-ID SIDECAR
#      (`/tmp/haven-wire-proxy.mlsgroupid`), which the device fills over the
#      proxy's control channel so a host-side oracle can assert Security Rule 4
#      — that the real MLS group id never appears on the wire. Asserting an
#      ABSENCE requires holding the value, so that file is the one thing on the
#      runner MORE sensitive than the journal, and uploading it would publish
#      exactly what Rule 4 protects. The proxy's own `.log` is exempt: Rule 6
#      keeps it to lengths, counts and fixed labels, never a recorded value.
#
#   4. THE SUMMARY STAYS SCANNED. That summary script must keep running its
#      output through scan-logs-for-secrets.sh, so a redaction bug is caught
#      before the file becomes an artifact rather than after.
#
#   5. RECORDING CANNOT BREAK TRAFFIC. Fail-open is a property of the recorder's
#      TYPE, not of its call sites: every `pub fn record*` in journal.rs returns
#      `u64` and nothing else, so there is no error for a caller to propagate
#      and no `?` for a later edit to add. Its non-test code also carries no
#      `unwrap`/`expect`/`panic!`, since a panic in the recorder would unwind
#      through the connection pump and take the proxied traffic down with it —
#      the instrument breaking the product, which is the one outcome fail-open
#      exists to prevent.
#
#   6. THE NEEDLE SIDECARS ARE NEVER READ OUT EITHER. The declaration channel
#      writes `/tmp/haven-soak/needles/<role>.needles.decl` (every value a run
#      declared, verbatim, secret-class material included) and
#      `<role>.canaries.json`; `haven-logscan seal` adds `<run>.needles.json`.
#      These are the needles a scanner searches FOR, so publishing one turns the
#      absence assertion into a lookup table for whoever reads the artifact.
#
#      The ban is keyed on WHAT THE FILE IS — its extension — and on the
#      soak root, for the reason recorded in check 3: a location-keyed ban on
#      the MLS sidecar was defeated twice by callers moving the path. It covers
#      five exposure shapes, in workflows and in tooling/e2e/ci runners alike:
#      an upload-artifact `path:` (check 3); a reading command on the file —
#      `cat`/`tee`/`head`/`tail`/`base64`/`less`/`more`/`awk`/`sed`/`jq`/`od`/
#      `xxd`/`strings`/`cut`/`nl` — at a command position; a redirection that
#      reads it without naming a command (`< file`, `$(< file)`); a
#      `$GITHUB_STEP_SUMMARY` write; and a `gh issue`/`gh pr` body. `grep` is
#      deliberately NOT in the list: the runners' own self-tests grep their
#      source for lines that name the directory. WRITING and DELETING are
#      untouched: `seal --out`, `rm`, `shred` and `mkdir` are how the lane
#      legitimately handles these files, and a guard that forbade them would
#      forbid the cleanup too.
#
#      What a per-line grep cannot see, stated so nobody reads more into a
#      green run than it proves: an INDIRECT read — `f=…/x.needles.decl` on
#      one line and `cat "$f"` on another — is outside this check. The ban is
#      keyed on the line that spells the path, not the one that uses it.
#
#      `--disclose-values` (haven-logscan's local-triage flag, which prints
#      matched text) may appear in no workflow and no runner; and there is no
#      `HAVEN_NEEDLE_DIR`, by design — the directory is a constant in
#      tooling/e2e/local-relay/src/needles.rs precisely so this guard can name
#      it, and an env override would reinstate the defeat above.
#
#   7. THE SCANNER BINARY IS NOT A LANE'S TO CHOOSE. `HAVEN_LOGSCAN_BIN` is
#      read at call time by scan-logs.sh and the runner so their self-tests can
#      inject a fake; an e2e workflow that set it would point the whole
#      log-privacy gate at a binary of its choosing — a stub that exits 0 is a
#      green lane that scanned nothing. No `.github/workflows/e2e-*.yml` may
#      assign it (an `env:` key, an `export`, an inline `NAME=… cmd`); the one
#      legitimate setter is rust-check.yml's logscan-tooling job, which is not
#      an e2e lane and points it at the binary it just built.
#
# Pure grep/awk, no toolchain — belongs in repo-guards.yml.
#
# Usage:
#   bash scripts/ci/check_wire_proxy_test_only.sh
#   bash scripts/ci/check_wire_proxy_test_only.sh --self-test
#
# Exit codes:
#   0  all invariants hold
#   1  an invariant is violated
#   2  expected paths missing (misconfiguration)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

readonly CRATE_DIR='tooling/e2e/local-relay'
readonly LOGSCAN_DIR='tooling/logscan'
# Both harness-only crates: neither may enter a shipped build (check 2).
readonly TOOLING_CRATES=("${CRATE_DIR}" "${LOGSCAN_DIR}")
readonly JOURNAL_RS='tooling/e2e/local-relay/src/journal.rs'
readonly SUMMARIZE_SH='tooling/e2e/ci/summarize-wire-journal.sh'
# Lane runners. Scanned beside the workflows because a `cat` in a runner reaches
# the same job log an `echo` in a workflow step does.
readonly E2E_CI_DIR='tooling/e2e/ci'
readonly SELF_TEST_FIXTURES=78

# Trees that ship. `haven/integration_test` is deliberately absent: that is the
# harness, and it is where the sentinel emitter belongs.
readonly PRODUCTION_TREES=(
  'haven/lib'
  'haven-core/src'
  'haven/rust_builder/src'
)

# Every name that would betray the proxy having been wired into the app.
#
# HAVEN_WIRE_MLS_GROUP_ID covers both the control VERB and the
# HAVEN_WIRE_MLS_GROUP_ID_FILE env var, and belongs here for a reason the
# others do not have: a shipped app that could emit that verb would be handing
# its real MLS group id to whatever it is connected to. The harness is where
# the emitter belongs (haven/integration_test is not scanned).
#
# HAVEN_NEEDLE_DECL and HAVEN_WIRE_CANARY_MANIFEST carry exactly the same
# reason: a shipped app able to emit either would be handing whatever it
# declares — pubkeys, group ids, names, coordinates, secret-class material — to
# whatever it is connected to. HAVEN_NEEDLE_DIR is here as a name that must
# exist NOWHERE: the needle directory is a constant so the path bans below can
# name it, and an override would make the subject of those bans relocatable.
readonly FORBIDDEN_TOKENS=(
  'haven-wire-proxy'
  'haven_local_relay'
  'HAVEN_WIRE_PROXY'
  'HAVEN_WIRE_JOURNAL'
  'HAVEN_WIRE_SENTINEL'
  'HAVEN_WIRE_MLS_GROUP_ID'
  'HAVEN_NEEDLE_DECL'
  'HAVEN_WIRE_CANARY_MANIFEST'
  'HAVEN_NEEDLE_DIR'
)

# Manifests and wrappers that decide what gets built into a shipped artifact.
readonly BUILD_MANIFESTS=(
  'haven-core/Cargo.toml'
  'haven/rust_builder/Cargo.toml'
  'haven/pubspec.yaml'
  'scripts/build_release.sh'
)

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

# ---------------------------------------------------------------------------
# Checks. Each takes an explicit root so --self-test can point them at fixtures.
# ---------------------------------------------------------------------------

# 1. No production file names the proxy. Flat token ban, comments included:
#    prose that needs to mention it can say "the recording wire proxy", and a
#    flat ban needs no comment-parsing machinery a rewording could sidestep.
check_no_production_reach() {
  local root="$1" rc=0 tree token hits
  for tree in "${PRODUCTION_TREES[@]}"; do
    [[ -d "${root}/${tree}" ]] || continue
    for token in "${FORBIDDEN_TOKENS[@]}"; do
      hits="$(grep -rlF -- "${token}" "${root}/${tree}" 2>/dev/null || true)"
      if [[ -n "${hits}" ]]; then
        printf '%s\n' "${hits}" >&2
        fail "'${token}' appears under ${tree}. The wire proxy records full event JSON and REQ filters carrying identity pubkeys; it must be unreachable from the shipped app (Security Rule 10)."
        rc=1
      fi
    done
  done
  return "${rc}"
}

# 2. No shipped manifest pulls the crate in.
check_not_in_build_path() {
  local root="$1" rc=0 manifest crate
  for crate in "${TOOLING_CRATES[@]}"; do
    for manifest in "${BUILD_MANIFESTS[@]}"; do
      local f="${root}/${manifest}"
      [[ -f "${f}" ]] || continue
      if grep -qF -- "${crate}" "${f}"; then
        fail "${manifest} references ${crate}. A harness-only crate must never be part of a build that ships."
        rc=1
      fi
    done
    # `publish = false` keeps it off crates.io even by accident.
    local crate_toml="${root}/${crate}/Cargo.toml"
    if [[ -f "${crate_toml}" ]] && ! grep -qE '^[[:space:]]*publish[[:space:]]*=[[:space:]]*false' "${crate_toml}"; then
      fail "${crate}/Cargo.toml no longer declares publish = false."
      rc=1
    fi
  done
  return "${rc}"
}

# Prints `<file>:<line>` for every FORBIDDEN path inside the `path:` block of an
# upload-artifact step. Comment text is stripped first, so documenting the ban
# does not trip it.
#
# Two rules, and the second is a PREFIX ban with one narrow exemption:
#
#   * any `.ndjson` — the raw journal, wherever it lives;
#   * any `/tmp/haven-wire-*` path that does NOT end in `.log`.
#
# The prefix form is what covers the MLS-group-id sidecar
# (`/tmp/haven-wire-proxy.mlsgroupid`), and covers it by default rather than by
# extension: anything else the proxy ever writes beside its journal — a claim
# file, a future dump — is caught without this guard having to learn its name
# first. The `.log` exemption is deliberate and load-bearing: two lanes already
# upload `/tmp/haven-wire-proxy.log`, which by Security Rule 6 carries only
# lengths, counts and fixed labels, never a recorded value.
upload_forbidden_path_hits() { # upload_forbidden_path_hits <workflow-file>
  awk '
    function forbidden(text,   rest, tok) {
      if (text ~ /\.ndjson/) return 1
      # The sidecar carries a Security Rule 4 value, so it is banned by the
      # shape of its NAME, wherever it lives. An earlier version banned the
      # literal prefix /tmp/haven-wire- and exempted *.log, which two review
      # passes independently defeated: the path is caller-controlled, so
      # HAVEN_WIRE_MLS_GROUP_ID_FILE=/tmp/haven-wire-ids.log took the .log
      # exemption, and HAVEN_WIRE_PROXY_RUN_DIR=${RUNNER_TEMP} moved the file
      # out from under the prefix entirely. A guard whose subject can be
      # relocated by an env var must key on what the file IS.
      if (text ~ /\.mlsgroupid/) return 1
      # The needle sidecars and the sealed manifest, keyed on WHAT THEY ARE the
      # first time rather than on where they live — the defeat above, learned.
      # A relocated `${RUNNER_TEMP}/alice.needles.decl` is still a file holding
      # every value a run declared.
      if (text ~ /\.needles\.decl|\.needles\.json|\.canaries\.json|\.attribution\.json/) return 1
      # The directory, and the soak root above it: nothing under it is ever
      # uploadable, so `needles/` and a `/tmp/haven-soak/*` sweep are both out.
      if (text ~ /needles\//) return 1
      if (text ~ /\/tmp\/haven-soak/) return 1
      # A wholesale directory upload sweeps up whatever the recorder wrote,
      # including a relocated sidecar.
      if (text ~ /^[[:space:]]*-?[[:space:]]*\/tmp\/?\*?[[:space:]]*$/) return 1
      # ...and so does any entry ending in a bare wildcard: `/tmp/**`,
      # `/tmp/haven*`, `/tmp/logs/*` take whatever sits beside the named
      # files. An extension after the last `/` bounds the match, so
      # `/tmp/strfry-profile-*.log` stays legal.
      entry = text
      sub(/^[[:space:]]*(path:)?[[:space:]]*-?[[:space:]]*/, "", entry)
      sub(/[[:space:]]*$/, "", entry)
      if (entry ~ /\*$/) {
        last = entry
        sub(/.*\//, "", last)
        if (last !~ /\./) return 1
      }
      rest = text
      while (match(rest, /\/tmp\/haven-wire-[^[:space:]]*/)) {
        tok = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        # The .log exemption stays: e2e-android.yml legitimately uploads
        # /tmp/haven-wire-proxy.log, and every write to that fd is a length, a
        # count, a fixed label or an ErrorKind — verified, never a value.
        if (tok !~ /\.log$/) return 1
      }
      return 0
    }
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      indent = match(line, /[^ ]/) - 1

      if (line ~ /^[[:space:]]*-[[:space:]]+name:/) { in_step = 0; in_path = 0 }
      if (line ~ /uses:[[:space:]]*actions\/upload-artifact/) { in_step = 1; next }

      if (in_path) {
        if (indent > path_indent) {
          if (forbidden(line)) print FILENAME ":" NR
          next
        }
        in_path = 0
      }

      if (in_step && line ~ /^[[:space:]]*path:/) {
        in_path = 1
        path_indent = indent
        if (forbidden(line)) print FILENAME ":" NR
        next
      }
    }
  ' "$1"
}

# 3. Neither the raw journal nor the MLS-group-id sidecar is ever uploaded.
check_raw_journal_not_uploaded() {
  local root="$1" rc=0 workflow hits
  local dir="${root}/.github/workflows"
  [[ -d "${dir}" ]] || { fail ".github/workflows not found"; return 1; }
  for workflow in "${dir}"/*.yml "${dir}"/*.yaml; do
    [[ -f "${workflow}" ]] || continue
    hits="$(upload_forbidden_path_hits "${workflow}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "$(basename "${workflow}") uploads a wire-proxy evidence path as an artifact. The RAW journal (.ndjson) is a full traffic transcript, and /tmp/haven-wire-*.mlsgroupid holds the REAL MLS group ids — the very values Security Rule 4 says must never leave the device. Both must die with the runner. Only the proxy's own .log (lengths and fixed labels, never a value) and the redacted summary from ${SUMMARIZE_SH} may be uploaded."
      rc=1
    fi
  done
  return "${rc}"
}

# Prints `<file>:<line>` for every line that READS a needle file into a place a
# human or a public artifact can see it.
#
# Deny-list by CONTEXT, not by path: the lane has to write, delete and pass these
# files around (`seal --out`, `--decl`, `rm -f`, `shred`, `mkdir`), and a rule
# that caught those would be turned off within a week. What is forbidden is the
# four shapes that PUBLISH a file's contents — a reading command, a step-summary
# write, an issue/PR body — plus `--disclose-values`, which makes the scanner
# itself print the matched text.
#
# `tee` counts as a reading command even though it writes: it copies to stdout,
# and a step's stdout is the job log, which cannot be retracted per step.
needle_exposure_hits() { # needle_exposure_hits <file>
  awk '
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next

      # haven-logscan prints matched text with this flag. Local triage only.
      if (line ~ /--disclose-values/) { print FILENAME ":" NR ":disclose-values"; next }

      if (line !~ /\.needles\.decl|\.needles\.json|\.canaries\.json|\.attribution\.json|needles\/|\/tmp\/haven-soak/) next

      if (line ~ /(^|[;&|(]|[[:space:]])(cat|tee|head|tail|base64|less|more|awk|sed|jq|od|xxd|strings|cut|nl)([[:space:]]|$)/) {
        print FILENAME ":" NR ":read-command"; next
      }
      # `< file` and `$(< file)` read without naming a command. A `<` must be
      # followed by whitespace, a quote or a slash so that `<<EOF` heredocs,
      # `<(…)` process substitutions and a `<path>` usage placeholder are not
      # read as redirections.
      if (line ~ /(^|[^<>])<([[:space:]]+[^[:space:]]*|["\/][^[:space:]]*)(\.needles\.decl|\.needles\.json|\.canaries\.json|\.attribution\.json|needles\/|\/tmp\/haven-soak)/ \
          || line ~ /\$\([[:space:]]*<[[:space:]]*["\/]?[^[:space:]]*(\.needles\.decl|\.needles\.json|\.canaries\.json|\.attribution\.json|needles\/|\/tmp\/haven-soak)/) {
        print FILENAME ":" NR ":redirect-read"; next
      }
      if (line ~ /GITHUB_STEP_SUMMARY/) { print FILENAME ":" NR ":step-summary"; next }
      if (line ~ /gh[[:space:]]+(issue|pr)[[:space:]]/) { print FILENAME ":" NR ":gh-body"; next }
    }
  ' "$1"
}

# 6. No workflow or runner reads a needle file out, and no env var can move one.
check_needle_files_are_not_exposed() {
  local root="$1" rc=0 file hits
  local -a scanned=()
  local dir="${root}/.github/workflows"
  [[ -d "${dir}" ]] || { fail ".github/workflows not found"; return 1; }
  for file in "${dir}"/*.yml "${dir}"/*.yaml "${root}/${E2E_CI_DIR}"/*.sh; do
    [[ -f "${file}" ]] || continue
    scanned+=("${file}")
  done
  if (( ${#scanned[@]} == 0 )); then
    fail "no workflow or ${E2E_CI_DIR} runner found — this check would pass vacuously."
    return 1
  fi

  for file in "${scanned[@]}"; do
    hits="$(needle_exposure_hits "${file}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "$(basename "${file}") publishes a needle file's contents (or passes --disclose-values). Those files hold every value a run declared — the needles a scanner searches FOR — so printing one turns an absence assertion into a lookup table for whoever reads the log. Writing, deleting and passing the paths as arguments are fine; reading them out is not."
      rc=1
    fi
  done

  # The directory is a CONSTANT so the bans above have a subject. An override
  # would relocate it out from under them — the defeat check 3 records, twice.
  local -a override_trees=("${root}/${CRATE_DIR}/src" "${root}/${E2E_CI_DIR}" "${dir}")
  local tree
  for tree in "${override_trees[@]}"; do
    [[ -d "${tree}" ]] || continue
    hits="$(grep -rlF -- 'HAVEN_NEEDLE_DIR' "${tree}" 2>/dev/null || true)"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "HAVEN_NEEDLE_DIR appears under ${tree#"${root}/"}. The needle directory must stay a constant: a path a caller can relocate defeats every ban on it, which is exactly how the MLS sidecar's first ban was broken."
      rc=1
    fi
  done
  return "${rc}"
}

# 7. No e2e lane may point the log-privacy gate at a binary of its choosing.
check_logscan_binary_not_overridden() {
  local root="$1" rc=0 file hits n=0
  local dir="${root}/.github/workflows"
  [[ -d "${dir}" ]] || { fail ".github/workflows not found"; return 1; }
  for file in "${dir}"/e2e-*.yml; do
    [[ -f "${file}" ]] || continue
    n=$(( n + 1 ))
    # Comment text stripped first, so documenting the ban does not trip it.
    hits="$(awk '{
        line = $0
        sub(/[[:space:]]*#.*$/, "", line)
        if (line ~ /(^|[^A-Za-z0-9_])HAVEN_LOGSCAN_BIN[[:space:]]*[:=]/) print FILENAME ":" NR
      }' "${file}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "$(basename "${file}") assigns HAVEN_LOGSCAN_BIN. That variable exists so the wrapper's and the runner's --self-test can inject a fake scanner; an e2e lane setting it points its whole log-privacy gate at a binary of its choosing, and a stub that exits 0 is a green lane that scanned nothing. Lanes run the binary the workflow built at tooling/logscan/target/release/haven-logscan; rust-check.yml's logscan-tooling job is the one legitimate setter."
      rc=1
    fi
  done
  if (( n == 0 )); then
    fail "no .github/workflows/e2e-*.yml found — this check would pass vacuously."
    return 1
  fi
  return "${rc}"
}

# 4. The summary keeps being scanned before it can become an artifact.
check_summary_is_scanned() {
  local root="$1" f="${root}/${SUMMARIZE_SH}"
  [[ -f "${f}" ]] || { fail "${SUMMARIZE_SH} not found — nothing produces the upload-safe form of the journal"; return 1; }
  # Matched from a capture, never a pipe: a `grep -q` that stops at the call
  # SIGPIPEs a writer with text left to send, and pipefail reads that as a miss.
  if ! grep -qF 'scan-logs-for-secrets.sh' <<<"$(grep -vE '^[[:space:]]*#' "${f}")"; then
    fail "${SUMMARIZE_SH} no longer runs its output through scan-logs-for-secrets.sh. The redaction is an allow-list and should hold on its own; this is the belt that catches it when it does not, BEFORE the file becomes a 14-day artifact."
    return 1
  fi
  return 0
}

# Everything in journal.rs above the `#[cfg(test)]` marker, with comment lines
# removed — the code that runs in CI lanes, as opposed to its own tests.
journal_production_code() { # journal_production_code <file>
  awk '/^#\[cfg\(test\)\]/ { exit } { print }' "$1" \
    | grep -vE '^[[:space:]]*(///|//!|//)'
}

# Signatures of every `pub fn record*`, flattened onto one line each.
record_signatures() { # record_signatures <file>
  awk '
    /pub fn record/ { collecting = 1; sig = "" }
    collecting {
      sig = sig " " $0
      if (index($0, "{")) { print sig; collecting = 0 }
    }
  ' "$1"
}

# 5. Recording cannot fail at a call site and cannot panic.
check_recorder_cannot_break_traffic() {
  local root="$1" f="${root}/${JOURNAL_RS}" rc=0 code sigs
  [[ -f "${f}" ]] || { fail "${JOURNAL_RS} not found"; return 1; }

  sigs="$(record_signatures "${f}")"
  if [[ -z "${sigs}" ]]; then
    # An extractor that matches nothing would report "all signatures fine"
    # forever. Refuse to pass on an empty set.
    fail "${JOURNAL_RS}: found NO 'pub fn record*' signature — either the recorder was renamed or this guard's extractor has rotted into a no-op."
    rc=1
  fi
  while IFS= read -r sig; do
    [[ -z "${sig}" ]] && continue
    if [[ "${sig}" != *"-> u64"* ]]; then
      fail "${JOURNAL_RS}: a recording entry point does not return plain u64 — fail-open must be unrepresentable at the call site, not a convention. Offending signature:${sig}"
      rc=1
    fi
    if [[ "${sig}" == *"Result"* ]]; then
      fail "${JOURNAL_RS}: a recording entry point returns a Result. A caller could then propagate a journal failure into the connection pump and kill proxied traffic — the instrument breaking the product. Offending signature:${sig}"
      rc=1
    fi
  done <<< "${sigs}"

  code="$(journal_production_code "${f}")"
  if [[ -z "${code//[[:space:]]/}" ]]; then
    fail "${JOURNAL_RS}: no production code found above #[cfg(test)] — this guard would pass vacuously."
    rc=1
  fi
  local panicky
  panicky="$(grep -nE '\.unwrap\(|\.expect\(|panic!|todo!|unimplemented!' <<<"${code}" || true)"
  if [[ -n "${panicky}" ]]; then
    printf '%s\n' "${panicky}" >&2
    fail "${JOURNAL_RS}: production code can panic. A panic in the recorder unwinds through the connection pump and takes the proxied traffic with it; every failure must latch the degraded flag instead."
    rc=1
  fi
  return "${rc}"
}

run_all() {
  local root="$1"
  check_no_production_reach "${root}"
  check_not_in_build_path "${root}"
  check_raw_journal_not_uploaded "${root}"
  check_summary_is_scanned "${root}"
  check_recorder_cannot_break_traffic "${root}"
  check_needle_files_are_not_exposed "${root}"
  check_logscan_binary_not_overridden "${root}"
}

# ---------------------------------------------------------------------------
# Self-test. Fixtures pin BOTH directions for every check: the shape that must
# pass, and the exact regression that must fail. A guard made of greps is worth
# only what its fixtures prove, and several of these checks are the kind that
# would sit green forever if their extractor stopped matching.
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
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _mk() { # _mk <root> — a minimal tree in the shape the guard expects
    local r="$1"
    mkdir -p "${r}/haven/lib/src" "${r}/haven-core/src" \
             "${r}/haven/rust_builder/src" "${r}/haven/integration_test/e2e/_lib" \
             "${r}/.github/workflows" "${r}/${CRATE_DIR}/src" \
             "${r}/tooling/e2e/ci" "${r}/scripts"
    printf 'void main() {}\n' > "${r}/haven/lib/src/app.dart"
    printf 'pub fn x() {}\n' > "${r}/haven-core/src/lib.rs"
    printf 'pub fn y() {}\n' > "${r}/haven/rust_builder/src/api.rs"
    # The harness legitimately names EVERY control verb; it must never be
    # flagged for any of them.
    printf "const t = String.fromEnvironment('HAVEN_WIRE_SENTINEL');\nconst m = 'HAVEN_WIRE_MLS_GROUP_ID';\nconst n = 'HAVEN_NEEDLE_DECL';\nconst c = 'HAVEN_WIRE_CANARY_MANIFEST';\n" \
      > "${r}/haven/integration_test/e2e/_lib/test_relay.dart"

    # The needle directory as a CONSTANT, which is what keeps it bannable.
    printf 'pub const NEEDLE_DIR: &str = "/tmp/haven-soak/needles";\n' \
      > "${r}/${CRATE_DIR}/src/needles.rs"
    # A lane runner doing everything it legitimately does with these files:
    # create the directory, seal from them, hand the paths on, delete them.
    cat > "${r}/${E2E_CI_DIR}/run-single-avd-scenario.sh" <<'SH'
#!/usr/bin/env bash
mkdir -m 0700 -p /tmp/haven-soak/needles
haven-logscan seal --decl /tmp/haven-soak/needles/default.needles.decl \
  --out /tmp/haven-soak/needles/run-1.needles.json
bash tooling/e2e/ci/scan-logs.sh /tmp/haven-soak/needles/run-1.needles.json --sink drive=/tmp/flutter-drive.log
tail -n 50 /tmp/flutter-drive.log
# NEVER cat /tmp/haven-soak/needles/default.needles.decl, and never pass
# --disclose-values here: reproduce locally instead.
rm -f /tmp/haven-soak/needles/*
SH

    printf '[package]\nname = "haven-local-relay"\npublish = false\n' \
      > "${r}/${CRATE_DIR}/Cargo.toml"
    mkdir -p "${r}/${LOGSCAN_DIR}"
    printf '[package]\nname = "haven-logscan"\npublish = false\n' \
      > "${r}/${LOGSCAN_DIR}/Cargo.toml"
    printf '[package]\nname = "haven-core"\n' > "${r}/haven-core/Cargo.toml"
    printf '[package]\nname = "rust_builder"\n' > "${r}/haven/rust_builder/Cargo.toml"
    printf 'name: haven\n' > "${r}/haven/pubspec.yaml"
    printf '#!/usr/bin/env bash\nflutter build apk\n' > "${r}/scripts/build_release.sh"

    cat > "${r}/${JOURNAL_RS}" <<'RS'
//! Doc mention of unwrap() and panic! that must not count as code.
impl WireJournal {
    pub fn record(
        &self,
        conn_id: &str,
        ts_ms: u64,
    ) -> u64 {
        self.emit()
    }

    pub fn record_conn_open(&self, conn_id: &str, ts_ms: u64) -> u64 {
        self.emit()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() {
        let x: Option<u8> = None;
        x.expect("tests may panic all they like");
    }
}
RS

    cat > "${r}/${SUMMARIZE_SH}" <<'SH'
#!/usr/bin/env bash
"${BIN}" --summarize "${JOURNAL}" --out "${OUT}"
bash "${SCRIPT_DIR}/scan-logs-for-secrets.sh" "${OUT}"
SH

    cat > "${r}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - name: Upload failure artifacts
        if: failure()
        uses: actions/upload-artifact@v6
        with:
          name: e2e
          path: |
            /tmp/flutter-test.log
            /tmp/wire-summary.log
            /tmp/haven-wire-proxy.log
          retention-days: 14
      - name: Start the recorder
        run: HAVEN_WIRE_JOURNAL=/tmp/haven-wire-journal.ndjson bash tooling/e2e/ci/start-wire-proxy.sh
YAML
    # An e2e lane doing what a lane legitimately does with the scanner: build
    # it and run the gate — never choose the binary (check 7).
    cat > "${r}/.github/workflows/e2e-lane.yml" <<'YAML'
jobs:
  lane:
    env:
      HAVEN_LOGSCAN: "true"
    steps:
      - name: Build the runtime log scanner
        run: cargo build --release --manifest-path tooling/logscan/Cargo.toml
      - name: Scan captured logs for secrets before upload
        # Never set HAVEN_LOGSCAN_BIN here: the lane runs the binary it built.
        run: bash tooling/e2e/ci/scan-logs.sh --manifest /tmp/haven-soak/needles/run.needles.json --sink diag=/tmp/diag.log
YAML
  }

  local ok="${tmp}/ok"; _mk "${ok}"

  echo "self-test: check 1 — no production reach"
  _case "healthy tree passes" 0 check_no_production_reach "${ok}"
  _case "harness naming the sentinel is not flagged" 0 check_no_production_reach "${ok}"

  local leaked="${tmp}/leaked"; _mk "${leaked}"
  printf "const url = String.fromEnvironment('HAVEN_WIRE_PROXY_PORT');\n" \
    > "${leaked}/haven/lib/src/app.dart"
  _case "proxy env var in haven/lib fails" 1 check_no_production_reach "${leaked}"

  local core_leaked="${tmp}/coreleak"; _mk "${core_leaked}"
  printf 'use haven_local_relay::journal::WireJournal;\n' \
    > "${core_leaked}/haven-core/src/lib.rs"
  _case "crate imported from haven-core fails" 1 check_no_production_reach "${core_leaked}"

  # A COMMENT is not an exemption. Flat token ban (see the header).
  local commented="${tmp}/commented"; _mk "${commented}"
  printf '// never call haven-wire-proxy from here\nvoid main() {}\n' \
    > "${commented}/haven/lib/src/app.dart"
  _case "even a comment mentioning the proxy fails" 1 check_no_production_reach "${commented}"

  # A shipped app that could emit the MLS-group-id verb would be handing its
  # real group id to whatever it is connected to — Security Rule 4, in the app
  # rather than in the harness.
  local mlsleak="${tmp}/mlsleak"; _mk "${mlsleak}"
  printf "void main() { ws.send('[\"HAVEN_WIRE_MLS_GROUP_ID\",\$id]'); }\n" \
    > "${mlsleak}/haven/lib/src/app.dart"
  _case "the mls-group-id verb in haven/lib fails" 1 check_no_production_reach "${mlsleak}"

  local mlsenv="${tmp}/mlsenv"; _mk "${mlsenv}"
  printf 'pub const P: &str = "HAVEN_WIRE_MLS_GROUP_ID_FILE";\n' \
    > "${mlsenv}/haven-core/src/lib.rs"
  _case "the sidecar env var in haven-core fails" 1 check_no_production_reach "${mlsenv}"

  # The same reasoning for the needle channel: an app that could declare a
  # needle would be handing the declared value to whatever it is connected to.
  _case "the harness naming the needle verbs is not flagged" 0 check_no_production_reach "${ok}"
  local declleak="${tmp}/declleak"; _mk "${declleak}"
  printf "void main() { ws.send('[\"HAVEN_NEEDLE_DECL\",{\"value\":\$v}]'); }\n" \
    > "${declleak}/haven/lib/src/app.dart"
  _case "the needle-decl verb in haven/lib fails" 1 check_no_production_reach "${declleak}"

  local canaryleak="${tmp}/canaryleak"; _mk "${canaryleak}"
  printf 'pub const V: &str = "HAVEN_WIRE_CANARY_MANIFEST";\n' \
    > "${canaryleak}/haven-core/src/lib.rs"
  _case "the canary-manifest verb in haven-core fails" 1 check_no_production_reach "${canaryleak}"

  local dirleak="${tmp}/dirleak"; _mk "${dirleak}"
  printf 'pub const D: &str = "HAVEN_NEEDLE_DIR";\n' \
    > "${dirleak}/haven/rust_builder/src/api.rs"
  _case "a needle-dir override in rust_builder fails" 1 check_no_production_reach "${dirleak}"

  echo "self-test: check 2 — not in a build path"
  _case "healthy manifests pass" 0 check_not_in_build_path "${ok}"
  local depended="${tmp}/depended"; _mk "${depended}"
  printf '[dependencies]\nhaven-local-relay = { path = "../tooling/e2e/local-relay" }\n' \
    >> "${depended}/haven-core/Cargo.toml"
  _case "haven-core path-depending on the crate fails" 1 check_not_in_build_path "${depended}"
  local publishable="${tmp}/publishable"; _mk "${publishable}"
  printf '[package]\nname = "haven-local-relay"\n' \
    > "${publishable}/${CRATE_DIR}/Cargo.toml"
  _case "publish = false removed fails" 1 check_not_in_build_path "${publishable}"

  # The scanner crate is held to the same two rules as the recorder.
  local scan_depended="${tmp}/scandepended"; _mk "${scan_depended}"
  printf '[package]\nname = "haven-core"\n[dependencies]\nhaven-logscan = { path = "../tooling/logscan" }\n' \
    > "${scan_depended}/haven-core/Cargo.toml"
  _case "haven-core path-depending on the scanner crate fails" 1 check_not_in_build_path "${scan_depended}"

  local scan_publishable="${tmp}/scanpublishable"; _mk "${scan_publishable}"
  printf '[package]\nname = "haven-logscan"\n' > "${scan_publishable}/${LOGSCAN_DIR}/Cargo.toml"
  _case "the scanner crate without publish = false fails" 1 check_not_in_build_path "${scan_publishable}"

  echo "self-test: check 3 — the raw journal is never an artifact"
  _case "healthy workflows pass" 0 check_raw_journal_not_uploaded "${ok}"
  # THE fixture this check exists for: a lane adds the journal to its artifact.
  local uploaded="${tmp}/uploaded"; _mk "${uploaded}"
  cat > "${uploaded}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - name: Upload failure artifacts
        uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/flutter-test.log
            /tmp/haven-wire-journal.ndjson
YAML
  _case "a lane uploading the raw journal fails" 1 check_raw_journal_not_uploaded "${uploaded}"

  local inline="${tmp}/inline"; _mk "${inline}"
  cat > "${inline}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/haven-wire-journal.ndjson
YAML
  _case "the single-line path form also fails" 1 check_raw_journal_not_uploaded "${inline}"

  # ...and the two ways this check could rot into a rubber stamp: a .ndjson
  # named OUTSIDE an upload step (starting the proxy needs to name the path),
  # and one named in a COMMENT (this very ban has to be documentable).
  local named="${tmp}/named"; _mk "${named}"
  cat > "${named}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - name: Start the recorder
        run: HAVEN_WIRE_JOURNAL=/tmp/haven-wire-journal.ndjson bash tooling/e2e/ci/start-wire-proxy.sh
      - name: Upload failure artifacts
        uses: actions/upload-artifact@v6
        with:
          # NEVER add the raw /tmp/haven-wire-journal.ndjson here.
          path: /tmp/wire-summary.log
YAML
  _case "naming the journal outside an upload step is allowed" 0 check_raw_journal_not_uploaded "${named}"

  local later="${tmp}/later"; _mk "${later}"
  cat > "${later}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/wire-summary.log
      - name: Archive locally
        run: cp /tmp/haven-wire-journal.ndjson /tmp/keep.ndjson
YAML
  _case "a later non-upload step is not attributed to the upload" 0 check_raw_journal_not_uploaded "${later}"

  # ---------------------------------------------------------------------------
  # ...and the same four directions for the MLS-GROUP-ID SIDECAR, which is the
  # reason check 3 grew a path-prefix ban. The file holds the REAL MLS group
  # ids: uploading it would publish precisely the values Security Rule 4 exists
  # to keep off the wire, and the oracle that reads it would then be proving a
  # property about a value anyone could fetch from the artifact.
  # ---------------------------------------------------------------------------
  local sidecar="${tmp}/sidecar"; _mk "${sidecar}"
  cat > "${sidecar}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - name: Upload failure artifacts
        uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/flutter-test.log
            /tmp/haven-wire-proxy.mlsgroupid
YAML
  _case "a lane uploading the mls-group-id sidecar fails" 1 check_raw_journal_not_uploaded "${sidecar}"

  local sidecar_inline="${tmp}/sidecarinline"; _mk "${sidecar_inline}"
  cat > "${sidecar_inline}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/haven-wire-proxy-planeA.mlsgroupid
YAML
  _case "the single-line sidecar path form also fails" 1 check_raw_journal_not_uploaded "${sidecar_inline}"

  # The two bypasses two independent review passes found. Both defeat a ban
  # keyed on LOCATION rather than on what the file is: the sidecar's path is
  # caller-controlled by HAVEN_WIRE_MLS_GROUP_ID_FILE (whole path) and
  # HAVEN_WIRE_PROXY_RUN_DIR (directory), both of which start-wire-proxy.sh
  # honours by design.
  local sidecar_dotlog="${tmp}/sidecardotlog"; _mk "${sidecar_dotlog}"
  cat > "${sidecar_dotlog}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: HAVEN_WIRE_MLS_GROUP_ID_FILE=/tmp/haven-wire-ids.mlsgroupid bash tooling/e2e/ci/start-wire-proxy.sh
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/haven-wire-ids.mlsgroupid
YAML
  _case "a sidecar renamed via HAVEN_WIRE_MLS_GROUP_ID_FILE still fails" 1 \
    check_raw_journal_not_uploaded "${sidecar_dotlog}"

  local sidecar_reloc="${tmp}/sidecarreloc"; _mk "${sidecar_reloc}"
  cat > "${sidecar_reloc}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: ${{ runner.temp }}/haven-wire-proxy.mlsgroupid
YAML
  _case "a sidecar RELOCATED out of /tmp still fails" 1 \
    check_raw_journal_not_uploaded "${sidecar_reloc}"

  local tmp_sweep="${tmp}/tmpsweep"; _mk "${tmp_sweep}"
  cat > "${tmp_sweep}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/*
YAML
  _case "a wholesale /tmp upload fails" 1 check_raw_journal_not_uploaded "${tmp_sweep}"

  # ...and the .log exemption must SURVIVE, or the guard reds the real repo:
  # e2e-android.yml uploads /tmp/haven-wire-proxy.log, whose every line is a
  # length, a count, a fixed label or an ErrorKind.
  local proxylog_ok="${tmp}/proxylogok"; _mk "${proxylog_ok}"
  cat > "${proxylog_ok}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/haven-wire-proxy.log
YAML
  _case "the proxy's own .log stays uploadable" 0 \
    check_raw_journal_not_uploaded "${proxylog_ok}"

  local sidecar_named="${tmp}/sidecarnamed"; _mk "${sidecar_named}"
  cat > "${sidecar_named}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - name: Read the ground truth
        run: |
          while read -r id; do args+=(--mls-group-id "${id}"); done \
            < /tmp/haven-wire-proxy.mlsgroupid
      - name: Upload failure artifacts
        uses: actions/upload-artifact@v6
        with:
          # NEVER add /tmp/haven-wire-proxy.mlsgroupid here.
          path: /tmp/wire-summary.log
YAML
  _case "naming the sidecar outside an upload step is allowed" 0 check_raw_journal_not_uploaded "${sidecar_named}"

  # The EXEMPTION, pinned: two lanes already upload the proxy's own log, which
  # Security Rule 6 keeps to lengths, counts and fixed labels. A prefix ban
  # without this hole would red the repository on day one — and a hole nobody
  # tests is a hole that quietly widens.
  local proxylog="${tmp}/proxylog"; _mk "${proxylog}"
  cat > "${proxylog}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/haven-wire-proxy.log
            /tmp/haven-wire-proxy-planeA.log
YAML
  _case "the proxy's own .log stays uploadable" 0 check_raw_journal_not_uploaded "${proxylog}"

  # The claim file is neither a .ndjson nor a .log, so the prefix ban is what
  # catches it — the point of a prefix ban being that it needs no new rule for
  # each new file the proxy learns to write.
  local claimup="${tmp}/claimup"; _mk "${claimup}"
  cat > "${claimup}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/haven-wire-proxy.journalpath
YAML
  _case "an unnamed future wire-proxy file is banned by default" 1 check_raw_journal_not_uploaded "${claimup}"

  # ---------------------------------------------------------------------------
  # ...and the NEEDLE files, which are the same hazard one step further: the MLS
  # sidecar holds one class of value, a `.needles.decl` holds every class a run
  # declared. Keyed on the EXTENSION from the start, so the two defeats above
  # (rename into an exempt suffix, relocate out of the prefix) are unavailable.
  # ---------------------------------------------------------------------------
  local sealed="${tmp}/sealed"; _mk "${sealed}"
  cat > "${sealed}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/flutter-test.log
            /tmp/haven-soak/needles/run-1.needles.json
YAML
  _case "a lane uploading the sealed needle manifest fails" 1 check_raw_journal_not_uploaded "${sealed}"

  local declup="${tmp}/declup"; _mk "${declup}"
  cat > "${declup}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: ${{ runner.temp }}/alice.needles.decl
YAML
  _case "a declaration sidecar RELOCATED out of /tmp still fails" 1 \
    check_raw_journal_not_uploaded "${declup}"

  local canup="${tmp}/canup"; _mk "${canup}"
  cat > "${canup}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/haven-soak/needles/alice.canaries.json
YAML
  _case "a lane uploading the canary manifest fails" 1 check_raw_journal_not_uploaded "${canup}"

  local dirup="${tmp}/dirup"; _mk "${dirup}"
  cat > "${dirup}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/haven-soak/needles/
YAML
  _case "a lane uploading the needle DIRECTORY fails" 1 check_raw_journal_not_uploaded "${dirup}"

  # Priced and banned before it exists: an attribution map is the join key
  # between the aliases in an uploaded report and the real ids in an artifact.
  local attrup="${tmp}/attrup"; _mk "${attrup}"
  cat > "${attrup}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/evidence/run-1.attribution.json
YAML
  _case "a lane uploading an attribution map fails" 1 check_raw_journal_not_uploaded "${attrup}"

  local soaksweep="${tmp}/soaksweep"; _mk "${soaksweep}"
  cat > "${soaksweep}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/haven-soak/*
YAML
  _case "a wholesale soak-directory upload fails" 1 check_raw_journal_not_uploaded "${soaksweep}"

  # ...and naming the sealed manifest in a RUN step is how the lane works.
  local sealok="${tmp}/sealok"; _mk "${sealok}"
  cat > "${sealok}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - name: Seal the needle manifest
        run: |
          haven-logscan seal --run-id "${GITHUB_RUN_ID}" \
            --decl /tmp/haven-soak/needles/default.needles.decl \
            --out /tmp/haven-soak/needles/run.needles.json
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/wire-summary.log
YAML
  _case "sealing a manifest in a run step is allowed" 0 check_raw_journal_not_uploaded "${sealok}"

  # A bare-wildcard entry is a sweep, whatever prefix it carries.
  local star2="${tmp}/star2"; _mk "${star2}"
  cat > "${star2}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/flutter-test.log
            /tmp/**
YAML
  _case "a /tmp/** upload fails" 1 check_raw_journal_not_uploaded "${star2}"

  local starprefix="${tmp}/starprefix"; _mk "${starprefix}"
  cat > "${starprefix}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: /tmp/haven*
YAML
  _case "a /tmp/haven* upload fails" 1 check_raw_journal_not_uploaded "${starprefix}"

  local stardir="${tmp}/stardir"; _mk "${stardir}"
  cat > "${stardir}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            - /tmp/logs/*
YAML
  _case "a /tmp/logs/* upload fails" 1 check_raw_journal_not_uploaded "${stardir}"

  # ...while a wildcard bounded by an extension is how a multi-relay lane
  # names its logs, and must stay legal.
  local starext="${tmp}/starext"; _mk "${starext}"
  cat > "${starext}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          path: |
            /tmp/strfry-profile-*.log
            /tmp/diag.log
YAML
  _case "an extension-bounded wildcard upload is allowed" 0 check_raw_journal_not_uploaded "${starext}"

  echo "self-test: check 6 — needle files are never read out (extends check 3)"
  _case "a healthy tree passes" 0 check_needle_files_are_not_exposed "${ok}"

  local catdecl="${tmp}/catdecl"; _mk "${catdecl}"
  cat > "${catdecl}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - name: Debug the declarations
        run: cat /tmp/haven-soak/needles/default.needles.decl
YAML
  _case "a workflow cat-ing a declaration sidecar fails" 1 \
    check_needle_files_are_not_exposed "${catdecl}"

  # `tee` writes AND copies to stdout, and a step's stdout is the job log, which
  # no later deletion can retract.
  local teedecl="${tmp}/teedecl"; _mk "${teedecl}"
  cat > "${teedecl}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: haven-logscan seal --decl x.needles.decl --out /tmp/haven-soak/needles/r.needles.json | tee /tmp/seal.log
YAML
  _case "a workflow tee-ing a needle path fails" 1 \
    check_needle_files_are_not_exposed "${teedecl}"

  local summary="${tmp}/summary"; _mk "${summary}"
  cat > "${summary}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: sed -n 1p /tmp/haven-soak/needles/alice.needles.decl >> "$GITHUB_STEP_SUMMARY"
YAML
  _case "a step-summary write of a needle file fails" 1 \
    check_needle_files_are_not_exposed "${summary}"

  local issue="${tmp}/issue"; _mk "${issue}"
  cat > "${issue}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: gh issue create --title soak --body-file /tmp/haven-soak/needles/run.needles.json
YAML
  _case "an issue body built from a needle file fails" 1 \
    check_needle_files_are_not_exposed "${issue}"

  # A RUNNER is scanned too: its stdout is the same job log.
  local runnercat="${tmp}/runnercat"; _mk "${runnercat}"
  printf '#!/usr/bin/env bash\nhead -n 3 "/tmp/haven-soak/needles/${ROLE}.needles.decl"\n' \
    > "${runnercat}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "a runner reading a declaration sidecar fails" 1 \
    check_needle_files_are_not_exposed "${runnercat}"

  # THE TWO SHAPES THAT MUST STAY LEGAL, or the lane cannot clean up after
  # itself and the ban is turned off within a week.
  local cleanup="${tmp}/cleanup"; _mk "${cleanup}"
  printf '#!/usr/bin/env bash\nrm -f /tmp/haven-soak/needles/*\nshred -u /tmp/haven-soak/needles/alice.canaries.json\n' \
    > "${cleanup}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "deleting the needle files is allowed" 0 check_needle_files_are_not_exposed "${cleanup}"

  local seal_runner="${tmp}/sealrunner"; _mk "${seal_runner}"
  printf '#!/usr/bin/env bash\nmkdir -m 0700 -p /tmp/haven-soak/needles\nhaven-logscan seal --decl /tmp/haven-soak/needles/a.needles.decl --out /tmp/haven-soak/needles/r.needles.json\n' \
    > "${seal_runner}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "sealing and mkdir in a runner are allowed" 0 \
    check_needle_files_are_not_exposed "${seal_runner}"

  # A read verb on a path that is NOT a needle file is ordinary lane work.
  local tailother="${tmp}/tailother"; _mk "${tailother}"
  printf '#!/usr/bin/env bash\ntail -n 50 /tmp/flutter-drive.log\ncat /tmp/haven-wire-proxy.log\n' \
    > "${tailother}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "reading a non-needle log is allowed" 0 check_needle_files_are_not_exposed "${tailother}"

  # The wider read-verb list: a structured reader is a reader.
  local jqread="${tmp}/jqread"; _mk "${jqread}"
  cat > "${jqread}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: jq -r .value /tmp/haven-soak/needles/run.needles.json
YAML
  _case "a workflow jq-ing the sealed manifest fails" 1 check_needle_files_are_not_exposed "${jqread}"

  local awkread="${tmp}/awkread"; _mk "${awkread}"
  printf '#!/usr/bin/env bash\nawk -F, "{print \\$1}" /tmp/haven-soak/needles/alice.canaries.json\n' \
    > "${awkread}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "a runner awk-ing the canary manifest fails" 1 check_needle_files_are_not_exposed "${awkread}"

  # A redirection reads without naming any command.
  local redirloop="${tmp}/redirloop"; _mk "${redirloop}"
  printf '#!/usr/bin/env bash\nwhile IFS= read -r l; do echo "${l}"; done < /tmp/haven-soak/needles/default.needles.decl\n' \
    > "${redirloop}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "a runner looping over a sidecar through < fails" 1 check_needle_files_are_not_exposed "${redirloop}"

  local substread="${tmp}/substread"; _mk "${substread}"
  cat > "${substread}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: echo "$(< "/tmp/haven-soak/needles/run.needles.json")"
YAML
  _case "a workflow reading a manifest through \$(< …) fails" 1 check_needle_files_are_not_exposed "${substread}"

  # The two shapes the redirection rule must leave alone: an APPEND write to a
  # sidecar (`>`, not `<`), and a `<path>` usage placeholder in an echo.
  local appendwrite="${tmp}/appendwrite"; _mk "${appendwrite}"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> /tmp/haven-soak/needles/default.needles.decl\necho "usage: scan --manifest <path>.needles.json"\n' \
    > "${appendwrite}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "an append write and a <path> placeholder are allowed" 0 check_needle_files_are_not_exposed "${appendwrite}"

  # grep is deliberately outside the list: the runners' self-tests grep their
  # own source for the lines that name the directory.
  local grepdir="${tmp}/grepdir"; _mk "${grepdir}"
  printf '#!/usr/bin/env bash\ngrep -n "^log_privacy_gate /tmp/haven-soak/needles " "${BASH_SOURCE[0]}"\n' \
    > "${grepdir}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "a grep naming the directory is not a read-out" 0 check_needle_files_are_not_exposed "${grepdir}"

  # ...and a COMMENT documenting the ban must stay writable.
  local commented_ban="${tmp}/commentedban"; _mk "${commented_ban}"
  printf '#!/usr/bin/env bash\n# never cat /tmp/haven-soak/needles/*.needles.decl or pass --disclose-values\ntrue\n' \
    > "${commented_ban}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "documenting the ban is allowed" 0 check_needle_files_are_not_exposed "${commented_ban}"

  local disclose="${tmp}/disclose"; _mk "${disclose}"
  cat > "${disclose}/.github/workflows/e2e.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: haven-logscan scan --manifest m.needles.json --disclose-values
YAML
  _case "--disclose-values in a workflow fails" 1 check_needle_files_are_not_exposed "${disclose}"

  local disclose_runner="${tmp}/discloserunner"; _mk "${disclose_runner}"
  printf '#!/usr/bin/env bash\nhaven-logscan scan --manifest "${M}" --disclose-values\n' \
    > "${disclose_runner}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "--disclose-values in a runner fails" 1 \
    check_needle_files_are_not_exposed "${disclose_runner}"

  # The relocation defeat, refused at the source: no env var may name the
  # directory the bans above are keyed on.
  local dirvar_crate="${tmp}/dirvarcrate"; _mk "${dirvar_crate}"
  printf 'let dir = std::env::var("HAVEN_NEEDLE_DIR").unwrap_or_default();\n' \
    > "${dirvar_crate}/${CRATE_DIR}/src/needles.rs"
  _case "a needle-dir env override in the crate fails" 1 \
    check_needle_files_are_not_exposed "${dirvar_crate}"

  local dirvar_runner="${tmp}/dirvarrunner"; _mk "${dirvar_runner}"
  printf '#!/usr/bin/env bash\nHAVEN_NEEDLE_DIR="${RUNNER_TEMP}" bash start-wire-proxy.sh\n' \
    > "${dirvar_runner}/${E2E_CI_DIR}/run-single-avd-scenario.sh"
  _case "a needle-dir env override in a runner fails" 1 \
    check_needle_files_are_not_exposed "${dirvar_runner}"

  # The vacuity route: a tree with nothing to scan must FAIL rather than pass
  # for want of anything to look at.
  local nofiles="${tmp}/nofiles"; _mk "${nofiles}"
  rm -f "${nofiles}"/.github/workflows/*.yml "${nofiles}/${E2E_CI_DIR}"/*.sh
  _case "a tree with no workflow or runner fails" 1 \
    check_needle_files_are_not_exposed "${nofiles}"

  echo "self-test: check 7 — no e2e lane chooses the scanner binary"
  _case "a lane that builds and runs the scanner passes" 0 check_logscan_binary_not_overridden "${ok}"

  local binenv="${tmp}/binenv"; _mk "${binenv}"
  cat > "${binenv}/.github/workflows/e2e-lane.yml" <<'YAML'
jobs:
  lane:
    env:
      HAVEN_LOGSCAN_BIN: /usr/bin/true
    steps:
      - run: bash tooling/e2e/ci/scan-logs.sh --manifest m.needles.json --sink diag=/tmp/diag.log
YAML
  _case "an env: HAVEN_LOGSCAN_BIN in an e2e lane fails" 1 check_logscan_binary_not_overridden "${binenv}"

  local binexport="${tmp}/binexport"; _mk "${binexport}"
  cat > "${binexport}/.github/workflows/e2e-lane.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: |
          export HAVEN_LOGSCAN_BIN="${RUNNER_TEMP}/stub"
          bash tooling/e2e/ci/scan-logs.sh --manifest m.needles.json --sink diag=/tmp/diag.log
YAML
  _case "an exported HAVEN_LOGSCAN_BIN in an e2e lane fails" 1 check_logscan_binary_not_overridden "${binexport}"

  local bininline="${tmp}/bininline"; _mk "${bininline}"
  cat > "${bininline}/.github/workflows/e2e-lane.yml" <<'YAML'
jobs:
  lane:
    steps:
      - run: HAVEN_LOGSCAN_BIN=/bin/true bash tooling/e2e/ci/run-single-avd-scenario.sh x.dart
YAML
  _case "an inline HAVEN_LOGSCAN_BIN=… prefix in an e2e lane fails" 1 check_logscan_binary_not_overridden "${bininline}"

  # The legitimate setter is not an e2e lane, and documenting the ban is not
  # setting it.
  local binrustcheck="${tmp}/binrustcheck"; _mk "${binrustcheck}"
  cat > "${binrustcheck}/.github/workflows/rust-check.yml" <<'YAML'
jobs:
  logscan-tooling:
    steps:
      - run: |
          export HAVEN_LOGSCAN_BIN="${PWD}/target/release/haven-logscan"
          bash ../e2e/ci/scan-logs.sh --manifest m.needles.json --sink drive=clean.log
YAML
  _case "rust-check.yml pointing at the binary it built is allowed" 0 check_logscan_binary_not_overridden "${binrustcheck}"

  local nolanes="${tmp}/nolanes"; _mk "${nolanes}"
  rm -f "${nolanes}/.github/workflows/e2e-lane.yml"
  _case "a tree with no e2e lane fails rather than passing vacuously" 1 check_logscan_binary_not_overridden "${nolanes}"

  echo "self-test: check 4 — the summary stays scanned"
  _case "healthy summary script passes" 0 check_summary_is_scanned "${ok}"
  local unscanned="${tmp}/unscanned"; _mk "${unscanned}"
  printf '#!/usr/bin/env bash\n"${BIN}" --summarize "${JOURNAL}" --out "${OUT}"\n' \
    > "${unscanned}/${SUMMARIZE_SH}"
  _case "summary that skips the secret scan fails" 1 check_summary_is_scanned "${unscanned}"
  local doconly="${tmp}/doconly"; _mk "${doconly}"
  printf '#!/usr/bin/env bash\n# we used to call scan-logs-for-secrets.sh here\ntrue\n' \
    > "${doconly}/${SUMMARIZE_SH}"
  _case "a comment mentioning the scanner does not count" 1 check_summary_is_scanned "${doconly}"
  # The call FIRST in a script far past a pipe's 64 KiB: a reader that stops at
  # it must not let the rest of the file turn it into a miss.
  local bigsum="${tmp}/bigsum"; _mk "${bigsum}"
  { printf '#!/usr/bin/env bash\nbash tooling/e2e/ci/scan-logs-for-secrets.sh "${OUT}"\n'
    awk 'BEGIN { for (i = 0; i < 40000; i++) printf "printf \"%%s\\n\" filler-%05d\n", i }'
  } > "${bigsum}/${SUMMARIZE_SH}"
  _case "a scanner call ahead of a 1 MiB script still counts" 0 check_summary_is_scanned "${bigsum}"

  echo "self-test: check 5 — recording cannot break traffic"
  _case "healthy recorder passes" 0 check_recorder_cannot_break_traffic "${ok}"

  # The regression that matters most: making the recorder fallible. It compiles,
  # it reads like good Rust, and it hands every call site a failure it can
  # propagate into the connection pump.
  local fallible="${tmp}/fallible"; _mk "${fallible}"
  cat > "${fallible}/${JOURNAL_RS}" <<'RS'
impl WireJournal {
    pub fn record(
        &self,
        conn_id: &str,
    ) -> Result<u64, std::io::Error> {
        self.emit()
    }
}
#[cfg(test)]
mod tests {}
RS
  _case "a recorder returning Result fails" 1 check_recorder_cannot_break_traffic "${fallible}"

  local panicky="${tmp}/panicky"; _mk "${panicky}"
  cat > "${panicky}/${JOURNAL_RS}" <<'RS'
impl WireJournal {
    pub fn record(&self, conn_id: &str) -> u64 {
        let mut inner = self.inner.lock().unwrap();
        inner.next_seq
    }
}
#[cfg(test)]
mod tests {}
RS
  _case "an unwrap in the recorder fails" 1 check_recorder_cannot_break_traffic "${panicky}"

  # A doc comment mentioning unwrap()/panic! must not count as code, or the
  # module could never explain why it avoids them.
  local documented="${tmp}/documented"; _mk "${documented}"
  cat > "${documented}/${JOURNAL_RS}" <<'RS'
//! Never call unwrap() or expect() here; a panic! would kill the pump.
impl WireJournal {
    /// Returns the wire_seq. Does not unwrap().
    pub fn record(&self, conn_id: &str) -> u64 {
        0
    }
}
#[cfg(test)]
mod tests {}
RS
  _case "doc comments naming unwrap are allowed" 0 check_recorder_cannot_break_traffic "${documented}"

  # A tests module may panic freely; only the production half is scanned.
  _case "test-module panics are allowed" 0 check_recorder_cannot_break_traffic "${ok}"

  # The vacuity route: a rename that leaves the extractor matching nothing must
  # FAIL, not pass for want of anything to check.
  local renamed="${tmp}/renamed"; _mk "${renamed}"
  cat > "${renamed}/${JOURNAL_RS}" <<'RS'
impl WireJournal {
    pub fn write_line(&self, conn_id: &str) -> Result<u64, ()> {
        Ok(0)
    }
}
#[cfg(test)]
mod tests {}
RS
  _case "a rename that empties the extractor fails" 1 check_recorder_cannot_break_traffic "${renamed}"

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

  for required in "${CRATE_DIR}" '.github/workflows'; do
    [[ -e "${REPO_ROOT}/${required}" ]] || {
      echo "ERROR: ${required} not found under ${REPO_ROOT}" >&2
      exit 2
    }
  done

  run_all "${REPO_ROOT}"

  if (( FAILED )); then
    echo >&2
    echo "The recording wire proxy is a test instrument that captures a complete" >&2
    echo "transcript of relay traffic, plus a sidecar holding the REAL MLS group" >&2
    echo "ids. It must stay out of the shipped app, out of every build path, and" >&2
    echo "out of CI artifacts. See the header of this script and" >&2
    echo "docs/WIRE_JOURNAL.md." >&2
    exit 1
  fi
  echo "wire-proxy test-only guard: OK (no production reach, no build-path dependency for either tooling crate, neither the raw journal nor the mls-group-id sidecar uploaded and no bare-wildcard upload, summary scanned, recorder cannot break traffic, no needle sidecar read out or relocatable, no e2e lane chooses the scanner binary)."
}

main "$@"
