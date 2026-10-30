#!/usr/bin/env bash
# CI guard: the intent-draining engine advance is called only where a released
# user intent can be handled.
#
# ## Why this exists
#
# MDK v0.10.4's `AccountDeviceSession::advance_convergence` settles convergence
# AND drains the group's queued outbound intents
# (`cgka-engine/src/message_processor/mod.rs:185-253`); its inputs-only twin,
# `advance_convergence_inputs` (`cgka-session/src/lib.rs:1053-1080`), releases
# none. A receive plane that called the draining one could release a user's
# queued Invite or Remove with nobody to publish its Welcomes or record its
# obligation (Addendum A; C7 re-review F1-F4). Every receive plane that makes
# no commit therefore goes through `SessionManager::advance_for_receive`,
# whose step is the inputs-only advance. A plane that drives goes through
# `SessionManager::advance_for_drive`, whose step may drain because it records
# what the drain releases as a durable fanout before it releases the session
# lock: the released change then has its obligation and keeps its Welcomes.
#
# ## What it enforces
#
#   A1. In production Rust (`haven-core/src` + `haven/rust_builder/src`,
#       `#[cfg(test)]` modules brace-walked out, comments dropped,
#       `frb_generated` excluded), every `.advance_convergence(` or path-qualified
#       `::advance_convergence(` call sits in
#       one of the reviewed functions below:
#         nostr/mls/manager.rs  advance_convergence        the SessionManager wrapper
#         nostr/mls/manager.rs  advance_once_for_drive     `advance_for_drive`'s step
#         nostr/mls/manager.rs  stage_unrecorded_for_test  a test seam: what a peer's
#                                                          engine, or a killed process,
#                                                          stages with no record
#   A2. Each reviewed function still makes the call, so a rename cannot leave
#       the allowlist describing code that no longer exists.
#   A3. The drive's step hands its result to `self.staged(` in the same
#       function — the hold that drained is the hold that records — makes the
#       draining call exactly once, and is itself called from nowhere but
#       `advance_for_drive_while`, which makes it only while the mode its
#       caller decided on still holds with the engine in hand.
#   A4. `advance_for_drive_while` is what every plane that drives calls, so
#       its production callers are pinned too: the fold's own advance, the
#       catch-up plane's and the live plane's, each of which keeps the handles
#       it is given. A new plane that drained the queue and dropped them would
#       otherwise pass. Every MENTION of the name counts, not only the method
#       call: the path-qualified call
#       (`SessionManager::advance_for_drive_while(s, ..)`), the function taken
#       as a value, and a call inside a closure are each read as a call from
#       the function they sit in.
#   A5. No shipped call makes the full advance in a mode it has not just read
#       again. A pass decides on the full mode, then waits — for the engine,
#       for a deadline — and the foreground it decided in can end in that
#       wait; a commit staged behind it is one a paused plane made, which then
#       gets no first transmission and leaves its circle pending for the whole
#       background life. So:
#         a. `advance_for_drive` — the same advance with a mode that cannot
#            change — is a test's entry: its definition sits under
#            `#[cfg(any(test, feature = "test-utils"))]` and no production
#            function names it.
#         b. Inside `advance_for_drive_while` the engine is taken, `still` is
#            asked, and only then is the step made — in that order, each time:
#            the first advance and every later one of its loop.
#         d. The step itself (`advance_once_for_drive`) and the staging send
#            (`send_location_staging`) hand the circle's stranded input back
#            first — a wait of seconds — so each asks `still` AGAIN after
#            that hand-back, with no `.await` on the re-read's line or any
#            line between it and the act (the full advance; the send). The
#            re-read is a branch (`if still.holds()`) or a binding the
#            function reads again later — never `let _ =` or a bare call,
#            whose answer nothing uses. And every function of the file that
#            takes a `still: Still` and hands stranded input back is one of
#            the two: a third would be a hand-back nobody re-reads after.
#         c. `Still::always(` — a decision that is never asked again — is
#            written in production only with `&DriveMode::FinishOnly`, which
#            makes nothing, or in one of the reviewed functions below, none
#            of which reaches an advance:
#              nostr/mls/manager.rs  advance_for_drive     the test's entry (a.)
#              relay/fanout.rs       unsent_and_set_aside  ends a lost commit's Welcomes
#
# Pure-grep gate (no Rust toolchain), part of the shared repo-guards job.
#
# Usage:
#   check_advance_convergence_sites.sh            # check the repo
#   check_advance_convergence_sites.sh --self-test
#
# Exit codes: 0 pass; 1 violation (including a vacuous scan); 2 misuse.

set -Eeuo pipefail
LITERAL_FREE="$(cat "$(dirname "${BASH_SOURCE[0]}")/lib/literal_free.awk")"
readonly LITERAL_FREE

SCRIPT_NAME="check_advance_convergence_sites"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROD_DIRS=("haven-core/src" "haven/rust_builder/src")
readonly ALLOWED=(
  "haven-core/src/nostr/mls/manager.rs:advance_convergence"
  "haven-core/src/nostr/mls/manager.rs:advance_once_for_drive"
  "haven-core/src/nostr/mls/manager.rs:stage_unrecorded_for_test"
)
readonly DRIVE_STEP_FILE="haven-core/src/nostr/mls/manager.rs"
readonly DRIVE_STEP="advance_once_for_drive"
readonly DRIVE_CALLERS=(
  "haven-core/src/circle/manager.rs:advance_as"
  "haven-core/src/relay/catchup.rs:advance"
  "haven-core/src/relay/live_sync/processor.rs:advance"
)
# Where a name is not a call from outside: the two definitions, the first of
# which is the second with a mode that cannot change.
readonly DRIVE_DEFINITIONS=(
  "haven-core/src/nostr/mls/manager.rs:advance_for_drive"
  "haven-core/src/nostr/mls/manager.rs:advance_for_drive_while"
)
# A5c: where a decision that is never asked again may name the full mode.
readonly UNLEASHED=(
  "haven-core/src/nostr/mls/manager.rs:advance_for_drive"
  "haven-core/src/relay/fanout.rs:unsent_and_set_aside"
)
# A5d: the functions that hand back before they act, and the act of each.
readonly REREAD_STEPS=(
  'advance_once_for_drive|advance_convergence[(]'
  'send_location_staging|[.]send[(]'
  'departure_holds_a_send|away_hold[(]'
  'leave_group_staging|send_leave[(]'
  'process_event_staging|[.]ingest[(]'
  'repair_self_update_staging|send_self_update_now[(]'
  'post_join_self_update_staging|send_self_update_now[(]'
  'change_admin_policy_staging|send_admin_policy_now[(]'
)
readonly TEST_ONLY='#[cfg(any(test, feature = "test-utils"))]'
readonly SELF_TEST_FIXTURES=40

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }

# Production view of one file as `<line-no>:<text>` (lifted from
# check_key_package_wire_shape.sh on purpose).
prod_view() { # prod_view <file>
  awk "${LITERAL_FREE}"'
    { L[NR] = $0 }
    END {
      depth = 0; intest = 0; pending = 0; testdepth = 0
      for (j = 1; j <= NR; j++) {
        t = L[j]
        if (!intest && t ~ /#\[[[:space:]]*cfg\(test\)/) pending = 1
        lfree = literal_free(t); tmp = lfree; o = gsub(/[{]/, "", tmp)
        tmp = lfree; c = gsub(/[}]/, "", tmp)
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

# `<line-no><TAB><enclosing fn>` for every `.advance_convergence(` or
# `::advance_convergence(` call (method or path syntax) in a
# file's production view.
call_sites() { # call_sites <file>
  prod_view "$1" | awk '
    {
      n = index($0, ":"); num = substr($0, 1, n - 1); t = substr($0, n + 1)
      if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
        f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
      }
      if (t ~ /(\.|::)advance_convergence\(/) printf "%s\t%s\n", num, fn_name
    }
  '
}

# `<enclosing fn>` for every line of a file's production view matching <ere>.
fns_matching() { # fns_matching <file> <ere>
  prod_view "$1" | awk -v pat="$2" '
    {
      n = index($0, ":"); t = substr($0, n + 1)
      if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
        f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
      }
      if (t ~ pat) print fn_name
    }
  '
}

# A3: the drive's step records in the hold that drained, and has one caller.
check_drive_step() { # check_drive_step <root>
  local file="$1/${DRIVE_STEP_FILE}" fail=0 callers
  [[ -f "${file}" ]] || return 0
  if ! fns_matching "${file}" 'self[.]staged[(]' | grep -qx "${DRIVE_STEP}"; then
    fail_msg "[A3] ${DRIVE_STEP_FILE}: \`${DRIVE_STEP}\` no longer hands its advance to \
\`self.staged(\`: a change the drain releases would leave the session lock with no record."
    fail=1
  fi
  callers="$(fns_matching "${file}" "([.]|::)${DRIVE_STEP}[(]" | sort -u | tr '\n' ' ')"
  if [[ "${callers}" != "advance_for_drive_while " ]]; then
    fail_msg "[A3] ${DRIVE_STEP_FILE}: \`${DRIVE_STEP}\` is called from [${callers}], \
expected only \`advance_for_drive_while\`."
    fail=1
  fi
  local drains
  drains="$(call_sites "${file}" | awk -F'\t' -v fn="${DRIVE_STEP}" '$2 == fn' | wc -l)"
  if (( drains != 1 )); then
    fail_msg "[A3] ${DRIVE_STEP_FILE}: \`${DRIVE_STEP}\` makes the draining advance ${drains} \
time(s), expected exactly one: a second one's result would not be the one recorded."
    fail=1
  fi
  return "${fail}"
}

# A4: who may call the drive advance. A5a: nobody the unleashed one.
check_drive_callers() { # check_drive_callers <root> <file>...
  local root="$1" fail=0 f rel fn entry
  shift
  for f in "$@"; do
    rel="${f#"${root}/"}"
    while IFS= read -r fn; do
      [[ -n "${fn}" ]] || continue
      entry="${rel}:${fn}"
      [[ " ${DRIVE_DEFINITIONS[*]} " == *" ${entry} "* ]] && continue
      if [[ " ${DRIVE_CALLERS[*]} " != *" ${entry} "* ]]; then
        fail_msg "[A4] ${rel} (fn ${fn}) names \`advance_for_drive_while\`, which may drain \
the user's queue: only the fold's advance, the catch-up plane's and the live plane's are \
reviewed to keep the handles it returns."
        fail=1
      fi
    done < <(fns_matching "${f}" '(^|[^A-Za-z0-9_])advance_for_drive_while([^A-Za-z0-9_]|$)' | sort -u)
    while IFS= read -r fn; do
      [[ -n "${fn}" ]] || continue
      [[ "${rel}:${fn}" == "${DRIVE_DEFINITIONS[0]}" ]] && continue
      fail_msg "[A5a] ${rel} (fn ${fn}) names \`advance_for_drive\`: the full advance in a \
mode nothing asks again. A shipped call makes \`advance_for_drive_while\` with the mode \
source it decided on."
      fail=1
    done < <(fns_matching "${f}" '(^|[^A-Za-z0-9_])advance_for_drive([^A-Za-z0-9_]|$)' | sort -u)
  done
  return "${fail}"
}

# A5: the full advance is made only in a mode read again with the engine held.
check_leash() { # check_leash <root> <file>...
  local root="$1" fail=0 f rel fn entry line order file
  shift
  file="${root}/${DRIVE_STEP_FILE}"
  if [[ -f "${file}" ]]; then
    if ! grep -B1 -F 'pub async fn advance_for_drive(' "${file}" | grep -qF "${TEST_ONLY}"; then
      fail_msg "[A5a] ${DRIVE_STEP_FILE}: \`advance_for_drive\` is not defined directly under \
\`${TEST_ONLY}\`: the unleashed full advance would ship."
      fail=1
    fi
    order="$(prod_view "${file}" | awk '
      {
        n = index($0, ":"); t = substr($0, n + 1)
        if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
          f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
        }
        if (fn_name != "advance_for_drive_while") next
        if (t ~ /self[.]engine[(][)]/) printf "E"
        if (t ~ /still[.]holds[(][)]/) printf "H"
        if (t ~ /advance_once_for_drive[(]/) printf "S"
      }')"
    if [[ ! "${order}" =~ ^(EHS)+$ ]]; then
      fail_msg "[A5b] ${DRIVE_STEP_FILE}: inside \`advance_for_drive_while\` the engine, the \
re-read of \`still\` and the step come in the order [${order}], expected (engine, \
still.holds(), step) each time: an advance of its loop would be made in a mode nobody asked \
again."
      fail=1
    fi
  fi
  local step act verdict
  if [[ -f "${file}" ]]; then
    for entry in "${REREAD_STEPS[@]}"; do
      step="${entry%%|*}"; act="${entry#*|}"
      verdict="$(prod_view "${file}" | awk -v step="${step}" -v act="${act}" '
        {
          n = index($0, ":"); t = substr($0, n + 1)
          if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
            f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
          }
          if (fn_name != step) next
          found = 1
          if (t ~ /hand_back_stranded[(]/) { b = NR; h = 0; a = 0; w = 0; bound = ""; used = 0; next }
          if (b && !a && t ~ /still[.]holds[(][)]/) {
            h = NR; w = (t ~ /[.]await/) ? 1 : 0; bound = ""; used = 0
            if (match(t, /let [a-z][a-z_0-9]* = (if !?)?still[.]holds[(][)]/)) {
              bound = substr(t, RSTART + 4, RLENGTH - 4); sub(/ .*/, "", bound)
            } else if (t ~ /(^|[^A-Za-z0-9_])if !?still[.]holds[(][)]/) {
              used = 1
            }
            next
          }
          if (h && bound != "" && t ~ ("(^|[^A-Za-z0-9_])" bound "([^A-Za-z0-9_]|$)")) used = 1
          if (b && h && !a && t ~ act) { a = NR; next }
          if (b && h && !a && t ~ /[.]await/) w++
        }
        END {
          if (!found) print "absent"
          else if (!b || !h || !a) print "unasked"
          else if (w) print "awaited"
          else if (!used) print "unread"
          else print "ok"
        }')"
      if [[ "${verdict}" != ok ]]; then
        fail_msg "[A5d] ${DRIVE_STEP_FILE}: \`${step}\` (${verdict}) does not ask \`still\` again \
after its hand-back with nothing awaited before its act: a foreground that ended while the \
circle's stranded input was handed back would still make it."
        fail=1
      fi
    done
    local covered
    while IFS= read -r fn; do
      [[ -n "${fn}" ]] || continue
      covered=0
      for entry in "${REREAD_STEPS[@]}"; do
        [[ "${entry%%|*}" == "${fn}" ]] && covered=1
      done
      if (( ! covered )); then
        fail_msg "[A5d] ${DRIVE_STEP_FILE}: \`${fn}\` takes a \`still\` or a mode and hands \
stranded input back, and is not one of the functions this gate holds to a re-read after that \
hand-back."
        fail=1
      fi
    done < <(prod_view "${file}" | awk '
      {
        n = index($0, ":"); t = substr($0, n + 1)
        if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
          f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
        }
        # A mode taken as a value is a decision made before the hand-back
        # just as a `still` is, and nothing can ask it again.
        if (t ~ /still: Still/ || t ~ /mode: DriveMode/) takes[fn_name] = 1
        if (t ~ /hand_back_stranded[(]/) hands[fn_name] = 1
      }
      END { for (f in takes) if (hands[f]) print f }')
  fi
  local -A seen=()
  for f in "$@"; do
    rel="${f#"${root}/"}"
    # A bare mode is its own source: `Still::new(&DriveMode::Full, ..)` is
    # `Still::always` by another spelling; so is a mode held in a variable or
    # a parameter, checked below.
    while IFS= read -r fn; do
      [[ -n "${fn}" ]] || continue
      fail_msg "[A5c] ${rel} (fn ${fn}) builds a \`Still\` whose source is the literal full \
mode: a decision nothing asks again. Pass the mode source the call reads."
      fail=1
    done < <(prod_view "${f}" | awk '
      {
        n = index($0, ":"); t = substr($0, n + 1)
        if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
          f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
        }
        literal = (t ~ /Still::new[(][[:space:]]*&[A-Za-z_:]*DriveMode::Full/) \
          || (opened && t ~ /^[[:space:]]*&[A-Za-z_:]*DriveMode::Full/)
        if (literal) print fn_name
        opened = (t ~ /Still::new[(][[:space:]]*$/)
      }' | sort -u)
    # A `Still` whose source is a mode held in a variable, a parameter or a
    # field — `let full = DriveMode::Full`, `mode: DriveMode`, `let m =
    # x.mode()`, `let m = if … { DriveMode::Full } …`, a `let` over several
    # lines, `self.mode` of a field typed `DriveMode` — never changes either.
    # A test-only seam may build one.
    while IFS= read -r fn; do
      [[ -n "${fn}" ]] || continue
      fail_msg "[A5c] ${rel} (fn ${fn}) builds a \`Still\` whose source is a mode held in a \
variable: a decision nothing asks again. Pass the mode source the call reads."
      fail=1
    done < <(prod_view "${f}" | awk -v testonly="${TEST_ONLY}" '
      {
        n = index($0, ":"); t = substr($0, n + 1)
        if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
          f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
          split("", held); insig = 1; seam = (index(prev, testonly) > 0)
        }
        if (insig) {
          rest = t
          while (match(rest, /[a-z_][a-z_0-9]*: DriveMode/)) {
            v = substr(rest, RSTART, RLENGTH); sub(/:.*/, "", v); held[v] = 1
            rest = substr(rest, RSTART + RLENGTH)
          }
          if (t ~ /[{][[:space:]]*$/) insig = 0
        } else if (match(t, /^[[:space:]]*(pub(\([a-z]+\))? )?[a-z_][a-z_0-9]*: DriveMode,[[:space:]]*$/)) {
          v = t; sub(/^[[:space:]]*(pub(\([a-z]+\))? )?/, "", v); sub(/:.*/, "", v)
          fields[in_struct SUBSEP v] = 1
        }
        # Which struct a field line belongs to, and which type the functions
        # of an impl block take `self` of: a field is of that struct alone.
        if (match(t, /(^|[^A-Za-z0-9_])struct [A-Z][A-Za-z0-9_]*/)) {
          in_struct = substr(t, RSTART, RLENGTH); sub(/^.*struct /, "", in_struct)
        }
        if (t ~ /^[[:space:]]*impl[<[:space:]]/) {
          ty = t; sub(/^[[:space:]]*impl/, "", ty)
          while (ty ~ /^[[:space:]]*</) { sub(/^[[:space:]]*<[^<>]*>/, "", ty) }
          if (ty ~ / for /) sub(/^.* for /, "", ty)
          sub(/^[[:space:]]*/, "", ty); sub(/[^A-Za-z0-9_].*$/, "", ty); in_impl = ty
        }
        valued = "DriveMode::|[.](mode|decided)[(][)]"
        if (match(t, /let (mut )?[a-z_][a-z_0-9]*(: DriveMode)? =([[:space:]]|$)/)) {
          v = substr(t, RSTART, RLENGTH); sub(/^let (mut )?/, "", v); sub(/[: =].*/, "", v)
          pending = ""
          if (t ~ /: DriveMode = / || t ~ /= DriveMode::/ \
            || t ~ /[.](mode|decided)[(][)];[[:space:]]*$/) held[v] = 1
          else if (t ~ /= if / || t !~ /;[[:space:]]*$/) {
            if (t ~ valued) held[v] = 1
            if (t !~ /;[[:space:]]*$/) pending = v
          }
        } else if (pending != "") {
          if (t ~ valued) held[pending] = 1
          if (t ~ /;[[:space:]]*$/) pending = ""
        }
        src = ""
        if (match(t, /Still::new[(][[:space:]]*&?(self[.])?[a-z_][a-z_0-9]*[[:space:]]*[,)]/)) {
          src = substr(t, RSTART, RLENGTH)
        } else if (opened && match(t, /^[[:space:]]*&?(self[.])?[a-z_][a-z_0-9]*[[:space:]]*[,)]/)) {
          src = substr(t, RSTART, RLENGTH)
        }
        if (src != "") {
          sub(/^.*[(]/, "", src); gsub(/[[:space:]&,)]/, "", src)
          if (src ~ /^self[.]/) {
            sub(/^self[.]/, "", src)
            if (((in_impl SUBSEP src) in fields) && !seam) print fn_name
          } else if ((src in held) && !seam) print fn_name
        }
        opened = (t ~ /Still::new[(][[:space:]]*$/)
        if (t !~ /^[[:space:]]*$/) prev = t
      }' | sort -u)
    while IFS=$'\t' read -r fn line; do
      [[ -n "${fn}" ]] || continue
      entry="${rel}:${fn}"
      if [[ " ${UNLEASHED[*]} " == *" ${entry} "* ]]; then
        seen["${entry}"]=1
      elif [[ "${line}" != *'Still::always(&DriveMode::FinishOnly)'* ]]; then
        fail_msg "[A5c] ${rel} (fn ${fn}) writes \`Still::always(\` with something other than \
\`&DriveMode::FinishOnly\`: a full mode decided once and never asked again. Build the \
\`Still\` from the mode source the call reads (\`Still::new(source, decided)\`)."
        fail=1
      fi
    done < <(prod_view "${f}" | awk '
      {
        n = index($0, ":"); t = substr($0, n + 1)
        if (match(t, /(^|[^A-Za-z0-9_])fn [a-z_0-9]+/)) {
          f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f); fn_name = f
        }
        if (t ~ /Still::always[(]/) printf "%s\t%s\n", fn_name, t
      }')
  done
  for entry in "${UNLEASHED[@]}"; do
    [[ -f "${root}/${entry%%:*}" ]] || continue
    if [[ -z "${seen[${entry}]:-}" ]]; then
      fail_msg "[A5c] ${entry} no longer writes \`Still::always(\`: update the reviewed list."
      fail=1
    fi
  done
  return "${fail}"
}

# The repository's api.rs, walked, still reaches its live-sync bridge near the
# end of its production code: a brace inside a literal once cut the walk short
# at about line 11282, and everything after was silently out of this guard's
# reach. Checked on the real tree only; the fixtures test the walk itself.
view_reaches_late_api_line() {
  if [[ "$(prod_view "${REPO_ROOT}/haven/rust_builder/src/api.rs")" != *"fn live_event_to_ffi("* ]]; then
    fail_msg "[view] the production view of api.rs ends before its live-sync bridge \
(fn live_event_to_ffi): the brace walk was cut short, or the function was renamed."
    return 1
  fi
}

run_checks() { # run_checks <root>
  local root="$1" fail=0 f rel line fn entry d
  local -a files=() dirs=()
  for d in "${PROD_DIRS[@]}"; do [[ -d "${root}/${d}" ]] && dirs+=("${root}/${d}"); done
  if (( ${#dirs[@]} > 0 )); then
    mapfile -t files < <(find "${dirs[@]}" -name '*.rs' | grep -v frb_generated | sort)
  fi
  if (( ${#files[@]} == 0 )); then
    fail_msg "[A1] no production Rust found: the scan would pass vacuously."
    return 1
  fi
  local -A seen=()
  for f in "${files[@]}"; do
    rel="${f#"${root}/"}"
    while IFS=$'\t' read -r line fn; do
      [[ -n "${line}" ]] || continue
      entry="${rel}:${fn}"
      if [[ " ${ALLOWED[*]} " == *" ${entry} "* ]]; then
        seen["${entry}"]=1
      else
        fail_msg "[A1] ${rel}:${line} (fn ${fn:-?}) calls the intent-draining \
\`advance_convergence\`. A receive plane must use \`SessionManager::advance_for_receive\`, \
or a queued user intent is released with nobody to publish it."
        fail=1
      fi
    done < <(call_sites "${f}")
  done
  for entry in "${ALLOWED[@]}"; do
    if [[ -z "${seen[${entry}]:-}" ]]; then
      fail_msg "[A2] ${entry} no longer calls \`.advance_convergence(\`: update the reviewed list."
      fail=1
    fi
  done
  check_drive_step "${root}" || fail=1
  check_drive_callers "${root}" "${files[@]}" || fail=1
  check_leash "${root}" "${files[@]}" || fail=1
  (( fail == 0 )) || return 1
  log "OK: every intent-draining advance in production Rust is one of the ${#ALLOWED[@]} reviewed sites."
}

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local reviewed
  local receive_sites drive_site
  receive_sites='pub async fn advance_convergence(&self, g: &G) { session.advance_convergence(g).await }
pub async fn stage_unrecorded_for_test(&self, g: &G) { session.advance_convergence(g).await }'
  local drive_entries test_entry leashed
  test_entry='#[cfg(any(test, feature = "test-utils"))]
pub async fn advance_for_drive(&self, g: &G) {
    self.advance_for_drive_while(g, Still::always(&DriveMode::Full)).await
}'
  leashed='pub(crate) async fn advance_for_drive_while(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    if !still.holds() { return self.settle(g).await; }
    let mut all = self.advance_once_for_drive(&mut s, g).await?;
    loop {
        let Ok(mut s) = self.engine().await else { break };
        if !still.holds() || !due(&mut s) { break; }
        all.extend(self
            .advance_once_for_drive(&mut s, g)
            .await);
    }
}'
  local send_site
  send_site='async fn send_location_staging(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    let sent = s.send(intent).await;
    self.staged(&mut s, sent, mode).await
}'
  local reread_sites
  reread_sites='pub(crate) async fn departure_holds_a_send(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    if self.away_hold(&s, g, mode).is_some() { return held; }
}
pub(crate) async fn leave_group_staging(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    let left = Self::send_leave(&mut s, g).await;
    self.stage_commits(&mut s, left, mode).await
}
pub(crate) async fn process_event_staging(&self, e: &E, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    let taken = Box::pin(s.ingest(msg)).await;
    self.stage_commits(&mut s, taken, mode).await
}
pub(crate) async fn repair_self_update_staging(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    let sent = self.send_self_update_now(&mut s, g).await;
    self.staged(&mut s, sent, mode).await
}
pub(crate) async fn post_join_self_update_staging(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    let sent = self.send_self_update_now(&mut s, g).await;
    self.staged(&mut s, sent, mode).await
}
pub(crate) async fn change_admin_policy_staging(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    let sent = self.send_admin_policy_now(&mut s, g, data).await;
    self.staged(&mut s, sent, mode).await
}'
  drive_entries="${test_entry}
${leashed}
${send_site}
${reread_sites}"
  drive_site="${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  reviewed="${receive_sites}
${drive_site}"
  # _case <label> <want-rc> <extra circle/manager.rs body>
  _case() {
    local label="$1" want="$2" circle="$3" t got=0
    checked=$(( checked + 1 ))
    t="${tmp}/case${checked}"
    mkdir -p "${t}/haven-core/src/nostr/mls" "${t}/haven-core/src/circle"
    printf '%s\n' "${reviewed}" >"${t}/haven-core/src/nostr/mls/manager.rs"
    printf '%s\n' "${circle}" >"${t}/haven-core/src/circle/manager.rs"
    ( run_checks "${t}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }
  echo "${SCRIPT_NAME}.sh --self-test"
  _case "the reviewed sites pass" 0 \
'async fn repair_deferred_send_staging(&self) { self.serve_deadlines(g).await }'
  _case "a receive plane calling the draining advance FAILS" 1 \
'async fn repair_deferred_send_staging(&self) { self.serve_deadlines(g).await }
async fn drain_convergence(&self) { self.session.advance_convergence(g).await }'
  _case "a path-qualified call from a receive plane FAILS" 1 \
'async fn repair_deferred_send_staging(&self) { self.serve_deadlines(g).await }
async fn drain_convergence(&self) { AccountDeviceSession::advance_convergence(&mut s, g).await }'
  _case "the inputs-only advance is not the draining one" 0 \
'async fn repair_deferred_send_staging(&self) { self.serve_deadlines(g).await }
async fn drain_convergence(&self) { self.session.advance_convergence_inputs(g).await }'
  _case "a call inside #[cfg(test)] is not production" 0 \
'async fn repair_deferred_send_staging(&self) { self.serve_deadlines(g).await }
#[cfg(test)]
mod tests {
    async fn t() { m.advance_convergence(g).await }
}'
  local kept_reviewed="${reviewed}"
  reviewed="${reviewed/stage_unrecorded_for_test(&self, g: &G) \{ session.advance_convergence/stage_unrecorded_for_test(&self, g: \&G) \{ session.advance_for_receive}"
  _case "a reviewed site that no longer calls it FAILS" 1 \
'async fn repair_deferred_send_staging(&self) { self.serve_deadlines(g).await }'
  reviewed="${kept_reviewed}"
  local ok_circle='async fn repair_deferred_send_staging(&self) { self.serve_deadlines(g).await }'
  reviewed="${receive_sites}
${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    if holds { s.advance_convergence(g).await } else { s.settle(g).await }
}"
  _case "a drive step that does not record in its hold FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let advanced = s.advance_convergence(g).await;
    self.staged(s, advanced).await
}"
  _case "a drive step that does not ask the mode again after its hand-back FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let before = self.roster(s, g).await;
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  _case "an await between the re-read and the full advance FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${test_entry}
${leashed}
async fn send_location_staging(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let mode = if still.holds() { still.decided() } else { DriveMode::FinishOnly };
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    let sent = s.send(intent).await;
    self.staged(&mut s, sent, mode).await
}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  _case "a send made in a mode read before its hand-back FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_site}
pub async fn advance_for_receive(&self, g: &G) {
    self.advance_once_for_drive(s, g).await
}"
  _case "a drive step called from a second function FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_site}
// self.advance_once_for_drive(s, g) is the only caller"
  _case "a mention of the drive step in a comment is not a call" 0 "${ok_circle}"
  reviewed="${receive_sites}
${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let _ = s.advance_convergence(g).await;
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  _case "a second draining advance inside the drive step FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_site}"
  local ok_fold='async fn advance_as(&self) { self.session.advance_for_drive_while(g, now, still).await }'
  _case "the fold's leashed advance passes" 0 \
"${ok_circle}
${ok_fold}"
  _case "the unleashed drive advance called from a reviewed plane FAILS" 1 \
"${ok_circle}
async fn advance_as(&self) { self.session.advance_for_drive(g, now).await }"
  _case "the leashed drive advance called from an unreviewed function FAILS" 1 \
"${ok_circle}
${ok_fold}
async fn poll_once(&self) { let _ = self.session.advance_for_drive_while(g, now, still).await; }"
  _case "a path-qualified drive advance from an unreviewed function FAILS" 1 \
"${ok_circle}
${ok_fold}
async fn poll_once(&self) { let _ = SessionManager::advance_for_drive_while(&self.session, g, now, s).await; }"
  _case "the drive advance taken as a value in an unreviewed function FAILS" 1 \
"${ok_circle}
${ok_fold}
fn poll_once(&self) -> impl Fn() { run(SessionManager::advance_for_drive_while) }"
  _case "a drive advance inside a closure of an unreviewed function FAILS" 1 \
"${ok_circle}
${ok_fold}
async fn poll_once(&self) {
    let step = |g| async move { session
        .advance_for_drive_while(g, now, still)
        .await };
    step(g).await;
}"
  _case "a full mode decided once and never asked again FAILS" 1 \
"${ok_circle}
async fn stage_due_eviction(&self) { self.fold(Still::always(&DriveMode::Full)).await }"
  _case "an unleashed mode held in a variable FAILS" 1 \
"${ok_circle}
async fn stage_due_eviction(&self) { let mode = DriveMode::Full; self.fold(Still::always(&mode)).await }"
  _case "a decision that makes nothing needs no leash" 0 \
"${ok_circle}
async fn finish(&self) { self.fold(Still::always(&DriveMode::FinishOnly)).await }"
  _case "a full mode passed as its own source FAILS" 1 \
"${ok_circle}
async fn stage_due_eviction(&self) {
    self.fold(Still::new(
        &DriveMode::Full,
        DriveMode::Full,
    )).await
}"
  reviewed="${receive_sites}
${test_entry}
pub(crate) async fn advance_for_drive_while(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    if !still.holds() { return self.settle(g).await; }
    let mut all = self.advance_once_for_drive(&mut s, g).await?;
    loop {
        let Ok(mut s) = self.engine().await else { break };
        if !due(&mut s) { break; }
        all.extend(self.advance_once_for_drive(&mut s, g).await);
    }
}
${send_site}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  _case "a later advance of the loop that does not ask the mode again FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${test_entry}
pub(crate) async fn advance_for_drive_while(&self, g: &G, still: Still) {
    if !still.holds() { return self.settle(g).await; }
    let mut s = self.engine().await?;
    self.advance_once_for_drive(&mut s, g).await
}
${send_site}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  _case "a mode asked before the wait for the engine FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
pub async fn advance_for_drive(&self, g: &G) {
    self.advance_for_drive_while(g, Still::always(&DriveMode::Full)).await
}
${leashed}
${send_site}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  _case "the unleashed entry outside a test build FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let _ = still.holds();
    let advanced = s.advance_convergence(g).await;
    self.staged(s, advanced).await
}"
  _case "a re-read whose answer is thrown away FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds();
    let advanced = s.advance_convergence(g).await;
    self.staged(s, advanced).await
}"
  _case "a re-read bound and never read FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_entries}
async fn advance_once_for_drive(&self, s: &mut S, g: &G, still: Still) {
    let ahead = self.hand_back_stranded(s, g).await?;
    let holds = still.holds() && self.roster(s, g).await.is_some();
    let advanced = if holds { s.advance_convergence(g).await } else { s.settle(g).await };
    self.staged(s, advanced).await
}"
  _case "an await on the re-read's own line FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_site}
async fn hand_back_and_send(&self, g: &G, still: Still) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    s.send(leave).await
}"
  _case "a third function that takes a still and hands back FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_site}
async fn hand_back_and_send(&self, g: &G, mode: DriveMode) {
    let mut s = self.engine().await?;
    let ahead = self.hand_back_stranded(&mut s, g).await?;
    s.send(leave).await
}"
  _case "a function that takes a mode and hands back FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_site//let mode = if still.holds() \{ still.decided() \} else \{ DriveMode::FinishOnly \};
    if self.away_hold/if self.away_hold}"
  _case "a departure check acting in the mode it was called with FAILS" 1 "${ok_circle}"
  reviewed="${receive_sites}
${drive_site}"
  _case "a Still over a mode held in a variable FAILS" 1 "${ok_circle}
async fn x(&self) {
    let full = DriveMode::Full;
    self.session.f(Still::new(&full, full)).await
}"
  _case "a Still over a mode parameter FAILS" 1 "${ok_circle}
async fn x(&self, mode: DriveMode) {
    self.session.f(Still::new(
        &mode,
        mode,
    )).await
}"
  _case "a Still over a mode read off its source FAILS" 1 "${ok_circle}
async fn x(&self) {
    let mode = self.mode.mode();
    self.session.f(Still::new(&mode, mode)).await
}"
  _case "a Still over the mode source itself passes" 0 "${ok_circle}
async fn x(&self) {
    let mode = self.mode.mode();
    self.session.f(Still::new(self.mode, mode)).await
}"
  _case "a Still over a mode a let binds through an if FAILS" 1 "${ok_circle}
async fn x(&self, ready: bool) {
    let m = if ready { DriveMode::Full } else { DriveMode::FinishOnly };
    self.session.f(Still::new(&m, m)).await
}"
  _case "a Still over a mode a let binds across lines FAILS" 1 "${ok_circle}
async fn x(&self) {
    let m =
        DriveMode::Full;
    self.session.f(Still::new(&m, m)).await
}"
  _case "a Still over a field typed as a mode FAILS" 1 "${ok_circle}
struct Pass {
    decided: DriveMode,
}
impl Pass {
    async fn x(&self) {
        self.session.f(Still::new(&self.decided, self.decided)).await
    }
}"
  _case "a test-only seam may build a Still over its mode" 0 "${ok_circle}
#[cfg(any(test, feature = \"test-utils\"))]
pub async fn x_for_test(&self, mode: DriveMode) {
    self.session.f(Still::new(&mode, mode)).await
}"
  if (( fails )); then echo "self-test: FAILED" >&2; return 1; fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}." >&2
    return 1
  fi
  log "OK: self-test passed (${checked} fixtures)."
}

case "${1:-}" in
  --self-test) self_test ;;
  '') view_reaches_late_api_line && run_checks "${REPO_ROOT}" ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
