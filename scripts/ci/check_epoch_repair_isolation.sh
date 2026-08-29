#!/usr/bin/env bash
# CI guard: the epoch-rotation repair is reachable from ONE narrow slice of the
# app, and nothing schedules it (Rule 14 / `docs/EPOCH_ROTATION_REPAIR_PLAN.md`
# §4 gate 5).
#
# ## Why an isolate boundary is a security boundary here
#
# The repair authors an MLS commit. Rule 14 allows exactly ONE live
# `AccountDeviceSession` per MLS database across every isolate and process: a
# second one diverges in-memory epoch state and risks epoch/exporter-key reuse —
# a confidentiality loss, not merely DB corruption. The Android foreground
# service and the WorkManager catch-up worker each run in their OWN Dart isolate
# and reach the core through a session they may have RECLAIMED from a main
# isolate that is still alive. A commit authored from there can be staged
# against state the foreground isolate is concurrently mutating, and
# `EpochManager::committed_from` is in-memory, so the resulting same-epoch
# sibling cannot be reconciled after a restart (M11 §H2).
#
# The repair is also a USER ACTION with a visible outcome. A background isolate
# has nobody to show a skip reason to and nobody to decide whether a circle
# should be repaired at all.
#
# ## Why this is an ALLOWLIST, not a denylist
#
# The first version of this guard named the three background entrypoints and
# refused the repair in them. That was wrong twice over. It named a file that
# does not exist (`ios_catchup_handler.dart`; the real one is
# `ios_background_catchup.dart`) and skipped it silently, so the iOS path was
# never actually checked. And a denylist cannot see a NEW background
# entrypoint — the next one added would be unguarded by construction.
#
# An allowlist inverts both failures: every file that may name the repair is
# listed here, so a new caller anywhere — background isolate, widget, provider,
# or a file that does not exist yet — fails until someone justifies it.
#
# ## What this guard does NOT check, and why
#
# It does not look for schedulers. `INV-E-NO-PERIODIC-REKEY` promises Haven
# never re-keys on a timer, and that promise is enforced — but not here. A
# scheduler callback spanning several lines defeats any line-scoped grep (that
# is exactly how the previous version of this file was bypassed), and a
# file-scoped grep is worse than useless: two of the four allowlisted files hold
# legitimate, unrelated `Timer.periodic`s (the health model's re-derivation
# tick, the banner's age re-render), so a file-scoped check would either fire on
# them forever or force unrelated timers out of the files they belong in.
#
# The scheduler question needs the call graph, so it is answered at AST level by
# `haven/test/lints/self_update_disabled_test.dart`, which fails any invocation
# of these identifiers whose ENCLOSING function is a scheduler callback. This
# guard owns the reachability question; that lint owns the periodicity question.
#
# Checks:
#   1. Every allowlisted path exists (a typo must not silently disable a check).
#   2. `repairEpochRotation` / `repairCircleEpoch` appear ONLY in allowlisted
#      files, anywhere under `haven/lib`.
#
# Exit codes:
#   0  all checks pass
#   1  the repair escaped the allowlist
#   2  expected paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# The ONLY files permitted to name the repair. `lib/src/rust/` is the generated
# FRB binding surface and is matched by prefix.
readonly -a ALLOWED_FILES=(
  "haven/lib/src/services/circle_service.dart"
  "haven/lib/src/services/nostr_circle_service.dart"
  "haven/lib/src/providers/sharing_health_provider.dart"
  "haven/lib/src/widgets/map/sharing_health_banner.dart"
)
readonly ALLOWED_PREFIX="haven/lib/src/rust/"

# Every name that REACHES the repair, not only the two at the FFI boundary.
#
# The first version listed the boundary calls alone, and a probe outside the
# allowlist doing `ref.read(sharingRepairProvider)()` passed it: the wrappers
# are the reachable surface, so naming only what they wrap guards nothing.
readonly -a REPAIR_TOKENS=(
  'repairEpochRotation'
  'repairCircleEpoch'
  'repairSelectedCircleEpoch'
  'sharingRepairProvider'
)

log() {
  printf '\033[1;34m[check_epoch_repair_isolation]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_epoch_repair_isolation] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# --self-test: every check must FIRE on a planted violation, and the allowlist
# must be shown to be real (its paths exist in the actual tree).
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  log "Self-test: allowlist is real, and each check goes red on a violation ..."

  # The allowlist must describe THIS repository, not a remembered one. This is
  # the check whose absence let a misspelled path disable a whole arm.
  for rel in "${ALLOWED_FILES[@]}"; do
    [[ -f "${REPO_ROOT}/${rel}" ]] \
      || fail "self-test: allowlisted path does not exist: ${rel}"
  done
  [[ -d "${REPO_ROOT}/${ALLOWED_PREFIX}" ]] \
    || fail "self-test: allowlisted prefix does not exist: ${ALLOWED_PREFIX}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  mkdir -p "${tmp}/haven/lib/src/services" \
           "${tmp}/haven/lib/src/providers" \
           "${tmp}/haven/lib/src/widgets/map" \
           "${tmp}/haven/lib/src/rust"
  for rel in "${ALLOWED_FILES[@]}"; do
    printf '// allowlisted, empty\n' > "${tmp}/${rel}"
  done

  # Check 2: a caller outside the allowlist — the shape a denylist misses.
  printf 'void x() { manager.repairEpochRotation(); }\n' \
    > "${tmp}/haven/lib/src/services/background_location_task.dart"
  if REPO_ROOT_OVERRIDE="${tmp}" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
    fail "self-test: check 2 did NOT fire on a caller outside the allowlist"
  fi
  rm -f "${tmp}/haven/lib/src/services/background_location_task.dart"

  # The same shape through the Dart WRAPPERS, which is how the first version of
  # this guard was escaped: neither name is the FFI call, and both reach it.
  for probe in \
    'void x(WidgetRef ref) { ref.read(sharingRepairProvider)(); }' \
    'void x(Ref ref) { repairSelectedCircleEpoch(ref); }'
  do
    printf '%s\n' "${probe}" \
      > "${tmp}/haven/lib/src/services/background_location_task.dart"
    if REPO_ROOT_OVERRIDE="${tmp}" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
      fail "self-test: check 2 did NOT fire on a wrapper call: ${probe}"
    fi
  done
  rm -f "${tmp}/haven/lib/src/services/background_location_task.dart"

  # A generated-binding path must stay allowed by PREFIX, not by listing.
  printf 'void x() { repairEpochRotation(); }\n' \
    > "${tmp}/haven/lib/src/rust/api.dart"
  REPO_ROOT_OVERRIDE="${tmp}" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 \
    || fail "self-test: the generated FRB prefix must stay allowed"

  # Check 1: a listed path that does not exist must be a misconfiguration, not
  # a silently skipped arm.
  rm -f "${tmp}/haven/lib/src/services/circle_service.dart"
  set +e
  REPO_ROOT_OVERRIDE="${tmp}" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
  rc=$?
  set -e
  [[ ${rc} -eq 2 ]] \
    || fail "self-test: a missing allowlisted path must exit 2, got ${rc}"

  log "OK: self-test passed — the allowlist is real and both checks fire."
  exit 0
fi

LIB_DIR="${REPO_ROOT}/haven/lib"
[[ -d "${LIB_DIR}" ]] || { echo "ERROR: ${LIB_DIR} not found" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Check 1: the allowlist describes files that exist.
# ---------------------------------------------------------------------------
for rel in "${ALLOWED_FILES[@]}"; do
  if [[ ! -f "${REPO_ROOT}/${rel}" ]]; then
    echo "ERROR: allowlisted path missing: ${rel} — a renamed or misspelled entry silently disables this guard" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Check 2: the repair is named ONLY in allowlisted files.
# ---------------------------------------------------------------------------
log "Checking the epoch-rotation repair stays inside its allowlist ..."
is_allowed() {
  local rel="$1"
  [[ "${rel}" == "${ALLOWED_PREFIX}"* ]] && return 0
  local allowed
  for allowed in "${ALLOWED_FILES[@]}"; do
    [[ "${rel}" == "${allowed}" ]] && return 0
  done
  return 1
}

for token in "${REPAIR_TOKENS[@]}"; do
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    file="${hit%%:*}"
    rel="${file#"${REPO_ROOT}/"}"
    if ! is_allowed "${rel}"; then
      printf '%s\n' "${hit}" >&2
      fail "'${token}' is named in ${rel}, which is NOT on the allowlist. The repair authors an MLS commit and must stay on the foreground service layer (Rule 14 / plan §4 gate 5). Add the file to ALLOWED_FILES only with a reason."
    fi
  done < <(grep -rnF "${token}" "${LIB_DIR}" 2>/dev/null || true)
done

log "OK: the epoch-rotation repair stays inside its allowlist."
