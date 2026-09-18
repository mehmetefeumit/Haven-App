#!/usr/bin/env bash
#
# The needles a lane can declare WITHOUT a recording proxy: the identifiers the
# E2E harness fixes at compile time, known to the host by construction.
#
# A proxy lane learns what a run minted from the declaration channel
# (haven-wire-proxy's `.needles.decl` sidecar). A lane with no proxy has no
# channel, yet its harness still runs the same fixed identities and coordinates,
# so its logs must be searched for them all the same. This library is the ONE
# place those values are written down on the host; the Rust tie test
# (tooling/logscan/tests/host_needles_tie.rs) asserts each constant equals its
# harness source verbatim, so the library cannot drift from what the app is
# actually driven with.
#
# Sourced by tooling/e2e/ci/logscan-gate.sh; run directly only for --self-test.
#
#   host_needle_args <proxy|host|rules>
#     Prints the `haven-logscan seal` arguments for a lane profile, ONE PER LINE
#     (a name stem ends in a space, which a word-split echo would lose; read it
#     with a `while IFS= read -r` loop — the iOS lanes run this under macOS's
#     bash 3.2, which has no `mapfile`):
#       proxy  the four role seeds, the two offset seeds and the constants,
#              ADDED to the sidecar's declarations; the caller keeps its own
#              `--expect` floors
#       host   the same needles plus the floors they satisfy by construction
#       rules  nothing: a rules-only scan seals no manifest
#
# Per-lane values (B1/B3/B4 below) are documented here and passed by the lane's
# own runner as extra seal arguments — they are that lane's, not every lane's.

# Role identity seeds (haven/integration_test/e2e/_lib/test_user.dart): 32 bytes
# of 0x01/0x02/0x03/0x04. `seal --host-seed` derives the pubkey; the seed itself
# is committed, never written to the manifest.
readonly HN_SEED_ALICE='0101010101010101010101010101010101010101010101010101010101010101'
readonly HN_SEED_BOB='0202020202020202020202020202020202020202020202020202020202020202'
readonly HN_SEED_CAROL='0303030303030303030303030303030303030303030303030303030303030303'
readonly HN_SEED_DAVE='0404040404040404040404040404040404040404040404040404040404040404'

# hn_seed_with_offset <64-hex seed> <offset> — the harness's own offset rule
# (haven/integration_test/e2e/_lib/synthetic_user.dart's `_seedWithOffset`):
# the leading 31 bytes unchanged, the trailing byte shifted by <offset> mod 256.
# A scenario uses it to bootstrap several peers from ONE base seed onto one
# relay without two of them colliding on a KeyPackage slot.
#
# Derived here rather than transcribed, because a hand-typed hex string would be
# a second source of truth for arithmetic the app already defines — and a wrong
# digit would read as a clean lane, not as a failing one. The Rust tie test ties
# this function's output to that Dart rule and to the offsets the scenarios
# actually pass.
hn_seed_with_offset() {
  printf '%s%02x' "${1:0:62}" "$(( (0x${1:62:2} + $2) & 0xFF ))"
}

# The offset identities a HOST-profile lane mints, and therefore has to declare:
# relay_customization_publish_test.dart's two extra Bobs (`seedOffset: 1` and
# `seedOffset: 2`). A proxy lane declares what it mints over the channel; a host
# lane's declaration is this library, so without these two the lane's logs were
# searched for neither pubkey. Declared for every sealing profile: a needle that
# a lane never mints costs a term, while one it mints and does not declare costs
# the search.
readonly HN_SEED_BOB_OFFSET1="$(hn_seed_with_offset "${HN_SEED_BOB}" 1)"
readonly HN_SEED_BOB_OFFSET2="$(hn_seed_with_offset "${HN_SEED_BOB}" 2)"

# Role sentinel coordinates, lat,lon
# (haven/integration_test/e2e/_lib/fake_location_service.dart).
readonly HN_COORD_ALICE='12.345678,87.654321'
readonly HN_COORD_BOB='13.456789,89.876543'
readonly HN_COORD_CAROL='14.567890,91.098765'

# Wire-canary constants (haven/integration_test/e2e/_lib/wire_canaries.dart).
# The name canaries are minted per run as `<stem><10-char token>`; only the
# stem is host-knowable, and the expander's prefix ladder makes a 12-character
# stem a searchable term in its own right (the sink term floor is 8).
readonly HN_COORD_CANARY='-47.209318,-127.478205'
readonly HN_CIRCLE_NAME_STEM='Qzvx CIRCLE '
readonly HN_PETNAME_STEM='Qzvx PETNAME '

# Per-lane fixed coordinates, lat,lon. B1: run-b1-fgs-publish.sh's emulator fix
# (Amsterdam). B3: e2e-real-gps.yml's HAVEN_B3_GEO_*. B4: e2e-ios-real-gps.yml's
# HAVEN_B4_GEO_*. Each is passed by ITS runner as `--host-decl coordinate=…`.
readonly HN_COORD_B1='52.370216,4.895168'
readonly HN_COORD_B3='-22.951916,-43.210487'
readonly HN_COORD_B4='-41.234567,-134.567890'

host_needle_args() {
  case "${1:-}" in
    proxy|host)
      printf '%s\n' \
        --host-seed "${HN_SEED_ALICE}" \
        --host-seed "${HN_SEED_BOB}" \
        --host-seed "${HN_SEED_CAROL}" \
        --host-seed "${HN_SEED_DAVE}" \
        --host-seed "${HN_SEED_BOB_OFFSET1}" \
        --host-seed "${HN_SEED_BOB_OFFSET2}" \
        --host-decl "coordinate=${HN_COORD_ALICE}" \
        --host-decl "coordinate=${HN_COORD_BOB}" \
        --host-decl "coordinate=${HN_COORD_CAROL}" \
        --host-decl "coordinate=${HN_COORD_CANARY}" \
        --host-decl "circle_name=${HN_CIRCLE_NAME_STEM}" \
        --host-decl "petname=${HN_PETNAME_STEM}"
      if [[ "$1" == host ]]; then
        printf '%s\n' \
          --expect pubkey=6 --expect coordinate=4 \
          --expect circle_name=1 --expect petname=1
      fi
      ;;
    rules)
      ;;
    *)
      echo "ERROR: host_needle_args: unknown profile '${1:-}' (proxy|host|rules)" >&2
      return 2
      ;;
  esac
}

# --self-test — every constant is present with the shape its class demands, and
# each profile's argv is pinned literally, so a reordering or a dropped needle
# is a failing fixture rather than a quieter scan.
readonly HN_SELF_TEST_FIXTURES=9
# bash-4-only: mapfile/readarray, coproc, declare -A, case conversion, |&, ;;&,
# negative substring offsets.
readonly HOST_NEEDLES_BASH4_ONLY_RE='(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)|declare[[:space:]]+-[a-zA-Z]*A|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|\|&|;;&|\$\{[^}]*:([[:space:]]+-[0-9]|[0-9]+:[[:space:]]*-[0-9])'

hn_self_test() {
  local fail=0 ran=0 name seed coord byte=0 want
  ran=$(( ran + 1 ))
  for name in ALICE BOB CAROL DAVE; do
    seed="HN_SEED_${name}"
    byte=$(( byte + 1 ))
    want="$(printf "0${byte}%.0s" {1..32})"
    if [[ "${!seed}" != "${want}" ]]; then
      echo "SELF-TEST FAIL (seed ${name}): not 32 bytes of 0x0${byte}" >&2
      fail=1
    fi
  done
  ran=$(( ran + 1 ))
  for name in ALICE BOB CAROL CANARY B1 B3 B4; do
    coord="HN_COORD_${name}"
    if [[ ! "${!coord}" =~ ^-?[0-9]+\.[0-9]{6},-?[0-9]+\.[0-9]{6}$ ]]; then
      echo "SELF-TEST FAIL (coordinate ${name}): not lat,lon at six decimals" >&2
      fail=1
    fi
  done
  ran=$(( ran + 1 ))
  if [[ "${HN_CIRCLE_NAME_STEM}" != 'Qzvx CIRCLE ' || "${HN_PETNAME_STEM}" != 'Qzvx PETNAME ' ]]; then
    echo "SELF-TEST FAIL (stems): the name stems must carry their trailing space" >&2
    fail=1
  fi
  # The offset rule, on the three cases that matter: the two offsets a scenario
  # actually passes, and the wrap the Dart `& 0xFF` performs. Checked against
  # the base seed's own bytes, never against a transcribed result — the Rust tie
  # test is what holds this function to the Dart source.
  ran=$(( ran + 1 ))
  if [[ "${HN_SEED_BOB_OFFSET1}" != "${HN_SEED_BOB:0:62}03" \
     || "${HN_SEED_BOB_OFFSET2}" != "${HN_SEED_BOB:0:62}04" \
     || "$(hn_seed_with_offset "${HN_SEED_BOB:0:62}ff" 1)" != "${HN_SEED_BOB:0:62}00" ]]; then
    echo "SELF-TEST FAIL (offset seeds): an offset seed must keep the leading 31" \
         "bytes and shift only the last, wrapping mod 256" >&2
    fail=1
  fi

  local -a got=() line needles=(
    --host-seed "${HN_SEED_ALICE}" --host-seed "${HN_SEED_BOB}"
    --host-seed "${HN_SEED_CAROL}" --host-seed "${HN_SEED_DAVE}"
    --host-seed "${HN_SEED_BOB_OFFSET1}" --host-seed "${HN_SEED_BOB_OFFSET2}"
    --host-decl "coordinate=${HN_COORD_ALICE}" --host-decl "coordinate=${HN_COORD_BOB}"
    --host-decl "coordinate=${HN_COORD_CAROL}" --host-decl "coordinate=${HN_COORD_CANARY}"
    --host-decl 'circle_name=Qzvx CIRCLE ' --host-decl 'petname=Qzvx PETNAME ')
  # The pubkey floor is the number of seeds declared above, exactly: a runner
  # that dropped one must not be able to seal a manifest that reads as complete.
  local -a want_host=("${needles[@]}"
    --expect pubkey=6 --expect coordinate=4 --expect circle_name=1 --expect petname=1)
  # hn_argv_mismatch <label> <got...> -- <want...> — the first differing index
  # and the flag words there. The argv carries the seeds, so no value is ever
  # printed: a non-flag word is reported only by its length.
  hn_word() { if [[ "$1" == --* || "$1" == '<end>' ]]; then printf '%s' "$1"; else printf '<%d-char value>' "${#1}"; fi; }
  hn_argv_mismatch() {
    local label="$1" i=0 g w
    shift
    local -a got=() want=()
    while (( $# > 0 )) && [[ "$1" != -- ]]; do got+=("$1"); shift; done
    shift
    want=("$@")
    while (( i < ${#got[@]} || i < ${#want[@]} )); do
      g='<end>'; w='<end>'
      (( i >= ${#got[@]} )) || g="${got[i]}"
      (( i >= ${#want[@]} )) || w="${want[i]}"
      if [[ "${g}" != "${w}" ]]; then
        echo "SELF-TEST FAIL (${label}): argv differs at index ${i} — got $(hn_word "${g}") (of ${#got[@]}), expected $(hn_word "${w}") (of ${#want[@]})" >&2
        return
      fi
      i=$(( i + 1 ))
    done
  }
  ran=$(( ran + 1 ))
  got=()
  while IFS= read -r line; do got+=("${line}"); done < <(host_needle_args proxy)
  if [[ "$(printf '%s\n' "${got[@]}")" != "$(printf '%s\n' "${needles[@]}")" ]]; then
    hn_argv_mismatch "proxy argv" "${got[@]}" -- "${needles[@]}"
    fail=1
  fi
  ran=$(( ran + 1 ))
  got=()
  while IFS= read -r line; do got+=("${line}"); done < <(host_needle_args host)
  if [[ "$(printf '%s\n' "${got[@]}")" != "$(printf '%s\n' "${want_host[@]}")" ]]; then
    hn_argv_mismatch "host argv" "${got[@]}" -- "${want_host[@]}"
    fail=1
  fi
  ran=$(( ran + 1 ))
  if [[ -n "$(host_needle_args rules)" ]]; then
    echo "SELF-TEST FAIL (rules argv): a rules-only profile must declare nothing" >&2
    fail=1
  fi
  ran=$(( ran + 1 ))
  if host_needle_args nonesuch 2>/dev/null; then
    echo "SELF-TEST FAIL (unknown profile): must be refused" >&2
    fail=1
  fi
  # The iOS lanes source this on macOS runners under /bin/bash 3.2, which
  # cannot be run here, so the guard is static: no bash-4-only construct
  # anywhere in this file (its own definition line excepted).
  ran=$(( ran + 1 ))
  if grep -vF 'HOST_NEEDLES_BASH4_ONLY_RE=' "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#' \
       | grep -qE "${HOST_NEEDLES_BASH4_ONLY_RE}"; then
    echo "SELF-TEST FAIL (bash 3.2): a bash-4-only construct is in this file (the constructs are listed at the regex definition); macOS's /bin/bash cannot run it" >&2
    fail=1
  fi

  if (( fail )); then
    echo "host-needles.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != HN_SELF_TEST_FIXTURES )); then
    echo "host-needles.sh: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${HN_SELF_TEST_FIXTURES}" >&2
    return 1
  fi
  echo "host-needles.sh: self-test passed (${ran}/${HN_SELF_TEST_FIXTURES} fixtures: four repeated-byte seeds, two offset seeds that shift only the trailing byte and wrap, seven lat,lon constants, two stems with their trailing space, the proxy and host argv pinned literally, rules declares nothing, an unknown profile is refused, no bash-4-only construct)."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  case "${1:-}" in
    --self-test)
      hn_self_test
      exit $?
      ;;
  esac
  echo "host-needles.sh is a sourced library; pass --self-test to run it directly." >&2
  exit 2
fi
