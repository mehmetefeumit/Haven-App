#!/usr/bin/env bash
# CI guard: every SharedPreferences key constant the app defines is either
# cleared on the identity-delete path, or on an explicit, reasoned keep-list.
#
# ## Why this exists
#
# `identityAdvancedDeleteBody` tells the user: "This deletes your identity and
# all circle data from this phone." Nothing enforced that promise structurally:
# `haven.security.pending_leaves` (the public nostr_group_id of every circle
# this identity was leaving), the background publish-history timestamps, and a
# stranded pre-Dark-Matter legacy MLS key all survived a delete, unnoticed,
# because no test — and no guard — ever asked "does EVERY SharedPreferences key
# have a deliberate fate on this path". A key added tomorrow would silently
# repeat the bug: nothing today forces the author to decide.
#
# ## What is checked, and how
#
# 1. DISCOVER every `const String NAME = ...;` declared in haven/lib.
# 2. CONFIRM which of those are genuinely SharedPreferences keys — used as the
#    first argument to a `prefs.<accessor>(` / `_prefs.<accessor>(` call
#    ANYWHERE in haven/lib. This is a USAGE test, not a naming convention: it is
#    what correctly excludes the `flutter_secure_storage` identity-key literal
#    (three call sites share `'haven.nostr.identity'`, none of them SharedPreferences),
#    the isolate-to-isolate liveness ping/pong Map keys, and the compile-time
#    `stadiaApiKey` — all of which happen to be named `*Key` too, so a
#    naming-only filter would misclassify every one of them.
# 3. For each confirmed key, require EITHER:
#      (a) CLEARED — the name appears in a `.remove(NAME)` or
#          `.setBool(NAME, false)` call inside one of DELETE_PATH_FILES (the
#          reviewed set of files that implement `IdentityNotifier.deleteIdentity`'s
#          teardown), or
#      (b) KEPT — the name is a key in this script's own KEEP_LIST, each entry
#          carrying its reason inline.
#    Anything else is a violation: a key nobody made a decision about.
#
# Check (a) deliberately does not accept a bare READ (`getBool(NAME)`) as
# "handled" — `kBackgroundSharingKey` is read inside a DELETE_PATH_FILE
# (`isBackgroundSharingEnabled()`) but is deliberately never cleared there, and
# a guard that could not tell "read" from "cleared" would let it pass silently
# instead of forcing it onto the keep-list where its reason is reviewable.
#
# Pure-grep gate (no toolchain) so it runs in seconds alongside the other repo
# guards. Behavioural coverage — that a clear actually fires, in the right
# order, and survives a delete — lives in
# haven/test/providers/identity_provider_test.dart and
# haven/test/services/nostr_identity_service_delete_test.dart; this guard's job
# is narrower and complementary: stop a NEW key from going unconsidered.
#
# Usage:
#   check_identity_delete_prefs_residue.sh              # check the tree
#   check_identity_delete_prefs_residue.sh --self-test  # hermetic fixtures
#
# Exit codes:
#   0  every confirmed key is cleared or explicitly kept
#   1  a confirmed key has no fate (violation)
#   2  the guard itself is broken (extractor found nothing / a stale keep-list
#      entry / a failed self-test)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_identity_delete_prefs_residue'

# Anti-vacuity floor. 17 SharedPreferences key constants existed when this
# guard landed; the floor sits well below so removing a couple of keys is not
# a red, but an extractor that has stopped matching (a rename of `const
# String`, a directory move) collapses to 0 and must fail loudly rather than
# report "0 keys, none unaccounted for".
readonly MIN_CONFIRMED_KEYS=10

# The reviewed set of files that implement `IdentityNotifier.deleteIdentity`'s
# SharedPreferences teardown. `identity_provider.dart` itself is the
# orchestrator but calls out to these by method (`PendingLeaveService.clearAll`,
# `BackgroundLocationManager.clearPublishHistoryOnIdentityDelete` /
# `disableBackgroundScheduling`) rather than touching prefs keys by name, so it
# is not itself in this set — see the Dart tests for the orchestration proof.
# Extending the delete path to a new file means adding it HERE, deliberately.
declare -a DELETE_PATH_FILES=(
  "${REPO_ROOT}/haven/lib/src/services/background_location_manager.dart"
  "${REPO_ROOT}/haven/lib/src/services/pending_leave_service.dart"
  "${REPO_ROOT}/haven/lib/src/services/pending_mls_wipe_service.dart"
)

# Every SharedPreferences key NOT cleared on the delete path, and why. Keep
# this list reasoned, not just present — a bare name here is exactly the
# silent-residue failure mode this guard exists to close off.
declare -A KEEP_LIST=(
  [kBackgroundSharingKey]="the user's background-sharing TOGGLE STATE — deliberately left set (identity_provider.dart documents why); load-bearing for scripts/ci/check_m7_native_wake_guards.sh and the M7 background-wake docs"
  [kLocationDisclosureAcceptedKey]="Play 'Prominent Disclosure' consent record — a device preference, not identity or circle data"
  [kLocationDisclosureBackgroundAcceptedKey]="same Play-policy consent, background variant"
  [kOnboardingIntroSeenKey]="onboarding flag — a device preference"
  [kOnboardingDisplayNameSetKey]="onboarding flag — a device preference"
  [kOnboardingCompletedKey]="onboarding flag — a device preference"
  [kLocaleKey]="device preference (haven.locale.tag), not identity or circle data"
  [kThemeModeKey]="device preference (haven.theme.mode)"
  [kMapStyleKey]="device preference (haven.map.style)"
  [kLegacyCutoverDoneKey]="one-time migration marker (haven.security.legacy_cutover_done_v1); re-running its idempotent destroy after a delete is harmless — see LegacyCutoverService"
  [_kBgCatchupEnabledMirrorKey]="WorkManager capability mirror (background_catchup_enabled) — a device/OS capability flag, not identity or circle data"
)

# Dart shares Kotlin/Java comment syntax, so one stripper serves `//`, `/* */`
# and doc comments. Same implementation as check_flag_secure_app_wide.sh, which
# needs it for the same reason: these files' own prose names every token matched
# below, and `sed 's|//.*||'` would let a block-commented call read as live.
code_view() { # <file>
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else {
          two = substr(line, i, 2)
          if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }

readonly ACCESSORS='getBool|getString|getInt|getDouble|getStringList|setBool|setString|setInt|setDouble|setStringList|remove|containsKey'

# ---------------------------------------------------------------------------
# 1. Discover every `const String NAME` declared under <dir>.
# Prints "<file>\t<name>" per declaration. The generated Rust binding
# (src/rust/) is excluded — it is machine output, not app-authored state.
# ---------------------------------------------------------------------------
declared_constants() { # <dir>
  local dir="$1"
  find "${dir}" -name '*.dart' -not -path '*/src/rust/*' -print0 2>/dev/null \
    | xargs -0 -r /usr/bin/grep -HoE '^const String [A-Za-z_][A-Za-z0-9_]*' 2>/dev/null \
    | sed -E 's/^([^:]+):const String /\1\t/'
}

# ---------------------------------------------------------------------------
# 2. Every distinct identifier passed as the first argument to a
# `[Pp]refs.<accessor>(` call under <dir>. Each file is newline-joined on its
# OWN (never across files) so a call wrapped across lines by dart format is
# still seen as one statement, without ever merging two files' text.
# ---------------------------------------------------------------------------
prefs_accessor_args() { # <dir>
  local dir="$1" f joined
  while IFS= read -r f; do
    joined=$(code_view "${f}" | tr '\n' ' ')
    /usr/bin/grep -oP "[A-Za-z_]*[Pp]refs\.(${ACCESSORS})\(\s*\K[A-Za-z_][A-Za-z0-9_]*" \
      <<<"${joined}" || true
  done < <(find "${dir}" -name '*.dart' -not -path '*/src/rust/*' 2>/dev/null | sort)
}

# ---------------------------------------------------------------------------
# 3. Whether <name> is CLEARED inside one of the given files: a `.remove(name)`
# or a `.setBool(name, false)` call. A bare read (getBool/getString/...) does
# NOT count — see the file header for why that distinction is the point.
# Comments are stripped BEFORE joining, so a commented-out call — or prose
# describing one — can never stand in for the real thing.
# ---------------------------------------------------------------------------
cleared_in_files() { # <name> <file...>
  local name="$1" f joined; shift
  for f in "$@"; do
    [[ -f "${f}" ]] || continue
    joined=$(code_view "${f}" | tr '\n' ' ')
    if /usr/bin/grep -qE "\.remove\([ \t]*${name}\b" <<<"${joined}"; then
      return 0
    fi
    if /usr/bin/grep -qE "\.setBool\([ \t]*${name}[ \t]*,[ \t]*false\b" <<<"${joined}"; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Runs the whole union-invariant check over <dir>, treating <delete_files_var>
# (a nameref to an indexed array) and <keep_list_var> (a nameref to an
# associative array) as the clearing surface and the reasoned exceptions.
# Prints one VIOLATION line per unhandled key and one #summary line; the
# caller interprets the return code.
#
# Returns 0 (clean), 1 (>=1 violation), or 2 (broken: extractor found nothing,
# or a keep-list entry does not correspond to any confirmed key).
# ---------------------------------------------------------------------------
check_union_invariant() { # <dir> <delete_files_var> <keep_list_var>
  local dir="$1"
  local -n delete_files="$2"
  local -n keep_list="$3"
  local -A declared=() confirmed=() seen_keep=()
  local file name violations=0

  while IFS=$'\t' read -r file name; do
    [[ -n "${name}" ]] || continue
    declared["${name}"]="${file}"
  done < <(declared_constants "${dir}")

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    [[ -n "${declared[${name}]:-}" ]] || continue
    confirmed["${name}"]="${declared[${name}]}"
  done < <(prefs_accessor_args "${dir}")

  if (( ${#confirmed[@]} == 0 )); then
    misconfig "found 0 SharedPreferences key constants under ${dir}."
    echo "  Either the tree really has none (self-test fixture?) or the" >&2
    echo "  extractor has stopped matching — update this guard, do not delete it." >&2
    return 2
  fi

  for name in "${!confirmed[@]}"; do
    if cleared_in_files "${name}" "${delete_files[@]}"; then
      continue
    fi
    if [[ -n "${keep_list[${name}]:-}" ]]; then
      seen_keep["${name}"]=1
      continue
    fi
    fail "SharedPreferences key '${name}' (${confirmed[${name}]}) has no fate on" \
      "the identity-delete path and is not on this guard's KEEP_LIST."
    echo "  Either clear it in one of the DELETE_PATH_FILES, or add it to" >&2
    echo "  KEEP_LIST with a reason — a new key must be a deliberate decision." >&2
    violations=$((violations + 1))
  done

  # A keep-list entry that matches no confirmed key is drift: the constant was
  # renamed or removed, and the reasoning behind it is now checking nothing.
  for name in "${!keep_list[@]}"; do
    if [[ -z "${confirmed[${name}]:-}" ]]; then
      misconfig "KEEP_LIST entry '${name}' matches no confirmed SharedPreferences key."
      echo "  It was likely renamed or removed — update the keep-list, it is" >&2
      echo "  checking nothing as written." >&2
      return 2
    fi
  done

  if (( violations > 0 )); then
    return 1
  fi
  printf '#summary %d confirmed, %d kept\n' "${#confirmed[@]}" "${#seen_keep[@]}"
  return 0
}

# ---------------------------------------------------------------------------
# Anti-vacuity floor on the REAL tree. Separate from check_union_invariant's
# own `found 0` check: a PARTIALLY broken extractor (a rename that only
# affects some declarations, a directory that stops being walked) can still
# turn up a handful of keys and look clean under a bare "not zero" test. The
# floor is only meaningful against the real haven/lib population, so it is
# applied in main() rather than inside check_union_invariant, which self-test
# fixtures deliberately exercise with tiny counts.
# ---------------------------------------------------------------------------
enforce_confirmed_floor() { # <count>
  local count="$1"
  if (( count < MIN_CONFIRMED_KEYS )); then
    misconfig "found only ${count} confirmed SharedPreferences key(s), expected >= ${MIN_CONFIRMED_KEYS}."
    echo "  The extractor has likely stopped matching part of the tree — this" >&2
    echo "  guard would otherwise silently check far less than it claims." >&2
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0 got=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # <label> <want-rc> <lib-tree-shell> <delete-file-shell> <keep-list-decl>
  _case() {
    local label="$1" want="$2" lib_src="$3" delete_src="$4" keep_decl="$5"
    checked=$((checked + 1))
    rm -rf "${tmp}/lib" "${tmp}/delete.dart"
    mkdir -p "${tmp}/lib"
    printf '%s' "${lib_src}" > "${tmp}/lib/keys.dart"
    printf '%s' "${delete_src}" > "${tmp}/delete.dart"

    local -a fixture_delete_files=("${tmp}/delete.dart")
    local -A fixture_keep_list=()
    eval "${keep_decl}"

    local got=0
    check_union_invariant "${tmp}/lib" fixture_delete_files fixture_keep_list \
      >/dev/null 2>&1 || got=$?
    if (( got == want )); then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  log "self-test: the union invariant"

  _case "a key removed on the delete path passes" 0 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) { prefs.remove(kFoo); }
" \
'fixture_keep_list=()'

  _case "a boolean marker cleared via setBool(_, false) passes" 0 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) {
  prefs.setBool(kFoo, true);
  prefs.setBool(kFoo, false);
}
" \
'fixture_keep_list=()'

  _case "a key on neither the delete path nor the keep-list FAILS" 1 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) { prefs.remove(kUnrelated); }
" \
'fixture_keep_list=()'

  # THE regression this guard exists for: a read-only reference inside a
  # delete-path file must not be mistaken for a clear.
  _case "a bare READ inside a delete-path file does not count as cleared" 1 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
'fixture_keep_list=()'

  # A real regression caught while writing this guard: a mutated-out call left
  # as a comment (`// await prefs.remove(kFoo);`) still contains the literal
  # text `.remove(kFoo)` and must NOT be read as a live clear.
  _case "a commented-out clear does not count as cleared" 1 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) {
  // await prefs.remove(kFoo);
}
" \
'fixture_keep_list=()'

  # ...and the same in a BLOCK comment, which a line-oriented stripper would
  # hand back verbatim as live code.
  _case "a block-commented clear does not count as cleared" 1 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) {
  /* await prefs.remove(kFoo); */
}
" \
'fixture_keep_list=()'

  _case "a key on the keep-list, cleared nowhere, passes" 0 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) { prefs.remove(kUnrelated); }
" \
'fixture_keep_list=([kFoo]="reasoned exception")'

  # The classifier: a `*Key`-named constant used ONLY with secure storage (or
  # anything else that is not `prefs.`) must be excluded entirely, not flagged —
  # a genuine, cleared prefs key sits alongside it so this isolates the
  # classifier from the separate anti-vacuity fixture below.
  _case "a non-prefs *Key constant is excluded, not flagged" 0 \
"const String kSecretStorageKey = 'x.secret';
const String kFoo = 'x.foo';
void r(FlutterSecureStorage s) { s.read(key: kSecretStorageKey); }
void g(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) { prefs.remove(kFoo); }
" \
'fixture_keep_list=()'

  # A stale keep-list entry (renamed/removed constant) is guard drift, not a
  # silent pass — the reasoning behind it would otherwise check nothing.
  _case "a keep-list entry matching no declared constant is BROKEN" 2 \
"const String kFoo = 'x.foo';
void r(SharedPreferences prefs) { prefs.getBool(kFoo); }
" \
"void c(SharedPreferences prefs) { prefs.remove(kFoo); }
" \
'fixture_keep_list=([kRenamedAway]="stale reason")'

  # Anti-vacuity: a tree with zero SharedPreferences-shaped constants must be
  # reported BROKEN, never a silent "0 keys, all fine".
  _case "an empty tree is reported BROKEN, not a vacuous pass" 2 \
"const String kUnrelatedApiKey = String.fromEnvironment('X');
void r() {}
" \
"void c() {}
" \
'fixture_keep_list=()'

  log "self-test: the real-tree anti-vacuity floor"

  checked=$((checked + 1))
  got=0
  enforce_confirmed_floor "$((MIN_CONFIRMED_KEYS - 1))" >/dev/null 2>&1 || got=$?
  if (( got == 2 )); then
    printf '  \033[1;32mPASS\033[0m a count below the floor is reported BROKEN\n'
  else
    printf '  \033[1;31mFAIL\033[0m a count below the floor should return 2, got %d\n' "${got}" >&2
    fails=1
  fi

  checked=$((checked + 1))
  got=0
  enforce_confirmed_floor "${MIN_CONFIRMED_KEYS}" >/dev/null 2>&1 || got=$?
  if (( got == 0 )); then
    printf '  \033[1;32mPASS\033[0m a count exactly at the floor passes\n'
  else
    printf '  \033[1;31mFAIL\033[0m a count exactly at the floor should return 0, got %d\n' "${got}" >&2
    fails=1
  fi

  if (( fails )); then
    fail "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (${checked} fixtures)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || { misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"; exit 2; }

  local lib_dir="${REPO_ROOT}/haven/lib" f
  [[ -d "${lib_dir}" ]] || { misconfig "${lib_dir} not found"; exit 2; }
  for f in "${DELETE_PATH_FILES[@]}"; do
    [[ -f "${f}" ]] || { misconfig "DELETE_PATH_FILES entry not found: ${f}"; exit 2; }
  done

  local out rc=0
  out="$(check_union_invariant "${lib_dir}" DELETE_PATH_FILES KEEP_LIST)" || rc=$?

  if (( rc == 2 )); then
    exit 2
  elif (( rc == 1 )); then
    exit 1
  fi
  local confirmed_count
  confirmed_count="$(sed -n 's/^#summary \([0-9]*\).*/\1/p' <<<"${out}")"
  enforce_confirmed_floor "${confirmed_count:-0}" || exit 2

  local summary
  summary="$(sed -n 's/^#summary //p' <<<"${out}")"
  log "OK: ${summary//confirmed/SharedPreferences key(s) confirmed} — every key is either cleared on identity delete or on the explicit keep-list."
  exit 0
}

main "$@"
