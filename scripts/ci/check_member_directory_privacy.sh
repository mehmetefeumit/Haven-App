#!/usr/bin/env bash
# CI guard: the local member directory (`member_directory` in circles.db) stays
# a list of PEOPLE, bounded in time, and confined to the encrypted database.
#
# ## Why this exists
#
# The directory records everyone this device currently shares a circle with,
# plus everyone it shared one with in the last three days. That is a contact
# list. It becomes a *social graph* the moment a row can be attributed to a
# circle, it becomes a permanent record the moment the purge stops running, and
# it survives an identity deletion the moment a second copy lands outside the
# SQLCipher database that logout deletes. Those three failure modes are the
# invariants below (plan docs/MEMBER_PICKER_PLAN.md §6.1, §10 D3, §13):
#
#   INV-D-DIRECTORY-HOLDS-NO-CIRCLE-IDENTIFIER
#   INV-D-DIRECTORY-RETENTION-BOUNDED
#   INV-D-DIRECTORY-NEVER-LEAVES-SQLCIPHER
#
# ## What this guard does NOT do, deliberately
#
# `haven-core/src/circle/storage_member_directory.rs` already carries a
# `PRAGMA table_info` test pinning the table's exact column list (plus a
# `sqlite_master` test pinning WITHOUT ROWID, which PRAGMA cannot see), plus
# tests pinning the three-day constant and that the purge DELETEs rather than
# hides. None of that is re-implemented here. This guard covers only what a
# unit test inside that module structurally CANNOT see:
#
#   * a SECOND writer of the table, in another module or another language;
#   * an `ALTER TABLE` on a migration path a fresh `in_memory()` open never
#     takes, and a companion table that re-creates the person->circle join
#     beside the guarded one (the PRAGMA test asserts the columns of the ONE
#     table it opens);
#   * the directory API being wired up without its purge — a retention promise
#     nobody schedules is not a retention promise, and no in-module test can
#     see its own caller;
#   * a sidecar copy: a second `Connection`, a file, a keyring blob on the Rust
#     side, or `SharedPreferences`/secure storage/a written file on the Dart
#     side. Logout deletes exactly the `circles.db` file set, so a third file
#     outlives identity deletion.
#
# `INV-D-SEARCH-QUERY-NEVER-LEAVES-DEVICE` is deliberately NOT enforced here.
# The typed query is folded and matched locally, but the egress claim was
# re-scoped by plan §12 to "closed-world over Nostr relay frames; open-world
# elsewhere" — the IME dictionary, the clipboard and Android Content Capture sit
# outside any wire proxy — and decision D2 has the *correct* path send a
# complete validated npub as hex. A grep asserting "the query never crosses a
# boundary" would therefore be false where it matters and would false-red on
# every legitimate refactor of the search path. Its real proof is the E2E
# wire-canary oracle (bech32-decode, then compare), not a source scan. The plan
# cut `check_directory_logic_not_in_ffi.sh` and
# `check_directory_plane_separation.sh` on exactly this reasoning.
#
# ## Vocabulary
#
# "chunk": the production text of a Rust file, comments (`//`, `/* */` and SQL
# `--`) removed, split on `;`. A SQL statement embedded in Rust is one chunk,
# which is what lets a rule say "this statement must not also name that" —
# prose describing the forbidden shape is stripped before any rule sees it, so
# no check here matches documentation.
#
# Pure grep/awk (no Rust/Flutter toolchain), so it runs with the other repo
# guards in seconds. Every check runs even after an earlier one fails, so one
# red run reports every violation.
#
# Usage:
#   check_member_directory_privacy.sh              # check the tree
#   check_member_directory_privacy.sh --self-test  # hermetic fixtures
#
# Exit codes:
#   0  every check passes
#   1  a privacy-boundary violation was found
#   2  the guard itself is broken (a pinned file/symbol is gone, an extractor
#      matched nothing, or a self-test fixture failed)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_member_directory_privacy'

# The ONE module allowed to run SQL against the table, and the ONE file allowed
# to declare it. Everything else is the complement.
readonly DIR_MODULE="${REPO_ROOT}/haven-core/src/circle/storage_member_directory.rs"
readonly SCHEMA_FILE="${REPO_ROOT}/haven-core/src/circle/storage.rs"
readonly CORE_SRC="${REPO_ROOT}/haven-core/src"
readonly FFI_SRC="${REPO_ROOT}/haven/rust_builder/src"
readonly LIB_DIR="${REPO_ROOT}/haven/lib"
readonly ANDROID_DIR="${REPO_ROOT}/haven/android"
readonly IOS_DIR="${REPO_ROOT}/haven/ios"

# The SQL table name, matched as a whole token. The leading class excludes
# `storage_member_directory` (the module) from matching the table.
readonly TABLE_TOKEN='(^|[^A-Za-z0-9_])member_directory([^A-Za-z0-9_]|$)'

# Identifier-shaped circle/group/MLS tokens. A statement that names the
# directory table must not also name one of these: that statement is the join
# the table exists not to hold. Matched as whole words (`grep -w`).
readonly CIRCLE_IDENT_TOKENS='circle_id|circleId|CircleId|circle_hex|group_id|groupId|GroupId|nostr_group_id|nostrGroupId|mls_group_id|MlsGroupId|mls_group|epoch|Epoch|circle_members|circles'

# Column-name rule, applied to DDL only (CREATE/ALTER) and only to extracted
# COLUMN NAMES — a substring test, exactly as the in-module PRAGMA test applies
# it to the columns of the one table it opens. Scoped this way, `GROUP BY` in a
# query and the `TEXT`/`INTEGER` type keywords can never trip it, while
# `last_group` and `origin_circle` cannot slip past a word-boundary rule.
readonly DDL_FORBIDDEN_SUBSTRINGS='circle|group|mls|epoch|conversation'

# The directory's own API. Splitting it this way is the retention coupling:
# reaching for any ACTIVATION symbol outside the module means the directory is
# live, and a live directory must have its purge wired.
readonly -a ACTIVATION_FNS=(
  sync_co_members
  ranked_directory_members
  delete_directory_member
  delete_directory_members
)
readonly -a COMPANION_FNS=(
  prune_expired_directory_members
)

# Companions required only WHEN THEY EXIST. A bulk wipe is one of two ways the
# rows can die; the other is logout deleting the circles.db file set, which is
# what actually carries the logout guarantee and is pinned by
# `the_member_directory_does_not_outlive_the_circles_db_file`. So a tree with
# no wipe fn is a legitimate design, while a tree that HAS one and never calls
# it is a dead erase path — worse than none, because it reads as coverage.
readonly -a OPTIONAL_COMPANION_FNS=(
  wipe_member_directory
)

# The Dart surface, discovered two ways because neither way alone covers it.
#
#   (1) Filename convention (as check_profile_privacy_boundaries.sh does for
#       `*profile*`): a newly added directory widget or provider is covered
#       without anyone remembering to list it.
#   (2) Import closure over DART_SURFACE_SEEDS: the modules that carry the
#       rows, the staged picks and the query fold. Anything importing one of
#       them handles directory-derived data whatever it is named — which is
#       how `member_avatar.dart`, `search_fold.dart`, `create_circle_page.dart`
#       and `add_member_page.dart` come in. Convention alone left all four
#       outside the scan, so a recent-searches cache or a staged-member draft
#       written to SharedPreferences from any of them passed silently: exactly
#       the second, unencrypted home for a contact list that check 4 exists to
#       forbid.
#
# The seeds are the row/state/query modules and deliberately NOT
# `member_directory_service.dart`. That interface is imported by
# `service_providers.dart`, the app-wide DI file whose other providers have
# nothing to do with the directory; seeding on it would red this guard on an
# unrelated provider reaching for SharedPreferences, and blame the member
# directory while doing it. `member_directory_service.dart` is still scanned —
# it matches the convention, and it imports the fold.
#
# Seeds are matched on their last two path segments, so a relative import
# (`../utils/search_fold.dart`) is caught as well as the package form the
# analyzer actually enforces.
readonly DART_SURFACE_GLOBS='*member_director*.dart|member_pick*.dart|member_search*.dart'
readonly -a DART_SURFACE_SEEDS=(
  src/providers/member_directory_provider.dart
  src/utils/member_pick_state.dart
  src/utils/search_fold.dart
  src/widgets/circles/member_avatar.dart
  src/widgets/circles/member_picker.dart
  src/widgets/circles/member_search_field.dart
)

# Anti-vacuity floors, one per discovery lane plus one on the union. A lane
# that silently stops matching — a rename away from the convention, an import
# style the extractor no longer recognises — takes its floor below water and
# exits 2 rather than reporting a green scan over nothing.
readonly MIN_DART_SURFACE_GLOB=4
readonly MIN_DART_SURFACE_IMPORTERS=4
readonly MIN_DART_SURFACE_FILES=8

# Persistence entry points that write OUTSIDE circles.db. Any of these in a
# directory file means a second, unencrypted home for a contact list that
# logout would not reach.
readonly OFF_DB_PERSISTENCE_DART='SharedPreferences|FlutterSecureStorage|secureStorage|getApplicationDocumentsDirectory|getApplicationSupportDirectory|getExternalStorageDirectory|getTemporaryDirectory|getDownloadsDirectory|path_provider|(^|[^A-Za-z0-9_.])File\(|writeAsString|writeAsBytes|(^|[^A-Za-z0-9_])Hive|(^|[^A-Za-z0-9_])Isar|localStorage|NSUserDefaults|UserDefaults'

# The Rust equivalent, inside the directory module: it owns no handle but the
# shared `CircleStorage` connection, so any of these is a sidecar.
readonly OFF_DB_PERSISTENCE_RUST='Connection::open|std::fs|(^|[^A-Za-z0-9_:])fs::|File::create|OpenOptions|write_all|(^|[^A-Za-z0-9_])keyring|to_writer|BufWriter|tempfile'

log()       { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
violation() { printf '\033[1;31m[%s] VIOLATION:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; VIOLATIONS=$((VIOLATIONS + 1)); }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
VIOLATIONS=0

# ---------------------------------------------------------------------------
# Views.
#
# `code_view` strips `//`, `/* */` and SQL `--` comments, one output line per
# input line so line numbers survive. Character-level rather than string-aware:
# a `//` inside a string literal truncates the rest of that line. Nothing this
# guard matches can legitimately share a line with a URL literal, and the
# failure direction is a MISS, never a false red.
# ---------------------------------------------------------------------------
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
          else if (two == "//" || two == "--") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

# `prod_view` is `code_view` with `#[cfg(test)]` module bodies blanked by a
# brace walk (the technique used by check_profile_privacy_boundaries.sh). Unit
# tests legitimately open temp files, name `std::fs` and run SELECTs that a
# production rule forbids; blanking rather than deleting keeps line numbers.
prod_view() { # <rust file>
  code_view "$1" | awk '
    { lines[NR] = $0 }
    END {
      depth = 0; intest = 0; pending = 0; testdepth = 0
      for (j = 1; j <= NR; j++) {
        t = lines[j]
        if (!intest && t ~ /#\[[[:space:]]*cfg\(test\)/) pending = 1
        tmp = t; o = gsub(/[{]/, "", tmp)
        tmp = t; c = gsub(/[}]/, "", tmp)
        if (!intest && pending && o > 0 && t ~ /(^|[^A-Za-z0-9_])mod([^A-Za-z0-9_]|$)/) {
          intest = 1; testdepth = depth; pending = 0
        }
        istest[j] = intest
        depth += o - c
        if (intest && depth <= testdepth) intest = 0
      }
      for (j = 1; j <= NR; j++) print (istest[j] ? "" : lines[j])
    }'
}

# Every `;`-delimited chunk of a Rust file that names the directory table, one
# per output line, whitespace squeezed. This is the statement-level view: an
# embedded SQL statement and the Rust call wrapping it land in one chunk.
#
# The squeeze is `sed`, not `tr -s '[:space:]'`: `tr` would fold the newlines
# the `;` split just produced and hand every rule ONE chunk containing the
# whole file, which passes every "this statement must not also name that" rule
# vacuously in one direction and reports the entire file in the other.
directory_chunks() { # <rust file>
  prod_view "$1" \
    | tr '\n' ' ' \
    | tr ';' '\n' \
    | sed 's/[[:space:]][[:space:]]*/ /g' \
    | grep -E "${TABLE_TOKEN}" || true
}

# Column names declared by a DDL chunk read on stdin: everything between the
# outermost parentheses of a `CREATE TABLE`, split on commas and reduced to the
# leading identifier, plus the identifier an `ALTER TABLE ... ADD [COLUMN]`
# introduces.
ddl_column_names() {
  local chunk; chunk="$(cat)"
  if grep -qiE 'CREATE[[:space:]]+TABLE' <<<"${chunk}"; then
    sed 's/^[^(]*(//; s/)[^)]*$//' <<<"${chunk}" \
      | tr ',' '\n' \
      | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' \
      | sed 's/^[[:space:]]*//'
  fi
  if grep -qiE 'ALTER[[:space:]]+TABLE' <<<"${chunk}"; then
    grep -oiE 'ADD[[:space:]]+(COLUMN[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*' <<<"${chunk}" \
      | grep -oE '[A-Za-z_][A-Za-z0-9_]*$'
  fi
}

# Rust sources to scan, minus the machine-generated FRB binding (not
# app-authored, and it mirrors every exported symbol by construction). The
# optional pattern pre-filters to files that could possibly match, so the
# awk-based views run over a handful of files rather than the whole crate.
rust_sources() { # <grep-pattern|-> <root...>
  local pattern="$1"; shift
  if [[ "${pattern}" == "-" ]]; then
    find "$@" -type f -name '*.rs' -not -name 'frb_generated.rs' 2>/dev/null | sort
  else
    grep -rlE --include='*.rs' "${pattern}" "$@" 2>/dev/null \
      | grep -v '/frb_generated\.rs$' | sort || true
  fi
}

# The two Dart discovery lanes, and their union. Generated Dart (`src/rust/`,
# `l10n/`) is excluded: it is not app-authored, and the FRB binding mirrors
# every exported symbol by construction.
dart_surface_by_convention() { # <lib-root>
  find "$1" -type f \
    \( -name '*member_director*.dart' -o -name 'member_pick*.dart' -o -name 'member_search*.dart' \) \
    2>/dev/null | sort
}

dart_surface_by_import() { # <lib-root>
  local seed alt=''
  for seed in "${DART_SURFACE_SEEDS[@]}"; do
    # Last two path segments: matches the package form and a relative one.
    alt+="|$(printf '%s' "${seed%.dart}" | awk -F/ '{ print $(NF-1) "/" $NF }')"
  done
  grep -rlE --include='*.dart' "import[[:space:]]+'[^']*(${alt#|})\.dart'" "$1" 2>/dev/null \
    | grep -vE '/(src/rust|l10n)/' | sort || true
}

dart_surface() { # <lib-root>
  local root="$1" seed
  {
    dart_surface_by_convention "${root}"
    dart_surface_by_import "${root}"
    for seed in "${DART_SURFACE_SEEDS[@]}"; do
      if [[ -f "${root}/${seed}" ]]; then printf '%s\n' "${root}/${seed}"; fi
    done
  } | sort -u
}

# ---------------------------------------------------------------------------
# Check 1: no circle/group/MLS identifier reaches the table.
#
# One rule over every chunk that names the table, wherever it lives:
#   (a) DDL (CREATE/ALTER) may not name a circle/group/MLS COLUMN — bare words,
#       because in a column list a bare word is a name. This is the rule the
#       in-module PRAGMA test cannot apply to an `ALTER` behind a migration
#       sentinel, which a fresh `in_memory()` open never executes.
#   (b) any statement, DDL or not, may not name a circle/group/MLS IDENTIFIER —
#       a `circle_id` bind parameter, a join against `circles`. This is what
#       catches the join being reintroduced as a value rather than a column.
# ---------------------------------------------------------------------------
check_no_circle_identifier() { # <root...>
  local file chunk hits
  while IFS= read -r file; do
    while IFS= read -r chunk; do
      [[ -n "${chunk}" ]] || continue
      if grep -qiE '(CREATE|ALTER)[[:space:]]+TABLE' <<<"${chunk}"; then
        hits="$(ddl_column_names <<<"${chunk}" \
          | grep -iE "${DDL_FORBIDDEN_SUBSTRINGS}" | sort -u | tr '\n' ' ' || true)"
        if [[ -n "${hits}" ]]; then
          violation "${file#"${REPO_ROOT}/"}: member_directory DDL declares a circle/group/MLS column (${hits% })"
          printf '    %s\n' "${chunk:0:200}" >&2
        fi
      fi
      hits="$(grep -owE "${CIRCLE_IDENT_TOKENS}" <<<"${chunk}" | sort -u | tr '\n' ' ' || true)"
      if [[ -n "${hits}" ]]; then
        violation "${file#"${REPO_ROOT}/"}: a statement naming member_directory also names a circle/group/MLS identifier (${hits% }) — the directory records PEOPLE, never which circle they came from"
        printf '    %s\n' "${chunk:0:200}" >&2
      fi
    done < <(directory_chunks "${file}")
  done < <(rust_sources "${TABLE_TOKEN}" "$@")
}

# ---------------------------------------------------------------------------
# Check 2: no second writer, and no companion table.
#
# (a) Only `storage_member_directory.rs` may run SQL against the table, and
#     only `storage.rs` may declare it. A statement in `manager.rs`, in the FFI
#     layer, or in a future `storage_*.rs` is invisible to every test the
#     directory module owns.
# (b) `storage.rs`'s own mentions must be DDL: it declares the table, it does
#     not read or write it.
# (c) No second table whose name says "directory". The PRAGMA test pins the
#     columns of ONE table; a `directory_circles` beside it holds exactly the
#     mapping the invariant forbids and leaves that test green.
# ---------------------------------------------------------------------------
check_single_writer() { # <module> <schema> <root...>
  local module="$1" schema="$2"; shift 2
  local file chunk name
  while IFS= read -r file; do
    while IFS= read -r chunk; do
      [[ -n "${chunk}" ]] || continue
      if [[ "${file}" == "${module}" ]]; then
        continue
      elif [[ "${file}" == "${schema}" ]]; then
        if ! grep -qiE '(CREATE|ALTER)[[:space:]]+TABLE' <<<"${chunk}"; then
          violation "${file#"${REPO_ROOT}/"}: the schema file may only DECLARE member_directory, never read or write it"
          printf '    %s\n' "${chunk:0:200}" >&2
        fi
      else
        violation "${file#"${REPO_ROOT}/"}: SQL naming member_directory outside ${module#"${REPO_ROOT}/"} — the table has exactly one writer, and a second one is invisible to every test that module owns"
        printf '    %s\n' "${chunk:0:200}" >&2
      fi
    done < <(directory_chunks "${file}")
  done < <(rust_sources "${TABLE_TOKEN}" "$@")

  while IFS= read -r file; do
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      [[ "${name}" == "member_directory" ]] && continue
      violation "${file#"${REPO_ROOT}/"}: CREATE TABLE ${name} — a second 'directory' table re-creates the person-to-circle join beside the guarded one, where the member_directory column test cannot see it"
    done < <(prod_view "${file}" \
      | grep -oiE 'CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      | grep -oE '[A-Za-z_][A-Za-z0-9_]*$' | grep -i 'director' || true)
  done < <(rust_sources 'CREATE[[:space:]]+TABLE' "$@")
}

# ---------------------------------------------------------------------------
# Check 3a: retention is scheduled, not merely implemented.
#
# The moment the directory is reachable from outside its module — anything
# calls `sync_co_members`, `ranked_directory_members` or either
# `delete_directory_member(s)` — the three-day promise is live, and
# `prune_expired_directory_members` (owner decision D3: purged by DELETE, never
# by a display filter) must be wired too, along with any erase path the module
# declares. A purge nobody calls keeps a contact list forever while every
# in-module test stays green: the module cannot see its own callers.
#
# Symmetric by construction: while nothing is wired, nothing is promised and
# this passes. It can only go red on the commit that activates the directory
# without its retention.
# ---------------------------------------------------------------------------
check_retention_is_scheduled() { # <module> <core-root> <ffi-root> <dart-root>
  local module="$1" core="$2" ffi="$3" dart="$4"
  local file fn found_activation="" missing=""

  # snake_case (Rust) and lowerCamelCase (the Dart FFI binding) of one name.
  _both_cases() { printf '%s|%s' "$1" "$(printf '%s' "$1" | awk -F_ '{ s=$1; for (i=2;i<=NF;i++) s = s toupper(substr($i,1,1)) substr($i,2); print s }')"; }

  # NB: never `view | grep -q` here. Under `set -o pipefail` a `-q` grep exits
  # on its first match, SIGPIPEs the awk feeding it, and the PIPELINE returns
  # 141 — so a match reads as "no match", and the size of the file decides
  # whether it does (a hit near EOF is found, a hit at line 1300 of 200 KB is
  # not). Capture the output instead and test it.
  _referenced() { # <fn>
    local pat; pat="$(_both_cases "$1")"
    local word="(^|[^A-Za-z0-9_])(${pat})([^A-Za-z0-9_]|\$)"
    local f hit
    while IFS= read -r f; do
      [[ "${f}" == "${module}" ]] && continue
      hit="$(prod_view "${f}" | grep -E "${word}" || true)"
      if [[ -n "${hit}" ]]; then
        printf '%s' "${f}"; return 0
      fi
    done < <(rust_sources "${word}" "${core}" "${ffi}")
    while IFS= read -r f; do
      case "${f}" in */src/rust/*) continue ;; esac
      hit="$(code_view "${f}" | grep -E "${word}" || true)"
      if [[ -n "${hit}" ]]; then
        printf '%s' "${f}"; return 0
      fi
    done < <(grep -rlE --include='*.dart' "${word}" "${dart}" 2>/dev/null | sort || true)
    return 1
  }

  for fn in "${ACTIVATION_FNS[@]}"; do
    if file="$(_referenced "${fn}")"; then
      found_activation="${fn} (${file#"${REPO_ROOT}/"})"
      break
    fi
  done
  if [[ -z "${found_activation}" ]]; then
    log "  directory API not yet reachable outside its module — retention coupling not yet armed"
    return 0
  fi
  for fn in "${COMPANION_FNS[@]}"; do
    _referenced "${fn}" >/dev/null || missing+="${fn} "
  done
  for fn in "${OPTIONAL_COMPANION_FNS[@]}"; do
    grep -qE "fn[[:space:]]+${fn}[[:space:]]*\(" "${module}" || continue
    _referenced "${fn}" >/dev/null || missing+="${fn} "
  done
  if [[ -n "${missing}" ]]; then
    violation "the directory is wired up (${found_activation}) but ${missing% }is called nowhere — retention is a DELETE that someone has to schedule (owner decision D3), and an erase path that exists but is never reached reads as coverage it does not have. A directory whose purge nobody runs keeps a contact list forever, and no test inside the module can see its own callers."
  fi
}

# ---------------------------------------------------------------------------
# Check 3b: expiry is a DELETE, never a read-side filter.
#
# `purge_after` may appear in a `WHERE` clause only in a `DELETE`. A read that
# hides expired rows (`WHERE purge_after >= ?`) looks identical to a working
# purge from the UI and from every behavioural test that reads through the
# public API — while the rows stay on disk, which is precisely what D3 says
# retention must not mean.
# ---------------------------------------------------------------------------
check_purge_is_a_delete() { # <module>
  local chunk
  while IFS= read -r chunk; do
    [[ -n "${chunk}" ]] || continue
    grep -qE '(^|[^A-Za-z0-9_])purge_after' <<<"${chunk}" || continue
    grep -qiE '(^|[^A-Za-z0-9_])WHERE([^A-Za-z0-9_]|$)' <<<"${chunk}" || continue
    if ! grep -qiE '(^|[^A-Za-z0-9_])DELETE([^A-Za-z0-9_]|$)' <<<"${chunk}"; then
      violation "$(basename "$1"): purge_after is used as a read-side WHERE filter — retention is enforced by DELETING the row (owner decision D3), never by a query hiding it"
      printf '    %s\n' "${chunk:0:200}" >&2
    fi
  done < <(directory_chunks "$1")
}

# ---------------------------------------------------------------------------
# Check 4: the directory never leaves the encrypted database.
#
# (a) Rust: the module holds no handle but the shared `CircleStorage`
#     connection. A second `Connection`, a file, a keyring blob is a copy that
#     logout's deletion of the circles.db file set does not reach.
# (b) Dart: no file on the directory surface — everything `dart_surface`
#     discovers, by convention OR by importing a seed — may write to
#     SharedPreferences/NSUserDefaults, flutter_secure_storage, or a file of
#     its own. The import lane is what makes this cover the pages that stage a
#     pick and the widgets that render a directory row, none of which carry the
#     naming convention.
# (c) Native: the table name appears in no Kotlin/Swift source at all.
# ---------------------------------------------------------------------------
check_stays_in_sqlcipher_rust() { # <module>
  local hits
  hits="$(prod_view "$1" | grep -nE "${OFF_DB_PERSISTENCE_RUST}" || true)"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" | sed 's/^/    /' >&2
    violation "$(basename "$1"): the directory module reaches a store outside circles.db — logout deletes exactly the circles.db file set, so a sidecar survives identity deletion"
  fi
}

check_stays_in_sqlcipher_dart() { # <file...>
  local f hits
  for f in "$@"; do
    hits="$(code_view "${f}" | grep -nE "${OFF_DB_PERSISTENCE_DART}" || true)"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" | sed 's/^/    /' >&2
      violation "${f#"${REPO_ROOT}/"}: a directory file persists outside the encrypted database — the directory lives only in circles.db (owner decision D3)"
    fi
  done
}

check_stays_in_sqlcipher_native() { # <root...>
  local root hits
  for root in "$@"; do
    [[ -d "${root}" ]] || continue
    hits="$(grep -rnE '(^|[^A-Za-z0-9_])(member_directory|memberDirectory|MemberDirectory)' \
      --include='*.kt' --include='*.java' --include='*.swift' --include='*.m' --include='*.h' \
      --include='*.plist' --include='*.xml' "${root}" 2>/dev/null || true)"
    if [[ -n "${hits}" ]]; then
      printf '%s\n' "${hits}" | sed 's/^/    /' >&2
      violation "${root#"${REPO_ROOT}/"}: the member directory is named in native code — it exists only as a table in the Rust-owned encrypted database"
    fi
  done
}

# ---------------------------------------------------------------------------
# Anti-vacuity. Each extractor must be shown to match SOMETHING real, or a
# rename silently turns this guard into a no-op that reports success.
# ---------------------------------------------------------------------------
preflight() {
  local rc=0 fn count
  for f in "${DIR_MODULE}" "${SCHEMA_FILE}"; do
    [[ -f "${f}" ]] || { misconfig "expected file not found: ${f}"; rc=2; }
  done
  (( rc == 0 )) || return "${rc}"

  if [[ -z "$(directory_chunks "${DIR_MODULE}")" ]]; then
    misconfig "no SQL naming member_directory found in ${DIR_MODULE#"${REPO_ROOT}/"} — the chunk extractor has stopped matching"
    rc=2
  fi
  # Captured, not `| grep -q` — see the note in check_retention_is_scheduled.
  if [[ -z "$(directory_chunks "${SCHEMA_FILE}" | grep -iE 'CREATE[[:space:]]+TABLE' || true)" ]]; then
    misconfig "no member_directory DDL found in ${SCHEMA_FILE#"${REPO_ROOT}/"}"
    rc=2
  fi
  for fn in "${ACTIVATION_FNS[@]}" "${COMPANION_FNS[@]}"; do
    # OPTIONAL_COMPANION_FNS are deliberately NOT pinned here: the tree is
    # allowed not to have them (see their declaration).
    if ! grep -qE "fn[[:space:]]+${fn}[[:space:]]*\(" "${DIR_MODULE}"; then
      misconfig "pinned directory fn '${fn}' is not declared in ${DIR_MODULE#"${REPO_ROOT}/"} — the retention coupling names a symbol that no longer exists"
      rc=2
    fi
  done
  # Each seed is pinned by path: it is what the import lane keys on, so a
  # rename that nobody mirrors here silently shrinks the closure instead of
  # failing. Existence is checked before the counts, because a missing seed
  # explains the counts.
  for f in "${DART_SURFACE_SEEDS[@]}"; do
    if [[ ! -f "${LIB_DIR}/${f}" ]]; then
      misconfig "pinned Dart directory seed '${f}' is gone from haven/lib — the import lane of check 4b keys on it, so a rename here shrinks the scan instead of failing it"
      rc=2
    fi
  done

  count=$(dart_surface_by_convention "${LIB_DIR}" | wc -l)
  if (( count < MIN_DART_SURFACE_GLOB )); then
    misconfig "found ${count} Dart directory file(s) matching ${DART_SURFACE_GLOBS} (expected >= ${MIN_DART_SURFACE_GLOB}) — either the surface was renamed away from the convention, leaving that lane of check 4b covering nothing, or it legitimately consolidated and this floor needs revisiting"
    rc=2
  fi
  count=$(dart_surface_by_import "${LIB_DIR}" | wc -l)
  if (( count < MIN_DART_SURFACE_IMPORTERS )); then
    misconfig "found ${count} Dart file(s) importing a directory seed (expected >= ${MIN_DART_SURFACE_IMPORTERS}) — the import extractor has stopped matching, so the pages and widgets that hold directory-derived data are no longer in check 4b"
    rc=2
  fi
  count=$(dart_surface "${LIB_DIR}" | wc -l)
  if (( count < MIN_DART_SURFACE_FILES )); then
    misconfig "the Dart directory surface is ${count} file(s) (expected >= ${MIN_DART_SURFACE_FILES}) — check 4b is scanning less than the surface it was sized for"
    rc=2
  fi
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # <label> <want-violations> <check-invocation...>; the fixture tree is
  # whatever the caller wrote into ${tmp} beforehand.
  _expect() {
    local label="$1" want="$2"; shift 2
    checked=$((checked + 1))
    VIOLATIONS=0
    "$@" >/dev/null 2>&1 || true
    if (( VIOLATIONS == want )); then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want %d violation(s), got %d)\n' "${label}" "${want}" "${VIOLATIONS}" >&2
      fails=1
    fi
  }

  # <label> <lib-root> <expected-relative-path>...; asserts the discovered set
  # exactly, so a lane that over-reaches fails as loudly as one that misses.
  _expect_files() {
    local label="$1" root="$2"; shift 2
    local want got
    want="$(printf '%s\n' "$@" | sort -u)"
    got="$(dart_surface "${root}" | sed "s|^${root}/||" | sort -u)"
    checked=$((checked + 1))
    if [[ "${got}" == "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s\n    want: %s\n    got:  %s\n' \
        "${label}" "${want//$'\n'/ }" "${got//$'\n'/ }" >&2
      fails=1
    fi
  }

  local mod="${tmp}/storage_member_directory.rs" sch="${tmp}/storage.rs" other="${tmp}/manager.rs"

  log "self-test: check 1 — no circle identifier reaches the table"

  rm -rf "${tmp:?}"/*.rs
  cat > "${sch}" <<'RS'
fn schema() { conn.execute_batch("
  CREATE TABLE IF NOT EXISTS member_directory (
      pubkey TEXT PRIMARY KEY,
      tier INTEGER NOT NULL
  );
"); }
RS
  _expect "a clean DDL passes" 0 check_no_circle_identifier "${tmp}"

  cat > "${sch}" <<'RS'
fn schema() { conn.execute_batch("
  CREATE TABLE IF NOT EXISTS member_directory (
      pubkey TEXT PRIMARY KEY,
      circle_id TEXT NOT NULL
  );
"); }
RS
  # Two rules fire on one chunk (DDL bare word + identifier token): that is the
  # designed overlap, not a miscount.
  _expect "a circle_id column FAILS" 2 check_no_circle_identifier "${tmp}"

  cat > "${sch}" <<'RS'
fn schema() { conn.execute_batch("
  CREATE TABLE IF NOT EXISTS member_directory (
      pubkey TEXT PRIMARY KEY,
      last_group TEXT NOT NULL
  );
"); }
RS
  _expect "a bare 'group' column FAILS" 1 check_no_circle_identifier "${tmp}"

  cat > "${sch}" <<'RS'
fn migrate() {
  if !done { conn.execute("ALTER TABLE member_directory ADD COLUMN nostr_group_id TEXT", []); }
}
RS
  _expect "an ALTER adding a group column FAILS (a fresh-open PRAGMA test never runs it)" 2 \
    check_no_circle_identifier "${tmp}"

  cat > "${sch}" <<'RS'
fn read() {
  conn.prepare("SELECT d.pubkey FROM member_directory d JOIN circles c ON c.id = d.origin");
}
RS
  _expect "a join against circles FAILS" 1 check_no_circle_identifier "${tmp}"

  cat > "${sch}" <<'RS'
// The table must never gain a circle_id / nostr_group_id column, and no
// statement may join it against circles or carry an mls_group_id.
fn schema() { conn.execute_batch("
  -- no circle_id here either, and no group column
  CREATE TABLE IF NOT EXISTS member_directory (
      pubkey TEXT PRIMARY KEY
  );
"); }
RS
  _expect "prose naming every forbidden token passes (comments are stripped, never grepped)" 0 \
    check_no_circle_identifier "${tmp}"

  log "self-test: check 2 — one writer, one declaration, no companion table"

  rm -rf "${tmp:?}"/*.rs
  cat > "${mod}" <<'RS'
fn sync() { conn.execute("INSERT INTO member_directory (pubkey) VALUES (?1)", p); }
RS
  cat > "${sch}" <<'RS'
fn schema() { conn.execute_batch("CREATE TABLE IF NOT EXISTS member_directory (pubkey TEXT);"); }
RS
  _expect "the module writing and the schema declaring passes" 0 \
    check_single_writer "${mod}" "${sch}" "${tmp}"

  cat > "${other}" <<'RS'
fn sneaky() { conn.execute("DELETE FROM member_directory WHERE pubkey = ?1", p); }
RS
  _expect "a second writer in another module FAILS" 1 check_single_writer "${mod}" "${sch}" "${tmp}"
  rm -f "${other}"

  cat > "${sch}" <<'RS'
fn schema() { conn.execute_batch("CREATE TABLE IF NOT EXISTS member_directory (pubkey TEXT);"); }
fn peek() { conn.prepare("SELECT pubkey FROM member_directory"); }
RS
  _expect "the schema file READING the table FAILS" 1 check_single_writer "${mod}" "${sch}" "${tmp}"

  cat > "${sch}" <<'RS'
fn schema() { conn.execute_batch("
  CREATE TABLE IF NOT EXISTS member_directory (pubkey TEXT);
  CREATE TABLE IF NOT EXISTS directory_circles (pubkey TEXT, circle TEXT);
"); }
RS
  _expect "a companion 'directory' table FAILS" 1 check_single_writer "${mod}" "${sch}" "${tmp}"

  log "self-test: check 3a — the purge and the wipe are wired with the API"

  rm -rf "${tmp:?}"/*.rs "${tmp:?}/dart"
  mkdir -p "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"
  : > "${tmp}/core/unrelated.rs"
  : > "${tmp}/ffi/api.rs"
  : > "${tmp}/dart/page.dart"
  cat > "${mod}" <<'RS'
pub fn sync_co_members() {}
pub fn ranked_directory_members() {}
pub fn delete_directory_member() {}
pub fn prune_expired_directory_members() {}
pub fn wipe_member_directory() {}
RS
  _expect "nothing wired yet passes (nothing is promised yet)" 0 \
    check_retention_is_scheduled "${mod}" "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"

  cat > "${tmp}/core/unrelated.rs" <<'RS'
fn tick() { storage.sync_co_members(&union, now); }
RS
  _expect "the API wired WITHOUT the purge or the wipe FAILS" 1 \
    check_retention_is_scheduled "${mod}" "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"

  cat > "${tmp}/core/unrelated.rs" <<'RS'
fn tick() {
  storage.sync_co_members(&union, now);
  storage.prune_expired_directory_members(now);
  storage.wipe_member_directory();
}
RS
  _expect "the API wired WITH both passes" 0 \
    check_retention_is_scheduled "${mod}" "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"

  cat > "${tmp}/core/unrelated.rs" <<'RS'
fn tick() { storage.sync_co_members(&union, now); }
RS
  cat > "${tmp}/dart/page.dart" <<'DART'
Future<void> tick() async {
  await core.syncCoMembers();
  await core.pruneExpiredDirectoryMembers();
  await core.wipeMemberDirectory();
}
DART
  _expect "companions satisfied from the Dart side pass (the FFI binding is lowerCamelCase)" 0 \
    check_retention_is_scheduled "${mod}" "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"

  cat > "${tmp}/dart/page.dart" <<'DART'
// We should call pruneExpiredDirectoryMembers and wipeMemberDirectory here.
Future<void> tick() async { await core.syncCoMembers(); }
DART
  _expect "a commented-out purge does not count as wired" 1 \
    check_retention_is_scheduled "${mod}" "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"

  # THE regression this arming rule shipped with: `view | grep -q` under
  # `set -o pipefail` SIGPIPEs the view and returns 141, so whether a reference
  # is seen depends on how far from EOF it sits. A hit early in a long file is
  # the failing shape, and the real tree's is at line 1300 of a 67 KB view —
  # this fixture reproduces that geometry rather than trusting a short file.
  # The Dart fixture is cleared first: leaving the previous one in place would
  # arm the rule through the OTHER code path and hide exactly what this pins.
  : > "${tmp}/dart/page.dart"
  cat > "${tmp}/core/unrelated.rs" <<'RS'
fn tick() { storage.sync_co_members(&union, now); }
RS
  # The filler must be CODE, and there must be enough of it that the view's
  # output cannot fit the pipe buffer — that is what makes the SIGPIPE
  # deterministic. Comment filler would be stripped to empty lines and shrink
  # the output back under the buffer, quietly restoring the vacuous pass.
  awk 'BEGIN { for (i = 0; i < 4000; i++) print "    let filler_" i " = 0_i64 + " i " ;" }' \
    >> "${tmp}/core/unrelated.rs"
  _expect "a reference near the TOP of a long file still arms the rule" 1 \
    check_retention_is_scheduled "${mod}" "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"

  # A module that declares no bulk wipe relies on logout deleting the
  # circles.db file set — a legitimate design, so the optional companion must
  # not be demanded. The purge stays required either way.
  cat > "${mod}" <<'RS'
pub fn sync_co_members() {}
pub fn ranked_directory_members() {}
pub fn delete_directory_member() {}
pub fn prune_expired_directory_members() {}
RS
  cat > "${tmp}/core/unrelated.rs" <<'RS'
fn tick() {
  storage.sync_co_members(&union, now);
  storage.prune_expired_directory_members(now);
}
RS
  _expect "a module with no wipe fn is not asked to wire one" 0 \
    check_retention_is_scheduled "${mod}" "${tmp}/core" "${tmp}/ffi" "${tmp}/dart"

  log "self-test: check 3b — expiry is a DELETE, not a read filter"

  rm -rf "${tmp:?}"/*.rs
  cat > "${mod}" <<'RS'
fn purge() { conn.execute("DELETE FROM member_directory WHERE purge_after < ?1", p); }
fn read()  { conn.prepare("SELECT pubkey, purge_after FROM member_directory ORDER BY tier"); }
RS
  _expect "a DELETE purge plus an unfiltered read passes" 0 check_purge_is_a_delete "${mod}"

  cat > "${mod}" <<'RS'
fn purge() { conn.execute("DELETE FROM member_directory WHERE purge_after < ?1", p); }
fn read()  { conn.prepare("SELECT pubkey FROM member_directory WHERE purge_after >= ?1"); }
RS
  _expect "a read-side purge_after filter FAILS even beside a real DELETE" 1 \
    check_purge_is_a_delete "${mod}"

  cat > "${mod}" <<'RS'
fn purge() { conn.execute("DELETE FROM member_directory WHERE purge_after < ?1", p); }
#[cfg(test)]
mod tests {
  fn raw() { conn.prepare("SELECT tier FROM member_directory WHERE purge_after > ?1"); }
}
RS
  _expect "the same filter inside #[cfg(test)] is not a violation" 0 check_purge_is_a_delete "${mod}"

  log "self-test: check 4 — no home outside the encrypted database"

  rm -rf "${tmp:?}"/*.rs
  cat > "${mod}" <<'RS'
fn wipe(&self) { let conn = self.conn().lock()?; conn.execute("DELETE FROM member_directory", []); }
RS
  _expect "connection-only Rust passes" 0 check_stays_in_sqlcipher_rust "${mod}"

  cat > "${mod}" <<'RS'
fn cache(&self) { std::fs::write("/tmp/directory.json", serde_json::to_string(&rows)?); }
RS
  _expect "a Rust sidecar file FAILS" 1 check_stays_in_sqlcipher_rust "${mod}"

  cat > "${mod}" <<'RS'
// Never mirror these rows with std::fs or a second Connection::open.
#[cfg(test)]
mod tests { fn t() { let _ = std::fs::remove_file(p); } }
RS
  _expect "std::fs in a comment and in #[cfg(test)] passes" 0 check_stays_in_sqlcipher_rust "${mod}"

  mkdir -p "${tmp}/dartsurface"
  cat > "${tmp}/dartsurface/member_directory_service.dart" <<'DART'
Future<MemberDirectory> load() async => MemberDirectory(await core.ranked());
DART
  _expect "an in-memory Dart service passes" 0 \
    check_stays_in_sqlcipher_dart "${tmp}/dartsurface/member_directory_service.dart"

  cat > "${tmp}/dartsurface/member_directory_service.dart" <<'DART'
Future<void> save(List<String> pubkeys) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList('haven.directory', pubkeys);
}
DART
  _expect "a Dart SharedPreferences write FAILS" 1 \
    check_stays_in_sqlcipher_dart "${tmp}/dartsurface/member_directory_service.dart"

  cat > "${tmp}/dartsurface/member_directory_service.dart" <<'DART'
// Never write this to SharedPreferences or a File( ) of our own.
Future<MemberDirectory> load() async => MemberDirectory(await core.ranked());
DART
  _expect "prose naming SharedPreferences passes" 0 \
    check_stays_in_sqlcipher_dart "${tmp}/dartsurface/member_directory_service.dart"

  log "self-test: check 4b discovery — the surface is more than the naming convention"

  local lib="${tmp}/lib"
  rm -rf "${lib}"
  mkdir -p "${lib}/src/providers" "${lib}/src/services" "${lib}/src/utils" \
           "${lib}/src/widgets/circles" "${lib}/src/pages/circles" "${lib}/src/rust"
  for f in "${DART_SURFACE_SEEDS[@]}"; do
    mkdir -p "$(dirname "${lib}/${f}")"
    printf 'class Seed {}\n' > "${lib}/${f}"
  done
  # Matches the convention, imports no seed.
  printf 'abstract class MemberDirectoryService {}\n' \
    > "${lib}/src/services/member_directory_service.dart"
  # Matches NOTHING by name; imports a seed. This is the shape the reviewer
  # found uncovered — create_circle_page.dart, add_member_page.dart.
  cat > "${lib}/src/pages/circles/create_circle_page.dart" <<'DART'
import 'package:haven/src/widgets/circles/member_picker.dart';
class CreateCirclePage extends StatelessWidget {}
DART
  # A relative import of a seed is caught too, though the analyzer bans them.
  cat > "${lib}/src/widgets/circles/circle_member_tile.dart" <<'DART'
import '../circles/member_avatar.dart';
class CircleMemberTile extends StatelessWidget {}
DART
  # The app-wide DI file imports the SERVICE INTERFACE, which is deliberately
  # not a seed: its other providers are none of the directory's business.
  cat > "${lib}/src/providers/service_providers.dart" <<'DART'
import 'package:haven/src/services/member_directory_service.dart';
final somethingElseProvider = Provider((ref) => SharedPreferences.getInstance());
DART
  # Generated Dart is excluded even though the binding names every symbol.
  cat > "${lib}/src/rust/api.dart" <<'DART'
import 'package:haven/src/utils/search_fold.dart';
DART

  _expect_files "the surface is convention + seeds + seed importers, and nothing generated" "${lib}" \
    "${DART_SURFACE_SEEDS[@]}" \
    src/services/member_directory_service.dart \
    src/pages/circles/create_circle_page.dart \
    src/widgets/circles/circle_member_tile.dart

  mapfile -t _surface < <(dart_surface "${lib}")
  _expect "a clean surface passes" 0 check_stays_in_sqlcipher_dart "${_surface[@]}"

  # THE gap this widening closed: a recent-searches cache written from a file
  # that carries no directory name in it. Under the convention-only scan this
  # was green.
  cat > "${lib}/src/pages/circles/create_circle_page.dart" <<'DART'
import 'package:haven/src/widgets/circles/member_picker.dart';
Future<void> _rememberPicks(List<String> pubkeys) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList('haven.recentPicks', pubkeys);
}
DART
  mapfile -t _surface < <(dart_surface "${lib}")
  _expect "a staged-pick cache in a file that carries no directory name FAILS" 1 \
    check_stays_in_sqlcipher_dart "${_surface[@]}"

  # And the counterpart: the DI file is out of scope by construction, so an
  # unrelated provider there does not red this guard (nor get blamed on the
  # directory). Its SharedPreferences line is still sitting in the fixture.
  _expect_files "the app-wide DI file is not pulled in by the service interface" "${lib}" \
    "${DART_SURFACE_SEEDS[@]}" \
    src/services/member_directory_service.dart \
    src/pages/circles/create_circle_page.dart \
    src/widgets/circles/circle_member_tile.dart

  mkdir -p "${tmp}/native"
  : > "${tmp}/native/Empty.kt"
  _expect "native code that never names the table passes" 0 check_stays_in_sqlcipher_native "${tmp}/native"
  cat > "${tmp}/native/Empty.kt" <<'KT'
val d = prefs.getStringSet("member_directory", emptySet())
KT
  _expect "native code naming the table FAILS" 1 check_stays_in_sqlcipher_native "${tmp}/native"

  if (( fails )); then
    misconfig "self-test failed — this guard cannot be trusted until it is fixed"
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

  preflight || exit 2

  log "Scanning statements naming member_directory for circle/group/MLS identifiers ..."
  check_no_circle_identifier "${CORE_SRC}" "${FFI_SRC}"

  log "Verifying the table has exactly one writer and no companion table ..."
  check_single_writer "${DIR_MODULE}" "${SCHEMA_FILE}" "${CORE_SRC}" "${FFI_SRC}"

  log "Verifying the retention purge and the wipe are wired wherever the directory is ..."
  check_retention_is_scheduled "${DIR_MODULE}" "${CORE_SRC}" "${FFI_SRC}" "${LIB_DIR}"

  log "Verifying expiry is a DELETE, never a read-side filter ..."
  check_purge_is_a_delete "${DIR_MODULE}"

  log "Verifying the directory has no home outside circles.db ..."
  check_stays_in_sqlcipher_rust "${DIR_MODULE}"
  mapfile -t dart_files < <(dart_surface "${LIB_DIR}")
  check_stays_in_sqlcipher_dart "${dart_files[@]}"
  check_stays_in_sqlcipher_native "${ANDROID_DIR}" "${IOS_DIR}"

  if (( VIOLATIONS > 0 )); then
    printf '\033[1;31m[%s] FAIL:\033[0m %d violation(s) — see above.\n' "${SCRIPT_NAME}" "${VIOLATIONS}" >&2
    exit 1
  fi
  log "OK: the member directory holds no circle identifier, is purged by DELETE, and lives only in circles.db."
  exit 0
}

main "$@"
