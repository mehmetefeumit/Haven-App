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
# Per-lane values (B1/B3/B4/B9 below) are documented here and passed by the
# lane's own runner as extra seal arguments — they are that lane's, not every
# lane's.
#
# What is NOT here is not searched for, and a few harness targets still mint
# coordinates of their own as inline literals rather than through a constant:
# `circle_service_remove_member_test.dart` (`latitude: 55.123456`),
# `relay_customization_publish_test.dart` and `relay_resync_convergence_test.dart`
# do. Their lanes' logs are scanned for every needle in this file and by every
# structural rule (S5 catches a coordinate PAIR on a Haven-owned line whether or
# not anyone declared it), but not for those values in the encodings only the
# expander produces. Declaring one means giving it an `HN_COORD_*` here, tying
# it in host_needles_tie.rs and passing it from that lane's runner — the three
# steps B9's two points went through — and the fixtures below then hold it to
# the same digit rules as everything else.

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
# (haven/integration_test/e2e/_lib/fake_location_service.dart). Open Arctic
# Ocean, north of the Siberian shelf: nobody's position, and no land.
#
# The digits are the point as much as the place. A needle is searched in every
# encoding, and the single-axis precision ladder starts at FOUR decimals, so a
# sentinel's 4- and 5-decimal spellings have to be strings a log does not
# otherwise carry. Two properties give that:
#
#   * no 4-digit ascending or descending run and no repeated 3-digit group
#     (hn_digit_ladder below, asserted over every HN_COORD_* in the self-test);
#   * an integer part OUTSIDE 00-59 on both axes, so no spelling can equal the
#     `SS.ffffff` seconds field of a `log show` timestamp — 207 902 of one iOS
#     capture's 5-decimal numbers are in that band against 148 outside it.
readonly HN_COORD_ALICE='78.641977,121.094612'
readonly HN_COORD_BOB='79.343842,117.194008'
readonly HN_COORD_CAROL='79.586509,125.149447'

# Wire-canary constants (haven/integration_test/e2e/_lib/wire_canaries.dart).
# The name canaries are minted per run as `<stem><10-char token>`; only the
# stem is host-knowable, and the expander's prefix ladder makes a 12-character
# stem a searchable term in its own right (the sink term floor is 8).
#
# The canary coordinate is declared on EVERY profile, so it reaches every iOS
# capture and carries the same two digit properties as the role sentinels above
# — including the 00-59 band rule, which is what hn_band_check enforces. It
# carries a THIRD property of its own that the role sentinels do not need: its
# geohash prefixes must contain a non-hex character, or the geohash arm of the
# wire oracle would be undetectable inside a journal's hex furniture
# (`kCanaryLongitude`'s doc, pinned by `canaryGeohashPrefixesSurviveHygiene`).
# Move it in wire_canaries.dart and here together; the tie test holds the two.
readonly HN_COORD_CANARY='-65.463158,-148.295312'
readonly HN_CIRCLE_NAME_STEM='Qzvx CIRCLE '
readonly HN_PETNAME_STEM='Qzvx PETNAME '

# Per-lane fixed coordinates, lat,lon. B1: run-b1-fgs-publish.sh's emulator fix
# (Dam Square, Amsterdam). B3: e2e-real-gps.yml's HAVEN_B3_GEO_* (Rothera
# Research Station, Adelaide Island — a public landmark in the southern AND
# western hemispheres, which is what makes an NMEA hemisphere letter wrong
# loudly). B4: e2e-ios-real-gps.yml's HAVEN_B4_GEO_* (open Southern Ocean, both
# axes negative, the opposite quadrant from every other sentinel here). Each is
# passed by ITS runner as `--host-decl coordinate=…`.
readonly HN_COORD_B1='52.370216,4.895168'
readonly HN_COORD_B3='-67.573047,-68.069783'
readonly HN_COORD_B4='-63.076429,-141.927821'

# B9's two own points, minted on the DEVICE rather than injected by the host:
# Carol's post-restore fix (the liveness signal) and Bob's backlog fix (the one
# event staged during the blackout and imported into strfry). Both are compiled
# into the drive target, which is built by the SHARED integration builder with
# no per-lane `--dart-define`, so unlike B1/B3/B4 the host cannot be the source
# of the value — `b9_network_reconnect_test.dart` is, and these two constants
# are its transcription, tied to those literals verbatim by the Rust tie test.
# Declared by run-b9-network-reconnect.sh at both of its gates; before they were
# declared, the lane minted two coordinates that no needle searched for.
readonly HN_COORD_B9_POST='78.411925,133.846732'
readonly HN_COORD_B9_BACKLOG='78.750293,169.553468'

# hn_digit_ladder <value> — 0 when the value's digits carry a 4-digit ascending
# or descending run, or the same 3-digit group twice.
#
# A ladder is what makes a coordinate collide with numbers a log already
# carries: the ios term floor is 8 characters, and `12.345678`'s round5 spelling
# `12.34568` is exactly 8 of them, which Apple's push daemon matched in CI run
# 35311161479 — one hit per iOS lane, on a daemon that cannot be logging a
# position. Every sentinel here was replaced for that, so the shape cannot come
# back by the next hand that edits a constant.
hn_digit_ladder() {
  local digits i j n a b c d
  digits="${1//[^0-9]/}"
  n=${#digits}
  i=0
  while (( i + 3 < n )); do
    a=${digits:i:1}; b=${digits:i+1:1}; c=${digits:i+2:1}; d=${digits:i+3:1}
    if (( b - a == 1 && c - b == 1 && d - c == 1 )) \
       || (( a - b == 1 && b - c == 1 && c - d == 1 )); then
      return 0
    fi
    i=$(( i + 1 ))
  done
  i=0
  while (( i + 2 < n )); do
    j=$(( i + 1 ))
    while (( j + 2 < n )); do
      [[ "${digits:i:3}" != "${digits:j:3}" ]] || return 0
      j=$(( j + 1 ))
    done
    i=$(( i + 1 ))
  done
  return 1
}

# hn_band_check <lat,lon> — 0 when BOTH axes have an integer part outside
# 00-59, i.e. when no spelling of either can equal the `SS.ffffff` seconds
# field of an iOS `log show` timestamp.
#
# That field is where the collision lives: 207 902 of one 64 MiB capture's
# 5-decimal numbers sit in the 00-59 band against 148 outside it, and every
# line of every iOS capture carries one. A ladder-free value in the band is
# still a value the timestamp column can spell.
hn_band_check() {
  local axis int
  for axis in ${1//,/ }; do
    int="${axis#-}"
    int="${int%%.*}"
    # A leading zero makes bash read the number as octal; strip it first.
    int="${int#0}"
    [[ -n "${int}" ]] || int=0
    (( int > 59 )) || return 1
  done
  return 0
}

# HN_COORD_* the band rule deliberately does NOT bind, each with its reason.
# An entry here is a decision, not a default: the fixture band-checks every
# other constant, so a new one is checked on the day it is added.
#
#   HN_COORD_B1  Dam Square, Amsterdam (52, 4 — both in the band). It is the
#                landmark run-b1-fgs-publish.sh and run-b5-permission-revocation.sh
#                share, and both lanes are ANDROID: a logcat timestamp is
#                `MM-DD HH:MM:SS.mmm`, three decimals, so the six-decimal
#                seconds field this rule is about does not exist in their
#                captures. Moving it would split a landmark across two runners
#                for a collision neither can have.
readonly HN_BAND_EXEMPT='HN_COORD_B1'

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
readonly HN_SELF_TEST_FIXTURES=11
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
  # Every HN_COORD_* by prefix expansion rather than a list, for the reason the
  # ladder fixture below reads the same way: a constant added later is checked
  # on the day it is added, not on the day someone remembers a list.
  ran=$(( ran + 1 ))
  for name in ${!HN_COORD@}; do
    if [[ ! "${!name}" =~ ^-?[0-9]+\.[0-9]{6},-?[0-9]+\.[0-9]{6}$ ]]; then
      echo "SELF-TEST FAIL (${name}): not lat,lon at six decimals" >&2
      fail=1
    fi
  done
  # No sentinel may be a digit ladder either. The helper itself is checked in
  # both directions on the shapes that were replaced.
  ran=$(( ran + 1 ))
  local seen=0
  for name in ${!HN_COORD@}; do
    seen=$(( seen + 1 ))
    if hn_digit_ladder "${!name}"; then
      echo "SELF-TEST FAIL (${name}): the value is a digit ladder (a 4-digit run" \
           "or a repeated 3-digit group). Its 5-decimal spelling is 8 characters," \
           "the ios term floor, and such a string collides with the numbers a" \
           "device-wide log already carries — apsd matched one in CI run" \
           "35311161479. Pick a high-entropy point instead." >&2
      fail=1
    fi
  done
  if (( seen < 9 )) \
     || ! hn_digit_ladder '12.345678,87.654321' \
     || ! hn_digit_ladder '-41.234567,-134.567890' \
     || ! hn_digit_ladder '-22.951916,-43.210487' \
     || hn_digit_ladder "${HN_COORD_CANARY}"; then
    echo "SELF-TEST FAIL (ladder check): the check must see every HN_COORD_*, must" \
         "reject each of the three values replaced for this (the ascending role" \
         "pair, B4's old seed, and B3's old longitude, whose run spans the decimal" \
         "point), and must accept one that is not a ladder" >&2
    fail=1
  fi
  # The band rule, over every constant the exemption list does not name.
  ran=$(( ran + 1 ))
  local exempt_seen=0
  for name in ${!HN_COORD@}; do
    case " ${HN_BAND_EXEMPT} " in
      *" ${name} "*) exempt_seen=$(( exempt_seen + 1 )); continue ;;
    esac
    if ! hn_band_check "${!name}"; then
      echo "SELF-TEST FAIL (${name}): an axis has an integer part inside 00-59," \
           "so one of its spellings is the shape of an iOS log timestamp's" \
           "seconds field — the collision CI run 35311161479 hit. Move the" \
           "point, or list the constant in HN_BAND_EXEMPT with the reason its" \
           "lane cannot produce that shape." >&2
      fail=1
    fi
  done
  # …the exemption list is not stale, and the helper answers both ways on the
  # boundary values (59 is in the band, 60 is not, and a negative axis is read
  # by magnitude).
  if (( exempt_seen != 1 )) \
     || ! hn_band_check '78.641977,121.094612' \
     || hn_band_check '52.370216,4.895168' \
     || hn_band_check '-47.209318,-127.478205' \
     || hn_band_check '60.000001,59.999999' \
     || ! hn_band_check '-60.111111,-60.222222'; then
    echo "SELF-TEST FAIL (band check): every name in HN_BAND_EXEMPT must exist," \
         "and the check must accept a pair outside 00-59, refuse B1's, refuse" \
         "the canary's old value, refuse a pair whose SECOND axis is 59, and" \
         "read a negative axis by magnitude" >&2
    fail=1
  fi
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
  echo "host-needles.sh: self-test passed (${ran}/${HN_SELF_TEST_FIXTURES} fixtures: four repeated-byte seeds, two offset seeds that shift only the trailing byte and wrap, nine lat,lon constants at six decimals, no digit ladder in any of them, no integer part inside the timestamp band except B1's declared exemption, two stems with their trailing space, the proxy and host argv pinned literally, rules declares nothing, an unknown profile is refused, no bash-4-only construct)."
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
