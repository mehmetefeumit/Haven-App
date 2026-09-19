#!/usr/bin/env bash
#
# CI guard: the soak rig's two clocks stay partitioned.
#
# ## Why a guard and not just a type
#
# The rig moves a clock forward on purpose. That is the only way a run bounded
# by five minutes can reach a 288-second sweep horizon, a key-package rotation
# window or a gift-wrap prune. haven-core takes an injected instant at two
# KINDS of seam, and only one of them may see that offset:
#
#   POLICY seams decide whether something has aged out — `sweep_unresolvable_
#   inputs`, `decide_kp_maintenance`, `repair_epoch_rotation`,
#   `rotation_decision`, `prune_expired_last_known`,
#   `prune_processed_gift_wraps`, `complete_leave`. Stepping this clock is the
#   whole mechanism.
#
#   WALL seams decide where a relay cursor sits and when a delivery or
#   subscription window opened — `cap_timestamp_to_now`, `cursor_ms_for_event`,
#   `cursor_ms_for_window`, `since_for_stream`, `note_subscription_opened`,
#   `note_inbox_subscription_opened`, `note_dropped_before_ingest`,
#   `open_delivery_window`. Every one of these is compared against a timestamp
#   a RELAY or a PEER produced. An offset instant here does not accelerate
#   anything: it fabricates a fork, a replay or a silently-dropped event out of
#   nothing, and the rig then grades the subject on a defect the rig invented.
#   That failure is indistinguishable from a real one in the timeline, which is
#   what makes it worth a guard of its own.
#
# `tooling/soak/src/clock.rs` encodes the partition in the type system: two
# newtypes, one one-way constructor (`PolicyNow::from_wall_with_offset`), and
# no `From`, no `Into`, no `to_wall()`. The type system is the first half. This
# grep is the second, and it exists because the type system cannot see the one
# move that defeats it — a conversion added later, or a raw `i64` taken out of
# one clock and handed to the other seam.
#
# ## What is checked
#
#   C1  NO CONVERSION. No `impl From<PolicyNow>`, no `impl From<WallNow>`, no
#       `impl Into<…>` between them, and none of the converting spellings
#       (`to_wall`, `as_wall`, `into_wall`, `to_policy`, `as_policy`,
#       `into_policy`) anywhere under `tooling/soak/src`. A `From` impl is the
#       worst shape of all, because it converts INVISIBLY at the call site.
#
#   C2  NO POLICY INSTANT AT A WALL SEAM. No call to a WALL seam passes a
#       policy-shaped argument (`PolicyNow`, a `policy_now`/`policy_secs`
#       binding, `policy_offset`).
#
#   C3  NO WALL INSTANT AT A POLICY SEAM. The mirror: no call to a POLICY seam
#       passes `WallNow`/`wall_now`/`wall_secs`. This half matters less for
#       privacy and more for vacuity — a policy seam fed the un-offset clock
#       silently never reaches its horizon, and the scenario passes having
#       tested nothing.
#
#   C4  THE VOCABULARY IS STILL REAL. Every seam name above is DERIVED against
#       haven-core: each must still be declared there as a `fn`. A guard whose
#       forbidden-call list has been renamed out from under it reports every
#       call site as compliant, which is the failure mode every grep-guard dies
#       of. This is the floor, and it is read from the repository rather than
#       hardcoded as a count.
#
# ## What this cannot see, stated plainly
#
# A policy instant unwrapped into a bare `i64` on one line and passed to a wall
# seam on another. The partition's real enforcement is the newtype pair; this
# guard catches the shapes that would dissolve it, not every path through a
# raw integer. `tooling/soak/tests/` is deliberately out of scope for C2/C3:
# a test may legitimately construct either clock to prove the partition itself.
#
# ## Absent crate
#
# While `tooling/soak/src` is not in the tree, C1–C3 print that they are inert
# and return 0. C4 runs regardless — it is about haven-core, not about the rig,
# and it is exactly the check that must not wait for the crate.
#
# Pure grep/awk, no toolchain — belongs in repo-guards.yml.
#
# Usage:
#   bash scripts/ci/check_soak_clock_partition.sh
#   bash scripts/ci/check_soak_clock_partition.sh --self-test
#
# Exit codes:
#   0  the partition holds
#   1  a violation
#   2  the guard cannot see what it checks (renamed seam, missing clock module,
#      self-test failure)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SELF_NAME='check_soak_clock_partition'

readonly SOAK_SRC='tooling/soak/src'
readonly CLOCK_RS='tooling/soak/src/clock.rs'
readonly CORE_SRC='haven-core/src'
# Equality pin: a fixture added or removed without moving this line is a
# self-test that no longer says what it runs.
readonly SELF_TEST_FIXTURES=20

# Seams that may only ever see the real clock (relay/cursor.rs and the
# live-sync processor's window/anchor entry points).
readonly WALL_SEAMS=(
  'cap_timestamp_to_now'
  'cursor_ms_for_event'
  'cursor_ms_for_window'
  'since_for_stream'
  'note_subscription_opened'
  'note_inbox_subscription_opened'
  'note_dropped_before_ingest'
  'open_delivery_window'
)
# Seams that decide whether something has aged out: the offset clock's whole
# purpose.
readonly POLICY_SEAMS=(
  'sweep_unresolvable_inputs'
  'decide_kp_maintenance'
  'repair_epoch_rotation'
  'rotation_decision'
  'prune_expired_last_known'
  'prune_processed_gift_wraps'
  'complete_leave'
)

# Written as bracket expressions, not backslash escapes: these go to awk
# through `-v`, which eats a backslash before the regex engine sees it.
readonly POLICY_ARG_RE='PolicyNow|policy_now|policy_secs|policy_offset|policy_instant'
readonly WALL_ARG_RE='WallNow|wall_now|wall_secs|wall_instant'
readonly CONVERSION_RE='impl[[:space:]]+From<(PolicyNow|WallNow)>|impl[[:space:]]+Into<(PolicyNow|WallNow)>|into_wall|to_wall|as_wall|into_policy|to_policy|as_policy'

FAILED=0
BROKEN=0
fail()   { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
broken() { printf 'BROKEN: %s\n' "$*" >&2; BROKEN=1; }
log()    { printf '[%s] %s\n' "${SELF_NAME}" "$*"; }

soak_sources() { # soak_sources <root>
  [[ -d "$1/${SOAK_SRC}" ]] || return 0
  find "$1/${SOAK_SRC}" -name '*.rs' | sort
}

# C1 — no conversion between the clocks. Comment text is stripped first, so the
# module can explain the ban (clock.rs's own doc comment names every spelling).
check_no_conversion() {
  local root="$1" rc=0 f hits n=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    n=$(( n + 1 ))
    hits="$(awk -v re="${CONVERSION_RE}" '
      {
        line = $0
        sub(/^[[:space:]]*\/\/.*$/, "", line)
        sub(/[[:space:]]\/\/.*$/, "", line)
        if (line ~ re) print FILENAME ":" NR
      }' "${f}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "${f#"${root}/"} converts between the rig's two clocks. PolicyNow::from_wall_with_offset is the ONE direction, and it is a named constructor on purpose: a From impl converts invisibly at the call site, which is where the offset would reach a cursor comparison."
      rc=1
    fi
  done < <(soak_sources "${root}")
  if (( n == 0 )); then
    log "C1 is inert: ${SOAK_SRC} is not in the tree yet."
    return 0
  fi
  # The module the type system half lives in must still declare both clocks, or
  # C1 is guarding a partition that no longer exists.
  local clock="${root}/${CLOCK_RS}"
  if [[ ! -f "${clock}" ]]; then
    broken "${CLOCK_RS} not found, yet ${SOAK_SRC} has ${n} source file(s). The clock partition is a property of that module; without it this guard is checking a rule nothing states."
    return 2
  fi
  local t
  for t in 'struct WallNow' 'struct PolicyNow'; do
    grep -qF -- "${t}" "${clock}" || {
      broken "${CLOCK_RS} no longer declares \`${t}\`. The two newtypes ARE the partition; a rename means every pattern here is matching nothing."
      return 2
    }
  done
  return "${rc}"
}

# Prints `<file>:<line>:<seam>` for every call to one of <seams> whose argument
# region names something matching <re>. One physical line, because a seam call
# in this rig is one line; a call split across lines is a known gap and is
# stated in the header's "what this cannot see".
seam_arg_hits() { # seam_arg_hits <file> <re> <seam>...
  local f="$1" re="$2"; shift 2
  local seams="$*"
  awk -v re="${re}" -v seams="${seams}" '
    BEGIN { n = split(seams, s, " ") }
    {
      line = $0
      sub(/^[[:space:]]*\/\/.*$/, "", line)
      sub(/[[:space:]]\/\/.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      for (i = 1; i <= n; i++) {
        p = index(line, s[i] "(")
        if (p == 0) continue
        args = substr(line, p + length(s[i]))
        if (args ~ re) { print FILENAME ":" NR ":" s[i]; break }
      }
    }' "${f}"
}

# C2/C3 — the partition at the call site.
check_seam_partition() {
  local root="$1" rc=0 f hits n=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    n=$(( n + 1 ))
    hits="$(seam_arg_hits "${f}" "${POLICY_ARG_RE}" "${WALL_SEAMS[@]}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "${f#"${root}/"} hands a POLICY instant to a cursor, anchor or processor-window seam. Those are compared against timestamps a relay and a peer produced: an offset there fabricates a fork, a replay or a dropped event, and the rig then grades the subject on a defect the rig invented."
      rc=1
    fi
    hits="$(seam_arg_hits "${f}" "${WALL_ARG_RE}" "${POLICY_SEAMS[@]}")"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" >&2
      fail "${f#"${root}/"} hands a WALL instant to a policy seam. The offset clock is the only way a five-minute run reaches an age-out horizon; the un-offset one silently never does, and the scenario passes having tested nothing."
      rc=1
    fi
  done < <(soak_sources "${root}")
  if (( n == 0 )); then
    log "C2/C3 are inert: ${SOAK_SRC} is not in the tree yet."
    return 0
  fi
  log "C2/C3: ${n} rig source file(s) read against $(( ${#WALL_SEAMS[@]} + ${#POLICY_SEAMS[@]} )) seam names."
  return "${rc}"
}

# C4 — the forbidden-call vocabulary is still real. Derived from haven-core, so
# the expectation moves with the repository instead of being a number here.
check_seam_names_still_exist() {
  local root="$1" core="${root}/${CORE_SRC}" seam missing=""
  if [[ ! -d "${core}" ]]; then
    broken "${CORE_SRC} not found — the vocabulary below is derived from it, so nothing here can be vouched for."
    return 2
  fi
  for seam in "${WALL_SEAMS[@]}" "${POLICY_SEAMS[@]}"; do
    grep -rqE "fn[[:space:]]+${seam}\b" "${core}" || missing="${missing} ${seam}"
  done
  if [[ -n "${missing}" ]]; then
    broken "these seam names are no longer declared in ${CORE_SRC}:${missing}. Either a seam was renamed — re-pin it here in the same change — or this guard is now forbidding calls to functions nothing has, which reports every call site as compliant."
    return 2
  fi
  log "C4: all $(( ${#WALL_SEAMS[@]} + ${#POLICY_SEAMS[@]} )) seam names are still declared in ${CORE_SRC}."
  return 0
}

run_all() {
  local root="$1"
  check_seam_names_still_exist "${root}" || true
  check_no_conversion "${root}" || true
  check_seam_partition "${root}" || true
}

# ---------------------------------------------------------------------------
# Self-test. Hermetic fixtures, both directions per rule, plus every route by
# which the guard could go blind.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <fn> <root>
    local label="$1" want="$2" fn="$3" root="$4" got=0
    checked=$(( checked + 1 ))
    ( FAILED=0; BROKEN=0
      "${fn}" "${root}" >/dev/null 2>&1
      rc=$?
      if (( BROKEN )); then exit 2; fi
      if (( FAILED )); then exit 1; fi
      exit "${rc}"
    ) || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _mk() { # _mk <root>
    local r="$1"
    mkdir -p "${r}/${SOAK_SRC}/rig" "${r}/${CORE_SRC}/relay"
    cat > "${r}/${CLOCK_RS}" <<'RS'
//! No From, no into_wall(), no to_policy() — the partition is the point.
pub struct WallNow(i64);
pub struct PolicyNow(u64);
impl PolicyNow {
    pub fn from_wall_with_offset(wall: WallNow, offset_secs: i64) -> Self { todo!() }
}
RS
    cat > "${r}/${SOAK_SRC}/rig/mod.rs" <<'RS'
fn tick(wall: WallNow, policy: PolicyNow) {
    let since = since_for_stream("group", 0, phase, wall.secs());
    processor.note_subscription_opened(hex, wall.secs());
    manager.sweep_unresolvable_inputs(policy.secs());
    circle.prune_expired_last_known(policy.secs());
}
RS
    # The haven-core half C4 derives its vocabulary from.
    {
      local s
      for s in "${WALL_SEAMS[@]}" "${POLICY_SEAMS[@]}"; do
        printf 'pub fn %s() {}\n' "${s}"
      done
    } > "${r}/${CORE_SRC}/relay/seams.rs"
  }

  echo "[${SELF_NAME}] self-test"

  local ok="${tmp}/ok"; _mk "${ok}"
  _case "a correct rig passes C1" 0 check_no_conversion "${ok}"
  _case "a correct rig passes C2/C3" 0 check_seam_partition "${ok}"
  _case "a complete vocabulary passes C4" 0 check_seam_names_still_exist "${ok}"

  # --- C1, every converting shape.
  local from1="${tmp}/from1"; _mk "${from1}"
  printf 'impl From<PolicyNow> for WallNow { fn from(p: PolicyNow) -> Self { todo!() } }\n' \
    >> "${from1}/${CLOCK_RS}"
  _case "an impl From<PolicyNow> fails" 1 check_no_conversion "${from1}"

  local from2="${tmp}/from2"; _mk "${from2}"
  printf 'impl From<WallNow> for PolicyNow { fn from(w: WallNow) -> Self { todo!() } }\n' \
    >> "${from2}/${CLOCK_RS}"
  _case "the reverse impl From<WallNow> fails too" 1 check_no_conversion "${from2}"

  local named="${tmp}/named"; _mk "${named}"
  printf 'impl PolicyNow { pub fn into_wall(self) -> WallNow { todo!() } }\n' \
    >> "${named}/${CLOCK_RS}"
  _case "a named into_wall() conversion fails" 1 check_no_conversion "${named}"

  local elsewhere="${tmp}/elsewhere"; _mk "${elsewhere}"
  printf 'fn f(p: PolicyNow) -> WallNow { p.to_wall() }\n' >> "${elsewhere}/${SOAK_SRC}/rig/mod.rs"
  _case "a conversion outside clock.rs fails too" 1 check_no_conversion "${elsewhere}"

  local doc="${tmp}/doc"; _mk "${doc}"
  printf '// never add into_wall() or impl From<PolicyNow> for WallNow here\n' \
    >> "${doc}/${SOAK_SRC}/rig/mod.rs"
  _case "a comment naming the banned shapes passes" 0 check_no_conversion "${doc}"

  local noclock="${tmp}/noclock"; _mk "${noclock}"
  rm -f "${noclock}/${CLOCK_RS}"
  _case "sources with no clock module at all is BROKEN, not clean" 2 check_no_conversion "${noclock}"

  local renamed="${tmp}/renamed"; _mk "${renamed}"
  sed -i 's/struct PolicyNow/struct PolicyInstant/' "${renamed}/${CLOCK_RS}"
  _case "a renamed clock newtype is BROKEN, not clean" 2 check_no_conversion "${renamed}"

  # --- C2: a policy instant at a wall seam, in each seam family.
  local c2a="${tmp}/c2a"; _mk "${c2a}"
  printf 'fn f(p: PolicyNow) { processor.note_subscription_opened(hex, policy_now.secs()); }\n' \
    >> "${c2a}/${SOAK_SRC}/rig/mod.rs"
  _case "a policy instant at a processor window seam fails" 1 check_seam_partition "${c2a}"

  local c2b="${tmp}/c2b"; _mk "${c2b}"
  printf 'fn f() { let s = since_for_stream("g", 0, phase, PolicyNow::from_wall_with_offset(w, o).secs()); }\n' \
    >> "${c2b}/${SOAK_SRC}/rig/mod.rs"
  _case "a policy instant at a cursor seam fails" 1 check_seam_partition "${c2b}"

  local c2c="${tmp}/c2c"; _mk "${c2c}"
  printf 'fn f() { proc.open_delivery_window(&key, policy_offset_secs); }\n' \
    >> "${c2c}/${SOAK_SRC}/rig/mod.rs"
  _case "a policy OFFSET at a delivery-window seam fails" 1 check_seam_partition "${c2c}"

  # --- C3: the mirror.
  local c3a="${tmp}/c3a"; _mk "${c3a}"
  printf 'fn f() { mgr.sweep_unresolvable_inputs(wall_now.secs()); }\n' \
    >> "${c3a}/${SOAK_SRC}/rig/mod.rs"
  _case "a wall instant at a policy sweep seam fails" 1 check_seam_partition "${c3a}"

  local c3b="${tmp}/c3b"; _mk "${c3b}"
  printf 'fn f(w: WallNow) { circle.repair_epoch_rotation(WallNow::now().secs()); }\n' \
    >> "${c3b}/${SOAK_SRC}/rig/mod.rs"
  _case "a wall instant at the rotation seam fails" 1 check_seam_partition "${c3b}"

  local c3ok="${tmp}/c3ok"; _mk "${c3ok}"
  printf 'fn f() { // sweep_unresolvable_inputs(wall_now) would be wrong\n}\n' \
    >> "${c3ok}/${SOAK_SRC}/rig/mod.rs"
  _case "a comment describing the mistake passes" 0 check_seam_partition "${c3ok}"

  # --- C4: the vocabulary floor, derived from haven-core.
  local gone="${tmp}/gone"; _mk "${gone}"
  sed -i '/^pub fn open_delivery_window/d' "${gone}/${CORE_SRC}/relay/seams.rs"
  _case "a renamed seam is BROKEN, not clean" 2 check_seam_names_still_exist "${gone}"

  local nocore="${tmp}/nocore"; _mk "${nocore}"
  rm -rf "${nocore}/${CORE_SRC}"
  _case "no haven-core source at all is BROKEN" 2 check_seam_names_still_exist "${nocore}"

  # --- the landing window.
  local absent="${tmp}/absent"; _mk "${absent}"
  rm -rf "${absent}/tooling"
  _case "C1 is inert while the rig is absent" 0 check_no_conversion "${absent}"
  _case "C2/C3 are inert while the rig is absent" 0 check_seam_partition "${absent}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin." >&2
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

  run_all "${REPO_ROOT}"

  if (( BROKEN )); then
    echo >&2
    echo "This guard could not see what it checks. That is not a clean bill of" >&2
    echo "health: a pattern that has stopped matching reports every call site as" >&2
    echo "compliant. See the header of this script." >&2
    exit 2
  fi
  if (( FAILED )); then
    echo >&2
    echo "The rig steps a clock on purpose, and exactly one kind of seam may see" >&2
    echo "the offset. A policy instant at a cursor, anchor or window seam does not" >&2
    echo "accelerate anything — it invents the fork the run then reports. See" >&2
    echo "tooling/soak/src/clock.rs and docs/SOAK_LANE.md." >&2
    exit 1
  fi
  log "OK — the two clocks do not convert, and neither reaches the other's seams."
}

main "$@"
