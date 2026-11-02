#!/usr/bin/env bash
#
# The guest-network predicates of the Android lane runners. SOURCED, never run.
#
# One definition, because both runners that turn the emulator's Wi-Fi off
# (run-single-avd-scenario.sh, run-kp-rotation.sh) decide from these whether
# there is another network to keep, and a parser corrected in one and not the
# other would have them disagree about the same routing table. Pure text
# inspection: nothing here takes a device, and both runners' --self-test pin it.

# wifi_is_off <settings-output> — exit 0 iff the guest reports Wi-Fi OFF.
#
# `settings get global wifi_on` answers `0` or `1`, `null` when the key was
# never written, and adb noise ("device offline", "error: closed") when the
# shell raced the device. ONLY a literal `0` is off. `null` is "the platform has
# no opinion", which is not evidence the second network is gone — treating it as
# off would report success for a disable that never happened, in precisely the
# case that needs catching.
wifi_is_off() {
  [[ "$(printf '%s' "${1:-}" | tr -d '\r' | head -n 1)" == "0" ]]
}

# -----------------------------------------------------------------
# guest_can_route_to <text> <ipv4> [<iface-glob>] — exit 0 iff <text> (the
# guest's /proc/net/route) carries a route that covers <ipv4> on an interface
# that is not loopback and, when <iface-glob> is given, does not match it.
#
# The glob is how a runner asks whether a network OTHER than Wi-Fi reaches the
# relay (`'wlan*'`) before it turns Wi-Fi off, and whether one still does after.
# In CI run 41322563075 cellular never registered on a cold boot, Wi-Fi held the
# only routes, and an unconditional disable left the guest with no network at
# all — while a read moments later still found the wlan0 route the kernel had
# not yet cleared, and called the guest ready.
#
# `sys.boot_completed=1` is the ONLY readiness signal the emulator action waits
# for, and it is not the one that matters here. It fires while the guest's
# network is still coming up: on a COLD boot the interface has to come up and
# take its lease afterwards, and until it does the guest has no route to the
# relay at all. A `connect()` to the host-loopback alias then fails instantly
# with ENETUNREACH (errno 101) rather than blocking, so nothing in the app
# retries it — in CI run 30925179141 the e2e_android live-sync lane's
# `setUpAll` died on exactly that, two seconds into the drive, while its
# sibling poll lane won the same race on the same cold boot.
#
# WHAT THIS CAN AND CANNOT PROVE. It is a NECESSARY-not-sufficient smoke
# signal, and the difference has cost two CI runs in opposite directions.
#
# Not sufficient: `/proc/net/route` is the legacy MAIN table, and Android does
# not route app sockets through it. netd installs each network's routes into its
# own table and picks the table from the socket's fwmark, so the main table can
# carry a covering route while the app's default network has none. In CI run
# 31667128290 it did exactly that — see the Wi-Fi note at run-single-avd-
# scenario.sh's guest-network wait — and this predicate read READY at 0s against
# a default network that returned ENETUNREACH for the whole boot. Widening the
# predicate cannot fix that: the file simply does not carry the answer.
#
# Not a hard gate either: demanding `Destination == 00000000` with a non-null
# gateway asks a different and wrong question. On the api-34 google_apis image
# the guest settles with on-link routes and no default route in main at all:
#
#   eth0   0000000A / 000000FF  ->  10.0.0.0/8    RTF_UP
#   wlan0  0002000A / 00FFFFFF  ->  10.0.2.0/24   RTF_UP
#
# In CI run 30964250098 rejecting that table failed five lanes (e2e_android poll
# + live-sync, e2e_integration, e2e_relay_customization, e2e_profile_android) on
# every boot: not a race, a gate that could never pass.
#
# So it stays permissive AND stays advisory (warn-and-drive, in the runner). It
# catches the guest that has no route to the relay at all; it does not certify
# one that has.
#
# It has to be `/proc/net/route`: it exists on every Android image, needs no
# toybox applet, and reports the kernel's own routing state rather than a
# framework's opinion of it. Format is one route per line, tab-separated, with
# addresses as LITTLE-ENDIAN hex:
#
#   Iface  Destination  Gateway   Flags  RefCnt  Use  Metric  Mask  ...
#   wlan0  00000000     0202000A  0003   0       0    0       00000000
#
# Loopback is excluded (it is up from the first instant and would make this
# vacuous), and RTF_UP (0x1) must be set — a route on a downed interface routes
# nothing.
#
# Deliberately pure bash rather than awk arithmetic: `strtonum()` and `and()`
# are gawk extensions, and `/usr/bin/awk` on the Ubuntu runners is mawk, which
# has neither. Bash's own `$(( ))` has the bitwise operators and is always
# present, so the predicate cannot silently degrade on a different runner image.

# _le_hex_to_u32 <8-hex-chars> — decode one little-endian /proc/net/route field.
_le_hex_to_u32() {
  local h="$1"
  [[ "${h}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 1
  printf '%u' $(( (16#${h:6:2} << 24) | (16#${h:4:2} << 16) \
                | (16#${h:2:2} << 8)  |  16#${h:0:2} ))
}

# _ipv4_to_u32 <a.b.c.d> — 1 if the argument is not a dotted-quad IPv4.
# Octets must be `0` or start with a non-zero digit. Bash arithmetic reads a
# leading-zero literal as OCTAL, so a permissive pattern would decode
# `010.0.2.2` as 8.0.2.2 and quietly wait for a route to a network nobody asked
# about — and `08`/`09` would emit a raw `value too great for base` instead.
# Rejecting the form outright is the honest answer: it is not a spelling this
# harness accepts, and "cannot evaluate" is a verdict the caller already handles.
_ipv4_to_u32() {
  local ip="$1" a b c d oct='(0|[1-9][0-9]*)'
  IFS=. read -r a b c d <<<"${ip}"
  [[ "${a}" =~ ^${oct}$ && "${b}" =~ ^${oct}$ \
  && "${c}" =~ ^${oct}$ && "${d}" =~ ^${oct}$ ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  printf '%u' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

guest_can_route_to() {
  local table="$1" target="$2" skip="${3:-}" tgt iface dest gw flags mask dnum mnum
  tgt="$(_ipv4_to_u32 "${target}")" || return 1
  while read -r iface dest gw flags _ _ _ mask _; do
    [[ -z "${iface}" || "${iface}" == "Iface" || "${iface}" == "lo" ]] && continue
    # Unquoted on the right: the glob is a pattern, not a literal name.
    # shellcheck disable=SC2053
    [[ -n "${skip}" && "${iface}" == ${skip} ]] && continue
    # Anything that is not three well-formed hex fields is adb noise ("device
    # offline", "cat: ... No such file"), i.e. not-ready — never a match.
    [[ "${dest}" =~ ^[0-9A-Fa-f]{8}$ && "${mask}" =~ ^[0-9A-Fa-f]{8}$ \
    && "${flags}" =~ ^[0-9A-Fa-f]+$ ]] || continue
    (( 16#${flags} & 1 )) || continue                  # RTF_UP
    dnum="$(_le_hex_to_u32 "${dest}")" || continue
    mnum="$(_le_hex_to_u32 "${mask}")" || continue
    # `if …; then return 0; fi` rather than `(( … )) && return 0`: the latter is
    # a failing command at the end of a loop body whenever the row does not
    # match, which is only safe because every current caller happens to invoke
    # this from an `if` condition (where errexit is suspended). Spelling the
    # branch out keeps it safe from any caller.
    if (( (tgt & mnum) == (dnum & mnum) )); then
      return 0
    fi
  done <<<"${table}"
  return 1
}
