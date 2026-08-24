#!/usr/bin/env bash
# CI guard: the inner (MLS-tunnelled) location event kind is pinned to 25442,
# and no production Rust constructs an event at a kind another Marmot client
# already owns.
#
# ## Why this exists
#
# Haven's location update is an UNSIGNED Nostr rumor serialized into the MLS
# payload; it never reaches a relay as an event, but every member of the circle
# decrypts it — including members running a DIFFERENT Marmot client. The kind
# is therefore not a private detail: it is the dispatch token those clients
# render on. Haven shipped it at kind 9 until 2026-08-24, which is the kind
# MDK's own chat path constructs, so Haven's location JSON arrived in any
# Marmot chat client sharing the circle as a chat bubble full of coordinates.
#
# 25442 is drawn from the ephemeral band (20000-29999) and was verified
# unallocated in `nostr-protocol/registry-of-kinds`, the NIPs README, MDK and
# Haven.
#
# ## Why a guard and not just the constant
#
# `check_privacy_invariants.sh` rule 13 declares every event-kind construction
# TOKEN in production Rust, and the send site's token is now
# `Kind::Custom(KIND_LOCATION_UPDATE)` — a NAMED constant. Rule 13 keys on token
# identity, so it can prove that no NEW construction shape appeared and cannot
# see the constant's VALUE at all: re-pointing `KIND_LOCATION_UPDATE` at 9 leaves
# the token, the manifest row and rule 13 untouched. The two guards compose —
# rule 13 owns "no new token", this one owns "that token's number" — and neither
# is redundant with the other.
#
# ## The reserved set
#
# Kinds allocated by Marmot/MDK or by NIP-01 — which another client in the same
# circle renders, or which the protocol has already spoken for — plus one number
# held as margin beside them:
#
#   9              MDK's chat message — the collision this guard was written for
#   1210           the engine's own system rows (membership changes, renames),
#                  carried INSIDE 445 and projected onto every member's timeline
#   446-452        the Marmot band around the account identity proof (450)
#   1009, 1200     Marmot registry allocations: message edit, agent text stream
#   1201, 1202     read as "reserved for possible experimental" in Marmot's
#                  registry, but already live in MDK — both are `cgka-traits`
#                  constants and its timeline projection renders their rows, so
#                  "reserved, not allocated" understates them
#   1, 2, 5, 7     NIP-01/09/25 core kinds every Nostr client renders or acts on
#
# That last number is 1209, and it is NOT an allocation: it is in no Marmot
# registry and no MDK rev, and appears only in a prose comment in
# whitenoise-android. It is kept as margin beside 1210 — reserving a number
# nobody has claimed costs Haven nothing (25442 is nowhere near it) and hedges
# the possibility that the comment reflects real intent. Do not re-describe it
# as an allocation.
#
# Haven does publish kind 5 (the legacy-443 cutover retraction) — through
# `EventBuilder::delete`, which carries no number. What checks 4 and 5 ban is
# the BARE LITERAL, never the kind: the pinned nostr crate names these kinds
# (`Kind::EventDeletion`, `Kind::Metadata`, both already used in this tree), and
# a bare reserved number is either a mistake or a deliberate collision.
#
# ## What it enforces
#
#   1. `haven-core/src/nostr/event.rs` declares exactly one
#      `pub const KIND_LOCATION_UPDATE: u16 = <n>;`
#   2. `<n>` is 25442, AND `<n>` is not in the reserved set. The second is not
#      implied by the first for the only edit that matters: whoever re-pins the
#      constant and edits EXPECTED_KIND here in the same breath still gets a
#      loud, specific failure if the number they chose is reserved.
#   3. `haven-core/src/nostr/mls/manager.rs` — the only file that builds inner
#      application rumors — constructs `Kind::Custom(KIND_LOCATION_UPDATE)`, and
#      every kind it constructs is spelled as a NAMED constant. A bare literal
#      there routes around check 1; a computed kind (`Kind::Custom(k)`) puts the
#      number outside every static check in this repo. The rule is on the file,
#      not on `fn send_location`, because the construction legitimately lives in
#      a private helper the entry point delegates to.
#   4. No production Rust constructs a reserved kind from a bare number, in any
#      of `Kind::Custom(<n>)`, `Kind::from(<n>)` or `<n>_u16.into()`.
#   5. No production Rust constructs a reserved kind through a CONSTANT —
#      `Kind::Custom(<CONST>)` or `Kind::from(<CONST>)` where `<CONST>` is a kind
#      constant declared in this tree at a reserved value, which is how
#      `KIND_LOCATION_DATA: u16 = 9` would come back under a new name, invisible
#      to check 4 because it is no longer a literal.
#   6. `LEGACY_KIND_LOCATION_UPDATE` is gone from production Rust once the MDK
#      pin moves — see "The transitional window's expiry" below.
#
# Checks 3-5 read ONE construction stream, so the ways a construction can hide
# from a line-scoped grep are closed in one place rather than three:
# `Kind::from` is the pinned nostr crate's `impl From<u16> for Kind` — the same
# constructor as `Kind::Custom`, not an exotic helper; a typed literal (`9u16`,
# `9_u16`) and a digit-separated one (`1_210`) are normalized to their decimal
# value; and a construction rustfmt has split across lines is folded back onto
# the line it starts on before anything greps it.
#
# Check 5 bans CONSTRUCTING a reserved kind, not naming one. Haven deliberately
# keeps `LEGACY_KIND_LOCATION_UPDATE: u16 = 9` for the receive side, to keep a
# not-yet-updated circle member on the map through the cutover; it is compared
# against an inbound kind and never built.
#
# ## The transitional window's expiry (check 6)
#
# That legacy arm is transitional, and check 6 is what ends it — nothing else in
# the repository can. `haven/pubspec.yaml` reads `0.1.0+1` at every release tag,
# so no version number here moves, and a wall-clock sunset would turn CI red on a
# morning nobody chose. The MDK pin is the real boundary.
#
# The arm exists for the builds that can still share a group with this one:
# v0.1.11 and v0.1.12, which emit `Kind::Custom(9)` tagged `["t","location"]`.
# v0.1.10 and earlier pin pre-Dark-Matter `mdk-core` and cannot decrypt a current
# kind 445 at all, so they are off the map with or without the arm. The next MDK
# bump therefore moves every peer that can still interoperate onto a post-cutover
# build, and the arm becomes dead code whose only remaining effect is to widen
# what the receive gate accepts. So: while `haven-core/Cargo.toml` pins the CGKA
# crates at LEGACY_WINDOW_MDK_REV below, the arm may exist; the moment that rev
# changes, it must be gone — which makes the deletion an obligation CI states at
# exactly the commit that earns it, with nothing to remember and no date to rot.
#
# Production Rust means `haven-core/src` + `haven/rust_builder/src` with
# `#[cfg(test)]` module bodies brace-walked out and `frb_generated` excluded —
# deliberately the same view `check_privacy_invariants.sh` rule 13 takes, so the
# two guards cannot disagree about what ships. Test fixtures build decoy kinds
# on purpose and are not findings.
#
# Pure-grep gate (no Rust toolchain), belongs in the shared repo-guards job.
#
# Usage:
#   check_inner_location_kind.sh            # check the repo
#   check_inner_location_kind.sh --self-test
#
# Exit codes:
#   0  all checks pass
#   1  a violation (including "could not read" — a moved or renamed declaration
#      scans nothing, which is a guard failure, not a pass)
#   2  the guard itself is broken or misconfigured

set -Eeuo pipefail

SCRIPT_NAME="check_inner_location_kind"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

readonly EXPECTED_KIND=25442
readonly KIND_CONST="KIND_LOCATION_UPDATE"
readonly LEGACY_CONST="LEGACY_KIND_LOCATION_UPDATE"
readonly EVENT_RS="haven-core/src/nostr/event.rs"
readonly MANAGER_RS="haven-core/src/nostr/mls/manager.rs"
readonly CARGO_TOML="haven-core/Cargo.toml"
readonly PROD_DIRS=("haven-core/src" "haven/rust_builder/src")

# The CGKA rev the legacy receive arm's window is defined by (check 6). Bumping
# MDK is the event that ends the window; see "The transitional window's expiry".
readonly LEGACY_WINDOW_MDK_REV="e391adc133a9b60e420da7a0446f014a180ac8d2"

# Singletons and inclusive ranges; see "The reserved set" above.
readonly RESERVED_KINDS=(1 2 5 7 9 446-452 1009 1200-1202 1209 1210)

# `10#` on every operand: Rust accepts a leading zero in an integer literal and
# bash would read `010` as octal, which is a wrong answer rather than an error.
is_reserved() { # is_reserved <n>
  local n="$1" spec lo hi
  for spec in "${RESERVED_KINDS[@]}"; do
    if [[ "${spec}" == *-* ]]; then
      lo="${spec%%-*}"; hi="${spec##*-}"
      (( 10#${n} >= 10#${lo} && 10#${n} <= 10#${hi} )) && return 0
    elif (( 10#${n} == 10#${spec} )); then
      return 0
    fi
  done
  return 1
}

# An extended-regex alternation over every reserved number, so one grep pass
# covers the whole set. Built from RESERVED_KINDS rather than written out, or
# the two would drift and the list above would stop being the source of truth.
reserved_alternation() {
  local spec lo hi n out=""
  for spec in "${RESERVED_KINDS[@]}"; do
    if [[ "${spec}" == *-* ]]; then
      lo="${spec%%-*}"; hi="${spec##*-}"
      for (( n = lo; n <= hi; n++ )); do out+="${n}|"; done
    else
      out+="${spec}|"
    fi
  done
  printf '%s\n' "${out%|}"
}

# ---------------------------------------------------------------------------
# Production Rust, one file at a time: `#[cfg(test)]` module bodies removed and
# whole-line comments dropped, printed as `<line-no>:<text>`.
#
# The brace walk is lifted from `check_privacy_invariants.sh`'s kind extractor
# on purpose — a second, subtly different notion of "production" is a second
# guard that can be argued with.
# ---------------------------------------------------------------------------
prod_view() { # prod_view <file>
  awk '
    { L[NR] = $0 }
    END {
      depth = 0; intest = 0; pending = 0; testdepth = 0
      for (j = 1; j <= NR; j++) {
        t = L[j]
        if (!intest && t ~ /#\[[[:space:]]*cfg\(test\)/) pending = 1
        tmp = t; o = gsub(/[{]/, "", tmp)
        tmp = t; c = gsub(/[}]/, "", tmp)
        if (!intest && pending && o > 0 && t ~ /(^|[^A-Za-z0-9_])mod([^A-Za-z0-9_]|$)/) {
          intest = 1; testdepth = depth; pending = 0
        }
        skipline = intest
        depth += o - c
        if (intest && depth <= testdepth) intest = 0
        if (skipline) continue
        if (t ~ /^[[:space:]]*(\/\/|\*|\/\*)/) continue
        printf "%d:%s\n", j, t
      }
    }
  ' "$1"
}

prod_files() { # prod_files <root>
  local root="$1" d
  local -a dirs=()
  for d in "${PROD_DIRS[@]}"; do [[ -d "${root}/${d}" ]] && dirs+=("${root}/${d}"); done
  (( ${#dirs[@]} > 0 )) || return 0
  find "${dirs[@]}" -name '*.rs' 2>/dev/null | grep -v 'frb_generated' | sort
}

# A production view with every multi-line `Kind::Custom(` / `Kind::from(` folded
# onto the line it starts on. rustfmt splits a call the moment it exceeds the
# width, and `Kind::Custom(\n    9,\n)` is the same construction as
# `Kind::Custom(9)`: without this fold every extractor below is a line-scoped
# grep looking at half a token.
fold_constructions() { # fold_constructions < prod_view
  awk '
    function unbalanced(s,   t, o, c) {
      t = s; o = gsub(/\(/, "", t)
      t = s; c = gsub(/\)/, "", t)
      return o > c
    }
    { L[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        t = L[i]
        p = match(t, /Kind::(Custom|from)\(/)
        if (p > 0) {
          j = i
          # Bounded: an argument list that has not closed after eight lines is
          # not a kind construction this guard can reason about anyway.
          while (unbalanced(substr(t, p)) && j < NR && j - i < 8) {
            j++
            s = L[j]; sub(/^[0-9]+:/, "", s)
            t = t " " s
          }
        }
        print t
      }
    }
  '
}

# `<line-no>\t<arg>\t<text>` for every kind CONSTRUCTION in a file's production
# view — both `Kind::Custom(<arg>)` and `Kind::from(<arg>)`, which the pinned
# nostr crate makes interchangeable (`impl From<u16> for Kind`).
#
# `<arg>` is normalized so one number has one spelling: surrounding whitespace
# and rustfmt's trailing comma removed, then a numeric literal reduced to its
# decimal digits (`9`, `9u16`, `9_u16`, `1_210`). Anything else — a name, an
# expression, or the empty string when the guard cannot read the argument at all
# — is passed through verbatim for check 3 to reject.
kind_construction_sites() { # kind_construction_sites <file>
  prod_view "$1" | fold_constructions | awk '
    {
      line = $0; sub(/:.*/, "", line)
      text = $0; sub(/^[0-9]+:/, "", text)
      rest = $0
      while (match(rest, /(^|[^A-Za-z0-9_])Kind::(Custom|from)\([^)]*\)/)) {
        arg = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/^.*Kind::(Custom|from)\(/, "", arg)
        sub(/\)$/, "", arg)
        sub(/^[[:space:]]+/, "", arg); sub(/[[:space:]]+$/, "", arg)
        sub(/,$/, "", arg); sub(/[[:space:]]+$/, "", arg)
        if (arg ~ /^[0-9][0-9_]*(_?u16)?$/) { sub(/_?u16$/, "", arg); gsub(/_/, "", arg) }
        printf "%s\t%s\t%s\n", line, arg, text
      }
    }
  '
}

# Every distinct construction argument in a file, one per line.
kind_construction_args() { # kind_construction_args <file>
  kind_construction_sites "$1" | cut -f2 | sort -u
}

# `NAME=VALUE` for every kind-named `u16` constant declared in production, with
# `_` separators stripped from the value.
kind_constants() { # kind_constants <file>...
  local f
  for f in "$@"; do
    prod_view "${f}" \
      | sed -nE 's/.*(^|[^A-Za-z0-9_])const[[:space:]]+([A-Za-z0-9_]*KIND[A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*u16[[:space:]]*=[[:space:]]*([0-9_]+)[[:space:]]*;.*/\2=\3/p'
  done | awk -F= '{ v = $2; gsub(/_/, "", v); print $1 "=" v }' | sort -u
}

# ---------------------------------------------------------------------------
# run_checks <root>
#
# Every path is resolved under <root> so the self-test can drive the same code
# over fixture trees. Checks accumulate rather than short-circuit: one red run
# should report every violation, the way the repo-guards job does.
# ---------------------------------------------------------------------------
run_checks() {
  local root="$1" fail=0
  local event_rs="${root}/${EVENT_RS}" manager_rs="${root}/${MANAGER_RS}"

  # --- Checks 1 & 2: the constant is declared once, and holds 25442 ---------
  if [[ ! -f "${event_rs}" ]]; then
    fail_msg "[1] ${EVENT_RS} not found — the inner location kind cannot be read, so this \
guard is scanning nothing."
    return 1
  fi
  local decls
  decls="$(prod_view "${event_rs}" \
    | grep -cE "(^|[^A-Za-z0-9_])const[[:space:]]+${KIND_CONST}[[:space:]]*:[[:space:]]*u16[[:space:]]*=" \
    || true)"
  if (( decls == 0 )); then
    fail_msg "[1] no \`const ${KIND_CONST}: u16 = …;\` in ${EVENT_RS}. The inner location \
kind must be declared there as a named u16 constant; a renamed or relocated declaration \
leaves this guard, and rule 13's token declaration in the privacy manifest, describing \
nothing."
    fail=1
  elif (( decls > 1 )); then
    fail_msg "[1] ${KIND_CONST} is declared ${decls} times in ${EVENT_RS}. Which one the \
send path picks up is a matter of scope resolution, not of anybody's decision."
    fail=1
  fi

  local raw value=""
  raw="$(prod_view "${event_rs}" \
    | sed -nE "s/.*(^|[^A-Za-z0-9_])const[[:space:]]+${KIND_CONST}[[:space:]]*:[[:space:]]*u16[[:space:]]*=[[:space:]]*([0-9_]+)[[:space:]]*;.*/\2/p" \
    | head -1)"
  value="${raw//_/}"
  if [[ -z "${value}" ]]; then
    if (( decls > 0 )); then
      fail_msg "[1] ${KIND_CONST} is declared in ${EVENT_RS} but its value could not be \
read as a decimal literal — the declaration changed shape, so its number is unpinned."
      fail=1
    fi
  else
    if [[ "${value}" != "${EXPECTED_KIND}" ]]; then
      fail_msg "[2] ${KIND_CONST} is ${value}, not ${EXPECTED_KIND}. The inner location \
kind is the dispatch token every OTHER Marmot client in the circle renders on, so it is a \
wire decision, not a local one: moving it needs the new number checked against the kind \
registry, this guard re-pinned, and the privacy manifest's event_kinds row re-derived."
      fail=1
    fi
    if is_reserved "${value}"; then
      fail_msg "[2] ${KIND_CONST} is ${value}, which is RESERVED (see this guard's header). \
A location rumor at an allocated kind is rendered as that kind by every other client in the \
circle — at kind 9 (MDK's chat message) Haven's coordinates arrived in Marmot chat clients \
as chat bubbles, which is the defect this guard exists to keep fixed."
      fail=1
    fi
  fi

  # --- Check 3: the inner rumor is built from a NAMED constant --------------
  if [[ ! -f "${manager_rs}" ]]; then
    fail_msg "[3] ${MANAGER_RS} not found — the inner application send path cannot be \
checked, so this guard is scanning nothing."
    fail=1
  else
    local args arg
    args="$(kind_construction_args "${manager_rs}")"
    if [[ -z "${args}" ]]; then
      fail_msg "[3] ${MANAGER_RS} constructs no kind at all. The inner application rumor is \
built there and nowhere else; if it moved, this guard has stopped watching the send path."
      fail=1
    else
      # Rust's `non_upper_case_globals` lint (denied here with every other
      # warning) makes SHOUT_CASE a reliable constant/variable discriminator.
      while IFS= read -r arg; do
        if [[ ! "${arg}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
          fail_msg "[3] ${MANAGER_RS} builds a kind from \`${arg:-<unreadable>}\`. Every kind \
this file constructs must be a NAMED constant: a bare literal routes around the pinned \
${KIND_CONST}, and a computed kind puts the number outside every static check in this repo."
          fail=1
        fi
      done <<< "${args}"
      if ! grep -qxF "${KIND_CONST}" <<< "${args}"; then
        fail_msg "[3] ${MANAGER_RS} never builds a kind from ${KIND_CONST}. The constant is \
what the privacy manifest's event_kinds token names and what checks 1-2 pin; a send path \
that does not use it is pinned by nothing."
        fail=1
      fi
    fi
  fi

  # --- Checks 4-6: the whole production tree -------------------------------
  local -a files=()
  local f
  while IFS= read -r f; do [[ -n "${f}" ]] && files+=("${f}"); done < <(prod_files "${root}")
  if (( ${#files[@]} == 0 )); then
    fail_msg "[4] no production Rust found under $(printf '%s ' "${PROD_DIRS[@]}")— with \
nothing to scan, checks 4-6 would pass vacuously."
    return 1
  fi

  # A reserved kind reached through a CONSTANT is invisible to check 4, and is
  # exactly how the retired kind-9 location constant comes back under a new
  # name. Declaring one stays legal — `LEGACY_KIND_LOCATION_UPDATE` is compared
  # against an inbound kind so a mid-cutover peer stays on the map — but
  # BUILDING one does not.
  local reserved_consts="" pair name value
  while IFS= read -r pair; do
    [[ -n "${pair}" ]] || continue
    name="${pair%%=*}"; value="${pair##*=}"
    is_reserved "${value}" && reserved_consts+="${name}"$'\n'
  done < <(kind_constants "${files[@]}")

  # One pass over the construction stream feeds both checks, so a construction
  # shape either guard can read is a shape BOTH read.
  local hits="" const_hits="" line arg text
  for f in "${files[@]}"; do
    while IFS=$'\t' read -r line arg text; do
      [[ -n "${arg}" ]] || continue
      if [[ "${arg}" =~ ^[0-9]+$ ]]; then
        is_reserved "${arg}" && hits+="    * ${f#"${root}/"}:${line}  ${text}"$'\n'
      elif [[ -n "${reserved_consts}" ]] && grep -qxF "${arg}" <<< "${reserved_consts}"; then
        const_hits+="    * ${f#"${root}/"}:${line}  ${text}"$'\n'
      fi
    done < <(kind_construction_sites "${f}")
  done

  # `<n>_u16.into()` names no `Kind` at all, so it has no construction site to
  # normalize; it stays a literal-only grep.
  local alt
  alt="$(reserved_alternation)"
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      [[ -n "${line}" ]] && hits+="    * ${f#"${root}/"}:${line%%:*}  ${line#*:}"$'\n'
    done < <(prod_view "${f}" | grep -E "(^|[^A-Za-z0-9_.])(${alt})(u16|_u16)?\.into\(\)" || true)
  done

  if [[ -n "${hits}" ]]; then
    fail_msg "[4] production Rust constructs an event at a RESERVED kind, spelled as a bare \
number. Every allocated kind in that set is rendered or acted on by other clients; \
name the kind (the nostr crate's own variant, or a Haven constant) and pick a number nobody \
owns:"
    printf '%s' "${hits}" >&2
    fail=1
  fi

  if [[ -n "${const_hits}" ]]; then
    fail_msg "[5] production Rust builds an event at a RESERVED kind, reached through a \
constant ($(tr '\n' ' ' <<< "${reserved_consts}")). Naming a \
reserved number does not unreserve it, and a constant hides it from check 4:"
    printf '%s' "${const_hits}" >&2
    fail=1
  fi

  # --- Check 6: the legacy receive arm expires with the MDK pin -------------
  local cargo="${root}/${CARGO_TOML}"
  if [[ ! -f "${cargo}" ]]; then
    fail_msg "[6] ${CARGO_TOML} not found — the MDK pin is the whole of what bounds the \
legacy kind-9 receive window, so without it this check is scanning nothing."
    fail=1
  else
    local rev
    rev="$(sed -nE 's/^[[:space:]]*cgka-session[[:space:]]*=.*[[:space:]]rev[[:space:]]*=[[:space:]]*"([0-9a-f]+)".*/\1/p' \
      "${cargo}" | head -1)"
    if [[ -z "${rev}" ]]; then
      fail_msg "[6] no \`cgka-session … rev = \"…\"\` pin in ${CARGO_TOML}. That rev is what \
dates the legacy kind-9 receive arm; a dependency declaration this check cannot read leaves \
the arm with no expiry at all."
      fail=1
    elif [[ "${rev}" != "${LEGACY_WINDOW_MDK_REV}" ]]; then
      local legacy_hits=""
      for f in "${files[@]}"; do
        while IFS= read -r line; do
          [[ -n "${line}" ]] && legacy_hits+="    * ${f#"${root}/"}:${line%%:*}  ${line#*:}"$'\n'
        done < <(prod_view "${f}" \
          | grep -E "(^|[^A-Za-z0-9_])${LEGACY_CONST}([^A-Za-z0-9_]|$)" || true)
      done
      if [[ -n "${legacy_hits}" ]]; then
        fail_msg "[6] MDK moved (${rev:0:12}, was ${LEGACY_WINDOW_MDK_REV:0:12}) and \
${LEGACY_CONST} is still in production Rust. The kind-9 arm exists only for v0.1.11/v0.1.12 \
peers, which are pinned to the OLD rev: on the new one they can no longer decrypt a kind 445 \
at all, so the arm now only widens what the receive gate accepts. Delete the constant and \
its arm in this commit, then re-point LEGACY_WINDOW_MDK_REV if a NEW transitional window is \
genuinely opening:"
        printf '%s' "${legacy_hits}" >&2
        fail=1
      fi
    fi
  fi

  (( fail == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixture trees, no repo state, no toolchain.
#
# One fixture per violation class this guard claims to catch, plus the
# fail-closed "declaration moved" paths, plus the false-positive directions
# (a decoy kind inside `#[cfg(test)]`, and the unreserved literals 443/445/30443
# that production legitimately carries today).
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local good_event='pub const KIND_GROUP_MESSAGE: u16 = 445;
pub const KIND_LOCATION_UPDATE: u16 = 25442;'
  # The shipped shape: the FFI-reachable entry point delegates to a private
  # helper, and only the helper names a kind.
  local good_manager='    pub async fn send_location(
        &self,
        group_id: &GroupId,
        content: String,
    ) -> Result<SessionEffects> {
        self.create_message(group_id, location_rumor(self.identity_pubkey, content))
            .await
    }
}

fn location_rumor(sender: PublicKey, content: String) -> UnsignedEvent {
    nostr::EventBuilder::new(Kind::Custom(KIND_LOCATION_UPDATE), content).build(sender)
}'

  # The MDK pin every fixture gets unless it is testing check 6, in which case
  # it names `haven-core/Cargo.toml` as its extra file and overwrites this.
  local good_cargo="[dependencies]
cgka-session = { git = \"https://github.com/marmot-protocol/mdk\", rev = \"${LEGACY_WINDOW_MDK_REV}\" }"

  # The expected CHECK MARKER is asserted alongside the exit code, not just the
  # code: a fixture that goes red for an unrelated reason reports coverage of a
  # violation class the guard may no longer catch at all. Markers are this
  # guard's documented contract (see "What it enforces"), not incidental prose.
  _case() { # _case <label> <expect-rc> <marker|""> <event.rs> <manager.rs> [extra-rel] [extra-body]
    local label="$1" want="$2" marker="$3" event="$4" manager="$5" extra_rel="${6:-}" extra="${7:-}"
    local got=0 out
    checked=$(( checked + 1 ))
    local root="${tmp}/case"
    rm -rf "${root}"
    mkdir -p "${root}/haven-core/src/nostr/mls" "${root}/haven/rust_builder/src"
    printf '%s\n' "${event}" > "${root}/${EVENT_RS}"
    printf '%s\n' "${manager}" > "${root}/${MANAGER_RS}"
    printf '%s\n' "${good_cargo}" > "${root}/${CARGO_TOML}"
    [[ -n "${extra_rel}" ]] && printf '%s\n' "${extra}" > "${root}/${extra_rel}"
    out="$( ( run_checks "${root}" ) 2>&1 )" || got=$?
    if [[ "${got}" -ne "${want}" ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    elif [[ -n "${marker}" ]] && ! grep -qF "${marker}" <<< "${out}"; then
      printf '  \033[1;31mFAIL\033[0m %s (rc=%d, but no %s failure — it went red for the wrong reason)\n' \
        "${label}" "${got}" "${marker}" >&2
      fails=1
    else
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    fi
  }

  log "self-test: inner location kind"

  # (1) The shape this guard is written to accept.
  _case "the pinned kind with a constant-named send site passes" 0 "" \
    "${good_event}" "${good_manager}"

  # (2) THE CRITICAL FIXTURE — the constant re-pointed at the chat kind. Neither
  #     rule 13 nor any test in the tree can see this edit: the token, the
  #     manifest row and every call site are unchanged.
  _case "the constant re-pointed at kind 9 FAILS" 1 "[2]" \
    'pub const KIND_LOCATION_UPDATE: u16 = 9;' "${good_manager}"

  # (3) ...and at any other allocated kind, here MDK's in-445 system rows.
  _case "the constant re-pointed at kind 1210 FAILS" 1 "[2]" \
    'pub const KIND_LOCATION_UPDATE: u16 = 1210;' "${good_manager}"

  # (4) ...and inside the Marmot band around the identity proof.
  _case "the constant re-pointed into the 446-452 band FAILS" 1 "[2]" \
    'pub const KIND_LOCATION_UPDATE: u16 = 449;' "${good_manager}"

  # (5) An unallocated number that is simply not the pinned one: the wire
  #     decision was taken unilaterally, which is its own finding.
  _case "the constant moved to an unallocated but unpinned kind FAILS" 1 "[2]" \
    'pub const KIND_LOCATION_UPDATE: u16 = 25443;' "${good_manager}"

  # (6) The underscore-separated literal Rust permits must read as 25442, not
  #     fail as unparseable.
  _case "an underscore-separated 25_442 passes" 0 "" \
    'pub const KIND_LOCATION_UPDATE: u16 = 25_442;' "${good_manager}"

  # (7)-(8) Fail-closed: the declaration renamed away, or duplicated.
  _case "a renamed constant FAILS" 1 "[1]" \
    'pub const KIND_LOCATION_DATA_V2: u16 = 25442;' "${good_manager}"
  _case "a duplicated constant FAILS" 1 "[1]" \
    'pub const KIND_LOCATION_UPDATE: u16 = 25442;
pub const KIND_LOCATION_UPDATE: u16 = 25442;' "${good_manager}"

  # (9) The rumor build regresses to a bare literal — checks 1-2 still pass,
  #     which is exactly why check 3 is not redundant with them.
  _case "a bare literal at the rumor build FAILS" 1 "[3]" "${good_event}" \
    'fn location_rumor(sender: PublicKey, content: String) -> UnsignedEvent {
    nostr::EventBuilder::new(Kind::Custom(9), content).build(sender)
}'

  # (10) ...and to a computed kind, which puts the number outside every static
  #      check in this repo.
  _case "a computed kind at the rumor build FAILS" 1 "[3]" "${good_event}" \
    'fn location_rumor(sender: PublicKey, kind: u16, content: String) -> UnsignedEvent {
    nostr::EventBuilder::new(Kind::Custom(kind), content).build(sender)
}'

  # (11) The rumor build moved out of the file this guard watches: nothing to
  #      scan is not a pass. This is the fail-closed anchor that survives the
  #      entry point being renamed or split into a helper.
  _case "the rumor build leaving manager.rs FAILS" 1 "[3]" "${good_event}" \
    '    pub async fn send_location(&self, content: String) -> Result<SessionEffects> {
        self.create_message(group_id, build_location_rumor(self.pk, content)).await
    }'

  # (12) A DIFFERENT named constant at the build site: checks 1-2 pin
  #      KIND_LOCATION_UPDATE and nothing else, so a second constant would carry
  #      an unpinned number.
  _case "a different named constant at the rumor build FAILS" 1 "[3]" \
    "${good_event}
pub const KIND_SOMETHING_ELSE: u16 = 31337;" \
    'fn location_rumor(sender: PublicKey, content: String) -> UnsignedEvent {
    nostr::EventBuilder::new(Kind::Custom(KIND_SOMETHING_ELSE), content).build(sender)
}'

  # (13)-(14) Check 4 over the WHOLE production tree, not just the send path:
  #           a reserved literal in either construction shape, in a file this
  #           guard names nowhere.
  _case "a reserved literal elsewhere in production FAILS" 1 "[4]" \
    "${good_event}" "${good_manager}" \
    'haven/rust_builder/src/api.rs' \
    'pub fn probe() -> Filter { Filter::new().kind(Kind::Custom(1200)) }'
  _case "a reserved kind via .into() elsewhere in production FAILS" 1 "[4]" \
    "${good_event}" "${good_manager}" \
    'haven/rust_builder/src/api.rs' \
    'pub fn probe() -> Kind { 1009_u16.into() }'

  # (15) Check 5: the retired kind-9 constant reintroduced under a new name and
  #      BUILT. The literal is gone, so only check 5 can see it.
  _case "building a reserved kind through a constant FAILS" 1 "[5]" \
    "${good_event}
pub const KIND_LEGACY_LOCATION: u16 = 9;" \
    "${good_manager}
pub fn legacy() -> Kind { Kind::Custom(KIND_LEGACY_LOCATION) }"

  # (16)-(19) The four ways a construction hides from a LINE-SCOPED, EXACTLY-
  #           SPELLED grep. Each was verified to return rc=0 against the
  #           extractor these fixtures replaced, with `Kind::Custom(9)` in the
  #           same position as the passing control.

  # (16) The typed literal Rust permits everywhere a `u16` is expected. The
  #      header claimed this shape was modelled; it was modelled for `.into()`
  #      only.
  _case "a typed reserved literal (9u16) elsewhere in production FAILS" 1 "[4]" \
    "${good_event}" "${good_manager}" \
    'haven/rust_builder/src/api.rs' \
    'pub fn probe() -> Filter { Filter::new().kind(Kind::Custom(9u16)) }'

  # (17) `Kind::from` is `impl From<u16> for Kind` — the pinned nostr crate's
  #      primary constructor, and `Kind::Custom`'s equal in every way that
  #      matters here.
  _case "a reserved kind via Kind::from elsewhere in production FAILS" 1 "[4]" \
    "${good_event}" "${good_manager}" \
    'haven/rust_builder/src/api.rs' \
    'pub fn probe() -> Kind { Kind::from(9) }'

  # (18) The same constructor AT THE SEND SITE, with a decoy `Kind::Custom(
  #      KIND_LOCATION_UPDATE)` elsewhere in the file to satisfy check 3's
  #      presence rule. Only check 5 is left to catch it, and it must.
  _case "the send site building the legacy kind via Kind::from FAILS" 1 "[5]" \
    "${good_event}
pub const LEGACY_KIND_LOCATION_UPDATE: u16 = 9;" \
    'fn location_rumor(sender: PublicKey, content: String) -> UnsignedEvent {
    nostr::EventBuilder::new(Kind::from(LEGACY_KIND_LOCATION_UPDATE), content).build(sender)
}

fn unused_decoy() -> Kind { Kind::Custom(KIND_LOCATION_UPDATE) }'

  # (19) rustfmt splits the call the moment it exceeds the width, and every
  #      extractor here is a line-scoped grep. Same decoy, so a guard that reads
  #      only whole lines sees a compliant file.
  _case "a reserved literal split across lines at the send site FAILS" 1 "[4]" \
    "${good_event}" \
    'fn location_rumor(sender: PublicKey, content: String) -> UnsignedEvent {
    nostr::EventBuilder::new(
        Kind::Custom(
            9,
        ),
        content,
    )
    .build(sender)
}

fn unused_decoy() -> Kind { Kind::Custom(KIND_LOCATION_UPDATE) }'

  # (20)-(22) Check 6: the legacy receive arm has an expiry, and the MDK pin is
  #           it. Both directions, plus the fail-closed unreadable pin.

  # (20) THE OBLIGATION. MDK moved, so every peer that can still decrypt a
  #      kind 445 is post-cutover — and the kind-9 arm is now nothing but extra
  #      surface on the receive gate.
  _case "a bumped MDK rev with the legacy kind still in production FAILS" 1 "[6]" \
    "${good_event}
pub const LEGACY_KIND_LOCATION_UPDATE: u16 = 9;" \
    "${good_manager}" \
    "${CARGO_TOML}" \
    '[dependencies]
cgka-session = { git = "https://github.com/marmot-protocol/mdk", rev = "0123456789abcdef0123456789abcdef01234567" }'

  # (21) ...and the same bump with the arm deleted is exactly what this check
  #      asks for, so it must be silent.
  _case "a bumped MDK rev with the legacy kind deleted passes" 0 "" \
    "${good_event}" "${good_manager}" \
    "${CARGO_TOML}" \
    '[dependencies]
cgka-session = { git = "https://github.com/marmot-protocol/mdk", rev = "0123456789abcdef0123456789abcdef01234567" }'

  # (22) Fail-closed: a manifest this check cannot read leaves the arm with no
  #      expiry at all, which is the state finding 5 was filed about.
  _case "an unreadable MDK pin FAILS" 1 "[6]" \
    "${good_event}" "${good_manager}" \
    "${CARGO_TOML}" \
    '[dependencies]
nostr = "0.44"'

  # (23) FALSE-POSITIVE DIRECTION, and the shipped one: a reserved kind may be
  #      DECLARED and compared against an inbound kind — that is the receive-only
  #      cutover window LEGACY_KIND_LOCATION_UPDATE exists for. Only building it
  #      is a finding.
  _case "a reserved kind constant that is only compared, never built, passes" 0 "" \
    "${good_event}
pub const LEGACY_KIND_LOCATION_UPDATE: u16 = 9;" \
    "${good_manager}
fn is_location(kind: u64) -> bool { kind == u64::from(LEGACY_KIND_LOCATION_UPDATE) }"

  # (24) FALSE-POSITIVE DIRECTION: the kinds production legitimately builds by
  #      literal today (443, 445, 30443) are not reserved and must stay silent.
  _case "unreserved production literals pass" 0 "" \
    "${good_event}" "${good_manager}" \
    'haven/rust_builder/src/api.rs' \
    'pub const KEY_PACKAGE_KIND: u16 = 30443;
pub fn legacy() -> Kind { Kind::Custom(443) }
pub fn group() -> Kind { Kind::Custom(445) }'

  # (25) FALSE-POSITIVE DIRECTION: test fixtures build decoy kinds on purpose
  #      (giftwrap.rs builds Kind::Custom(1) to prove a non-wrap is rejected),
  #      and a `#[cfg(test)]` module is not something this app ships.
  _case "a decoy kind inside a #[cfg(test)] module passes" 0 "" \
    "${good_event}" "${good_manager}" \
    'haven-core/src/nostr/giftwrap.rs' \
    '#[cfg(test)]
mod tests {
    #[test]
    fn rejects_a_non_wrap() {
        let not_a_wrap = EventBuilder::new(Kind::Custom(1), "hello");
        assert!(unwrap(not_a_wrap).is_err());
    }
}'

  # (26) FALSE-POSITIVE DIRECTION: prose describing the retired kind must not be
  #      a finding — every guard header and doc comment in this tree names it.
  _case "a comment naming the retired kind passes" 0 "" \
    "${good_event}" "${good_manager}" \
    'haven-core/src/nostr/mod.rs' \
    '// The inner rumor was Kind::Custom(9) until 2026-08-24; see event.rs.
pub use event::KIND_LOCATION_UPDATE;'

  # (27) Fail-closed: a tree with no production Rust at all.
  local empty="${tmp}/empty"
  mkdir -p "${empty}"
  checked=$(( checked + 1 ))
  local got=0
  ( run_checks "${empty}" ) >/dev/null 2>&1 || got=$?
  if (( got == 1 )); then
    printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "a tree with no production Rust FAILS" "${got}"
  else
    printf '  \033[1;31mFAIL\033[0m %s (want rc=1, got rc=%d)\n' \
      "a tree with no production Rust FAILS" "${got}" >&2
    fails=1
  fi

  # (28) The reserved-set expansion is data this guard derives twice — once as
  #      a membership test, once as a regex. They must agree, or check 2 and
  #      checks 4/5 would enforce different sets.
  checked=$(( checked + 1 ))
  local alt drift=0 n
  alt="$(reserved_alternation)"
  for n in 1 2 5 7 9 446 449 452 1009 1200 1202 1209 1210; do
    is_reserved "${n}" || drift=1
    grep -qxE "(${alt})" <<< "${n}" || drift=1
  done
  for n in 0 3 4 6 8 10 445 453 1008 1199 1203 1208 1211 25442 30443; do
    is_reserved "${n}" && drift=1
    grep -qxE "(${alt})" <<< "${n}" && drift=1
  done
  if (( drift == 0 )); then
    printf '  \033[1;32mPASS\033[0m %s\n' "the membership test and the regex describe the same set"
  else
    printf '  \033[1;31mFAIL\033[0m %s\n' \
      "the membership test and the regex describe DIFFERENT sets" >&2
    fails=1
  fi

  if (( fails )); then
    fail_msg "self-test failed — this guard cannot be trusted until it is fixed"
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
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  if run_checks "${REPO_ROOT}"; then
    log "OK: the inner location kind is pinned at ${EXPECTED_KIND}, named at the send site, \
and no production Rust builds a reserved kind."
    exit 0
  fi
  fail_msg "the inner location kind is not what this repository claims (see above)."
  exit 1
}

main "$@"
