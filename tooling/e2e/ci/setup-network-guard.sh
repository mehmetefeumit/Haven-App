#!/usr/bin/env bash
#
# CI network-egress guard for the hermetic E2E lanes (e2e-android,
# e2e-profile/android, e2e-location-provider-toggle).
#
# Workstream C proves, from the relay's side, that only expected data leaves
# the device. This is the complement: it proves nothing leaves to an
# UNEXPECTED DESTINATION. A wire oracle that inspects the traffic we know
# about says nothing about a host we never intended to contact.
#
# =============================================================================
# WHAT THIS SCRIPT DID BEFORE C7, AND WHY THAT WAS NOT ENOUGH
# =============================================================================
#
# It installed exactly five rules: ACCEPT `-o lo`, ACCEPT ESTABLISHED/RELATED,
# ACCEPT `-d 172.16.0.0/12`, then REJECT `tcp --dport 80` and REJECT
# `tcp --dport 443`. There was no LOG target anywhere and no ip6tables chain.
# Three consequences, all of them silence:
#
#   * Egress to ANY other destination passed. TCP 8080, 9735, a relay on
#     :4848, DNS or NTP over UDP, QUIC/HTTP-3 on UDP 443 — none of it was
#     touched. "Rejects 80/443" is a statement about two ports, not about
#     egress.
#   * Egress over IPv6 was entirely unguarded, including ports 80 and 443:
#     the chain lived in `iptables` only, and `ip6tables` appears nowhere in
#     this repo.
#   * Nothing was recorded either way. A clean run and a run that dialled a
#     CDN on port 8080 produced byte-identical evidence: none. So the guard
#     could not answer the question it exists to answer, and no one could
#     tell whether it was even working.
#
# =============================================================================
# WHAT IT DOES NOW: OBSERVE FIRST, ENFORCE LATER
# =============================================================================
#
# Two LOG rules sit at the top of the chain, before every verdict rule, so
# they see traffic regardless of what happens to it afterwards. `-j LOG` is
# non-terminating; adding it changes no packet's fate.
#
#   HAVEN_EGRESS_EXT:   every NEW flow leaving on a non-loopback interface.
#                       UNRATE-LIMITED — this is the finding, and a sampled
#                       finding is not a finding.
#   HAVEN_EGRESS_LO:    every NEW flow on `lo`, rate-limited to 20/min with a
#                       burst of 40. This is NOT a finding; it is the liveness
#                       proof (see ANTI-VACUITY). Loopback is where all of a
#                       hermetic lane's real traffic lives, so it is high
#                       volume and low information, and sampling it is the
#                       right trade.
#
# `--ctstate NEW` means one line per connection ATTEMPT, not per packet: a
# 10 MB download is one line, not seven thousand. `--log-uid` records the
# UID/GID of the originating socket.
#
# ## Mode: observe (default) vs enforce
#
#   observe   Everything above, plus the pre-C7 REJECT of TCP 80/443 kept
#             EXACTLY as it was. Nothing else is blocked. `report` never
#             fails on a destination.
#   enforce   Everything above, plus ACCEPT for each line of
#             `egress-allowlist.txt` and REJECT for everything else; `report`
#             exits 1 if any observed flow fell outside the allow-list.
#
# The staging is deliberate. Asserting on a destination set nobody has
# measured produces a false red on the first unexpected-but-legitimate host
# — a DNS resolver, an NTP peer, an Azure metadata endpoint, a connectivity
# check the AVD makes on its own — and a lane that cries wolf gets bypassed.
# Log first, let the nightlies establish the real baseline, assert later.
# `egress-allowlist.txt` documents the evidence bar for that flip.
#
# ## NOT a "move to logging-only": the existing enforcement is KEPT
#
# The backlog item says "move to logging-only first". Taken literally that
# means dropping today's REJECT of TCP 80/443, which would let an accidental
# CDN / Blossom / public-relay call actually SUCCEED where today it gets an
# RST — a privacy REGRESSION shipped in the name of a privacy improvement,
# and a direct hit on CLAUDE.md Security Rule 10. So observe mode is
# strictly additive: the pre-C7 rejects survive byte-for-byte, and the
# logging-only posture applies to the NEWLY OBSERVED surface (every port and
# protocol other than TCP 80/443), which was previously unguarded AND
# unrecorded. Nothing that was blocked yesterday is permitted today.
#
# =============================================================================
# ATTRIBUTION CEILING — READ THIS BEFORE QUOTING THE OUTPUT
# =============================================================================
#
# The observation is at UID/GID granularity, and on a GitHub-hosted runner
# that DOES NOT separate the app from the emulator or from the toolchain.
#
#   * iptables cannot attribute to a PID. `xt_owner`'s `--pid-owner` and
#     `--sid-owner` matches were removed from the kernel long ago; only
#     `--uid-owner` / `--gid-owner` survive, and `--log-uid` is their
#     read-only equivalent.
#   * The Android emulator uses QEMU SLIRP userspace networking: it proxies
#     GUEST TCP/UDP through HOST sockets owned by `qemu-system-x86_64`. That
#     process runs as the same `runner` UID as `flutter drive`, `adb`, and
#     Gradle. So one UID covers the app's traffic, the AVD's own traffic
#     (GMS check-in, captive-portal probes, guest DNS) and the build
#     toolchain's traffic, indistinguishably.
#   * The only reliable split `--log-uid` gives is root (system daemons:
#     dockerd, chrony, unattended-upgrades, systemd-resolved's upstream
#     queries) vs non-root (everything this lane runs).
#
# Therefore: "destination X was contacted during the drive window" is the
# strongest claim this instrument supports. "HAVEN contacted X" is NOT, and
# must never be written on the strength of this log alone. An unattributable
# baseline is still useful — it bounds the total set of destinations, which
# is exactly what an allow-list needs — but presenting it as an app-behaviour
# claim would be the same category error this repo keeps catching elsewhere.
#
# Two things do narrow it, and both are recorded rather than assumed:
#
#   1. TIME. The guard is installed inside the drive step, AFTER the AVD has
#      finished booting (`reactivecircus/android-emulator-runner` boots before
#      it runs `script:`), and torn down straight after. So the window is the
#      drive, not the job: boot-time GMS chatter is out of frame, and so is
#      every `flutter pub get` / Gradle / cargo fetch, which all run in
#      earlier steps.
#   2. DESTINATION. Classification in the report is by destination, not by
#      process, and the report says so on its own face.
#
# Separating the AVD's traffic from Haven's would need the emulator running
# under its own UID (the emulator-runner action gives no such hook) or a
# guest-side rule set (no root on a `google_apis` AVD; `adb root` is refused
# on Play-store images and the lanes use `google_apis`). Not attempted, and
# not claimed.
#
# =============================================================================
# ANTI-VACUITY — this guard's failure mode is silence, so it proves it can see
# =============================================================================
#
# Three gates run at INSTALL time, before the drive starts, so a blind lane
# fails immediately instead of running to green having watched nothing:
#
#   G1  RULE READ-BACK. `iptables -S` must show the chain with both LOG rules
#       present, and the OUTPUT jump must exist. `iptables -A` exiting 0 is
#       not proof — the same "the exit code is worthless" trap `pm grant`
#       needed in the B-series lanes.
#   G2  LOOPBACK PROBE. A datagram is sent to 127.0.0.1 and a
#       HAVEN_EGRESS_LO line must appear in the kernel log within
#       PROBE_TIMEOUT. This is what G1 cannot give: it proves the rule
#       MATCHES TRAFFIC and that the line REACHES the reader. A chain that is
#       present but never consulted (wrong table, jump at the wrong position,
#       a DROP above it) passes G1 and fails G2.
#   G3  UNEXPECTED-DESTINATION PROBE. A datagram is sent to 192.0.2.1
#       (RFC 5737 TEST-NET-1 — documentation-only, guaranteed never routed on
#       the public internet, so the probe cannot reach anything) and a
#       HAVEN_EGRESS_EXT line naming it must appear. This is the literal
#       demand: a deliberate egress to an unexpected destination shows up in
#       the log. It also exercises the enforce path — in enforce mode the
#       probe is REJECTed, and still logged, because LOG precedes REJECT.
#
# And at REPORT time:
#
#   G4  NON-EMPTY. A missing, empty, or LO-less capture is a lane FAILURE
#       with its own exit code (3), never a pass. This is A4's lesson
#       verbatim — "nothing to scan" was reported as "nothing leaked" — and
#       the exit-code convention is deliberately the SAME one
#       `scan-logs-for-secrets.sh` established rather than a new one:
#         0 clean/observed  1 violation  2 usage  3 UNOBSERVABLE.
#       Note which stream carries the gate: an EMPTY EXTERNAL set is a
#       perfectly healthy result for a hermetic lane and must never fail,
#       so the liveness gate is on the LOOPBACK stream, which is non-empty
#       on any run where the drive talked to adb, the emulator console, the
#       VM service or the relay — i.e. any run at all.
#   G5  COUNTER READ-BACK. The chain's LOG-rule packet counters are read back
#       before teardown and must be non-zero, cross-checking G4 against the
#       kernel's own accounting rather than against our parse of a text log.
#
# =============================================================================
# WHERE THE LOG GOES, AND WHAT UPLOADING IT DISCLOSES
# =============================================================================
#
# `-j LOG` writes to the kernel ring buffer. The ring is finite (~128 KB-1 MB)
# and WILL wrap on a long lane, so `install` starts a background follower
# (`dmesg --follow-new`) draining it to a file; `report` also takes a final
# `dmesg` snapshot and merges, so a follower that died still degrades to
# whatever the ring retained rather than to nothing.
#
#   $EGRESS_DIR/egress-raw.log       merged, de-duplicated kernel lines
#   $EGRESS_DIR/egress-summary.txt   aggregated PROTO / DST / PORT / UID +
#                                    counts, plus the verdict
#
# `report` echoes the summary to stdout (so it is in the lane's own log) and
# appends it to `$GITHUB_STEP_SUMMARY` (so a nightly's baseline is readable
# from the job page without downloading anything). Both files are uploaded as
# an artifact on EVERY outcome, not just failure: the whole point of observe
# mode is to accumulate a baseline from GREEN runs, and an artifact that only
# appears on red would never produce one.
#
# ## Disclosure review of the uploaded artifact
#
# `-j LOG` records IP and transport HEADERS ONLY. No payload byte is ever
# copied, so no pubkey, event id, coordinate, display name or ciphertext can
# appear by construction. What IS in there:
#
#   * DST — public infrastructure addresses (Azure resolver, Ubuntu mirrors,
#     Google connectivity-check endpoints, GitHub) plus loopback and the
#     Docker bridge. Nothing user-specific; there is no user.
#   * SRC — the ephemeral runner's own address. Already visible in every
#     GitHub Actions run and destroyed with the VM.
#   * SPT/DPT/PROTO — ports. UID/GID — `0` and `1001`.
#
# So nothing needs stripping, and this file says so explicitly rather than
# leaving it to inference. It is nonetheless run through
# `scan-logs-for-secrets.sh` before upload, because that is this repo's
# standing rule for anything an artifact carries and because it costs one
# step; the same scanner's rc-3 then also covers the "artifact went missing"
# case. The one field deliberately dropped is `MAC=` (L2 addresses), which
# the OUTPUT chain does not emit anyway; the parser ignores it either way.
#
# =============================================================================
# SCOPE: THE iOS HALF IS SKIPPED, AND THE STATED REASON IS ONLY HALF TRUE
# =============================================================================
#
# Skipped, per the backlog item. The first clause is exactly right:
# `e2e-ios.yml:57` and `e2e-profile.yml:405` are `runs-on: macos-latest`,
# which has `pf`, not iptables, and no equivalent hook in the lane.
#
# The second clause — "hermeticity is already enforced in-process" — is TRUE
# FOR THE RELAY PLANES AND ONLY THOSE. Verified: `TestUser.bootstrapProcess`
# (`haven/integration_test/e2e/_lib/test_user.dart:118-137`) rejects any
# non-loopback URL in BOTH the circle pool and the profile pool with a
# `StateError` before the bridge is initialised, and then read-back-verifies
# that the override propagated (`:240-247`) instead of trusting the setter.
# `e2e_profile_sharing.dart:346` applies the same test to its Blossom base
# URL. That is a genuine in-process control, and it fails closed.
#
# What it does NOT cover, on iOS or anywhere: anything that reaches the
# network WITHOUT going through the relay/Blossom URL resolvers — map tiles,
# platform telemetry, a future SDK. On Android those are caught (in observe
# mode, for TCP 80/443) or at least SEEN (everything else) by this script.
# On iOS they are neither blocked nor recorded. So "hermeticity is already
# enforced in-process" should be read as "the relay and profile planes
# cannot leave loopback", which is the important half but not the whole
# claim, and the iOS lanes remain UNINSTRUMENTED for egress outside those
# planes. Recorded here so the next person does not inherit the stronger
# reading.
#
# =============================================================================
# USAGE
# =============================================================================
#
#   bash tooling/e2e/ci/setup-network-guard.sh                 # = install
#   bash tooling/e2e/ci/setup-network-guard.sh install
#   bash tooling/e2e/ci/setup-network-guard.sh report
#   bash tooling/e2e/ci/setup-network-guard.sh teardown
#   bash tooling/e2e/ci/setup-network-guard.sh --self-test
#
# Exit codes (same convention as scan-logs-for-secrets.sh, deliberately):
#   0 = installed / observed cleanly
#   1 = a destination outside the allow-list was observed (enforce mode only,
#       or self-test failure)
#   2 = usage error
#   3 = UNOBSERVABLE — the guard could not be installed, could not prove it
#       sees traffic, or produced no capture. This run proves NOTHING about
#       egress; it is not a clean run.
#
# Environment:
#   HAVEN_EGRESS_MODE   observe (default) | enforce.  <-- the enforcement flip
#   STRFRY_PORT         host port strfry listens on (default 7777)
#   SKIP_GUARD          "1" skips installation entirely (local dev override)
#   EGRESS_DIR          output directory (default /tmp/haven-egress)
#   HAVEN_EGRESS_ALLOWLIST  path to the allow-list (default: alongside this
#                       script)

set -euo pipefail

# ---------------------------------------------------------------------------
# THE ENFORCEMENT FLIP LIVES ON THE NEXT LINE.
#
# Changing `observe` to `enforce` here turns all three lanes that install this
# guard from recording to rejecting in one edit, because none of them passes a
# mode. Do not do it without the evidence bar in egress-allowlist.txt.
# ---------------------------------------------------------------------------
MODE="${HAVEN_EGRESS_MODE:-observe}"
readonly MODE

readonly STRFRY_PORT="${STRFRY_PORT:-7777}"
readonly CHAIN="HAVEN_E2E_GUARD"
readonly EGRESS_DIR="${EGRESS_DIR:-/tmp/haven-egress}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SELF_PATH="${BASH_SOURCE[0]}"
readonly SELF_PATH
readonly ALLOWLIST="${HAVEN_EGRESS_ALLOWLIST:-${SCRIPT_DIR}/egress-allowlist.txt}"

# Named exit codes, so the "unobservable != clean" distinction cannot be
# collapsed by an accidental `return 0` in a later edit (scan-logs-for-secrets.sh
# established this convention; C7 reuses it rather than inventing a second one).
readonly RC_OK=0
readonly RC_VIOLATION=1
readonly RC_USAGE=2
readonly RC_UNOBSERVABLE=3

readonly LOG_PREFIX_EXT='HAVEN_EGRESS_EXT: '
readonly LOG_PREFIX_LO='HAVEN_EGRESS_LO: '

# RFC 5737 TEST-NET-1. Reserved for documentation, never routed on the public
# internet, so probing it cannot contact anything real — while still being, to
# every rule in the chain, an ordinary unexpected external destination.
readonly PROBE_EXT_ADDR='192.0.2.1'
readonly PROBE_LO_ADDR='127.0.0.1'
# Discard port. Nothing listens; a UDP datagram is emitted unconditionally by
# the kernel and traverses OUTPUT, which is all the probe needs. No listener,
# no handshake, no timeout.
readonly PROBE_PORT='9'
readonly PROBE_TIMEOUT="${HAVEN_EGRESS_PROBE_TIMEOUT:-15}"

readonly RAW_LOG="${EGRESS_DIR}/egress-raw.log"
readonly SUMMARY="${EGRESS_DIR}/egress-summary.txt"
readonly FOLLOWER_LOG="${EGRESS_DIR}/.follower.log"
readonly FOLLOWER_PID="${EGRESS_DIR}/.follower.pid"
readonly STATE_FILE="${EGRESS_DIR}/.state.env"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

log() { echo "[egress-guard] $*"; }
err() { echo "[egress-guard] $*" >&2; }

# `-w 5` on every call: the b9 lane installs its own chain (HAVEN_B9_OUTAGE)
# and a concurrent invocation otherwise dies on the xtables lock. The pre-C7
# version had no `-w` and was one scheduling accident away from a spurious red.
ipt() { sudo iptables -w 5 "$@"; }
ipt6() { sudo ip6tables -w 5 "$@"; }

have_ip6tables() { command -v ip6tables >/dev/null 2>&1; }

# Read the kernel ring buffer. `dmesg` is restricted to root on many kernels
# (kernel.dmesg_restrict=1); try unprivileged first so the self-test can run
# without sudo, then escalate.
#
# HAVEN_EGRESS_NO_SNAPSHOT=1 suppresses the read entirely. That is what makes
# `--self-test` hermetic: without it, a self-test running on a machine whose
# ring buffer happens to hold real HAVEN_EGRESS lines would silently score its
# fixtures against someone else's traffic.
read_dmesg() {
  [[ "${HAVEN_EGRESS_NO_SNAPSHOT:-}" == "1" ]] && return 0
  dmesg 2>/dev/null || sudo dmesg 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Allow-list parsing.
#
# Emits normalized "cidr proto port" triples on stdout. Refuses, loudly, the
# two shapes that would make enforce mode a lie: a default route (which allows
# everything while looking like a rule) and an IPv6 CIDR narrower than /128
# (which this matcher cannot evaluate and must not guess at).
# ---------------------------------------------------------------------------
parse_allowlist() {
  local file="$1" line cidr proto port lineno=0 bad=0
  if [[ ! -f "${file}" ]]; then
    err "ERROR: allow-list not found: ${file}"
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$(( lineno + 1 ))
    line="${line%%#*}"
    # shellcheck disable=SC2001
    line="$(echo "${line}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "${line}" ]] && continue
    # Split with `read`, NOT `set -- ${line}`. Unquoted word-splitting also
    # PATHNAME-EXPANDS, and the `*` this format uses for "any proto / any port"
    # is a glob: on an unlucky working directory every wildcard line silently
    # became a 31-field line naming files in the cwd. `read` does not glob.
    local extra=''
    read -r cidr proto port extra <<< "${line}"
    if [[ -z "${cidr}" || -z "${proto}" || -z "${port}" || -n "${extra}" ]]; then
      err "ERROR: ${file}:${lineno}: expected exactly 3 fields (cidr proto port), got '${line}'"
      bad=1
      continue
    fi
    proto="$(echo "${proto}" | tr '[:lower:]' '[:upper:]')"
    case "${cidr}" in
      0.0.0.0/0 | ::/0 | '*')
        err "ERROR: ${file}:${lineno}: a default route ('${cidr}') allows everything;" \
            "it would make enforce mode a no-op that reads like a control."
        bad=1
        continue
        ;;
    esac
    # IPv6 entries: only /128 (or a bare address) can be evaluated here.
    if [[ "${cidr}" == *:* && "${cidr}" == */* && "${cidr##*/}" != "128" ]]; then
      err "ERROR: ${file}:${lineno}: IPv6 CIDR '${cidr}' is not /128;" \
          "this matcher does not do IPv6 prefix arithmetic and refuses to guess."
      bad=1
      continue
    fi
    case "${proto}" in TCP | UDP | ICMP | '*') ;; *)
      err "ERROR: ${file}:${lineno}: proto must be TCP|UDP|ICMP|*, got '${proto}'"
      bad=1
      continue
      ;;
    esac
    if [[ "${port}" != '*' && ! "${port}" =~ ^[0-9]{1,5}$ ]]; then
      err "ERROR: ${file}:${lineno}: port must be a number or *, got '${port}'"
      bad=1
      continue
    fi
    echo "${cidr} ${proto} ${port}"
  done < "${file}"
  return "${bad}"
}

_ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "${a}${b}${c}${d}" =~ ^[0-9]+$ ]] || return 1
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# ipv4_in_cidr <ip> <cidr-or-ip>
_ipv4_in_cidr() {
  local ip="$1" cidr="$2" net bits ipi neti mask
  if [[ "${cidr}" != */* ]]; then
    [[ "${ip}" == "${cidr}" ]]
    return
  fi
  net="${cidr%/*}"
  bits="${cidr#*/}"
  [[ "${bits}" =~ ^[0-9]{1,2}$ ]] || return 1
  (( bits > 32 )) && return 1
  ipi="$(_ipv4_to_int "${ip}")" || return 1
  neti="$(_ipv4_to_int "${net}")" || return 1
  (( bits == 0 )) && return 0
  mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (ipi & mask) == (neti & mask) ))
}

# allowlist_permits <dst> <proto> <port> — reads triples on stdin.
allowlist_permits() {
  local dst="$1" proto="$2" port="$3" cidr aproto aport
  while read -r cidr aproto aport; do
    [[ -z "${cidr}" ]] && continue
    if [[ "${aproto}" != '*' && "${aproto}" != "${proto}" ]]; then continue; fi
    if [[ "${aport}" != '*' && "${aport}" != "${port}" ]]; then continue; fi
    if [[ "${dst}" == *:* ]]; then
      # IPv6: exact match only, by construction (see parse_allowlist).
      [[ "${dst}" == "${cidr}" || "${dst}" == "${cidr%/128}" ]] && return 0
    else
      _ipv4_in_cidr "${dst}" "${cidr}" && return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Rule installation
# ---------------------------------------------------------------------------

# The conntrack match module name differs between builds; `-m conntrack` is
# current, `-m state` is the legacy alias the pre-C7 script used. Probe rather
# than assume: picking the wrong one makes every rule below fail to install,
# and the read-back gate would then fail the whole lane for a cosmetic reason.
#
# The probe runs in a THROWAWAY chain. Probing inside ${CHAIN} would be
# circular — the chain does not exist yet at detection time, so every probe
# would fail and the fallback would always win.
CT_MATCH=(-m conntrack --ctstate)
readonly CT_PROBE_CHAIN="HAVEN_E2E_CTPROBE"
detect_ct_match() {
  ipt -F "${CT_PROBE_CHAIN}" >/dev/null 2>&1 || ipt -N "${CT_PROBE_CHAIN}" >/dev/null 2>&1 || true
  if ipt -A "${CT_PROBE_CHAIN}" -m conntrack --ctstate NEW -j ACCEPT >/dev/null 2>&1; then
    CT_MATCH=(-m conntrack --ctstate)
  else
    CT_MATCH=(-m state --state)
  fi
  ipt -F "${CT_PROBE_CHAIN}" >/dev/null 2>&1 || true
  ipt -X "${CT_PROBE_CHAIN}" >/dev/null 2>&1 || true
}

install_chain() {
  local ipt_cmd="$1" family="$2"
  local lo_net_v4=() ct=("${CT_MATCH[@]}")

  if "${ipt_cmd}" -L "${CHAIN}" -n >/dev/null 2>&1; then
    "${ipt_cmd}" -F "${CHAIN}"
  else
    "${ipt_cmd}" -N "${CHAIN}"
  fi

  # --- OBSERVATION (rules 1-2). Non-terminating; they change no verdict, and
  # they come FIRST so they see traffic that a later rule rejects. ---
  #
  # LO is rate-limited: it is the liveness proof, not the finding, and a
  # hermetic lane's loopback volume would otherwise wrap the ring buffer and
  # push out the EXT lines that matter.
  "${ipt_cmd}" -A "${CHAIN}" -o lo "${ct[@]}" NEW \
    -m limit --limit 20/min --limit-burst 40 \
    -j LOG --log-prefix "${LOG_PREFIX_LO}" --log-uid --log-level 4
  # EXT is NOT rate-limited. Completeness where it matters.
  "${ipt_cmd}" -A "${CHAIN}" ! -o lo "${ct[@]}" NEW \
    -j LOG --log-prefix "${LOG_PREFIX_EXT}" --log-uid --log-level 4

  # --- VERDICT (rules 3+). ---
  "${ipt_cmd}" -A "${CHAIN}" -o lo -j ACCEPT
  "${ipt_cmd}" -A "${CHAIN}" "${ct[@]}" ESTABLISHED,RELATED -j ACCEPT

  if [[ "${MODE}" == "enforce" ]]; then
    local cidr proto port args
    while read -r cidr proto port; do
      [[ -z "${cidr}" ]] && continue
      # Skip entries of the wrong address family; a v4 CIDR in ip6tables is a
      # hard error that would abort the install.
      if [[ "${family}" == "v6" && "${cidr}" != *:* ]]; then continue; fi
      if [[ "${family}" == "v4" && "${cidr}" == *:* ]]; then continue; fi
      args=(-A "${CHAIN}" -d "${cidr}")
      # `if` blocks, not `[[ … ]] && …`: under `set -e` a false one-liner is the
      # last command of the loop body and would abort the whole install.
      if [[ "${proto}" != '*' ]]; then
        args+=(-p "$(echo "${proto}" | tr '[:upper:]' '[:lower:]')")
      fi
      if [[ "${port}" != '*' && "${proto}" != '*' && "${proto}" != 'ICMP' ]]; then
        args+=(--dport "${port}")
      fi
      args+=(-j ACCEPT)
      "${ipt_cmd}" "${args[@]}"
    done < <(parse_allowlist "${ALLOWLIST}")
    "${ipt_cmd}" -A "${CHAIN}" -p tcp -j REJECT --reject-with tcp-reset
    if [[ "${family}" == "v6" ]]; then
      "${ipt_cmd}" -A "${CHAIN}" -j REJECT --reject-with icmp6-port-unreachable
    else
      "${ipt_cmd}" -A "${CHAIN}" -j REJECT --reject-with icmp-port-unreachable
    fi
  else
    # OBSERVE MODE. The pre-C7 verdict rules, unchanged: Docker bridge ACCEPT,
    # then REJECT TCP 80 and 443. Everything else falls off the end of the
    # chain and returns to OUTPUT's policy (ACCEPT) — observed, not blocked.
    if [[ "${family}" == "v4" ]]; then
      lo_net_v4=(-d 172.16.0.0/12)
      "${ipt_cmd}" -A "${CHAIN}" "${lo_net_v4[@]}" -j ACCEPT
    fi
    "${ipt_cmd}" -A "${CHAIN}" -p tcp --dport 80 -j REJECT --reject-with tcp-reset
    "${ipt_cmd}" -A "${CHAIN}" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
  fi

  # Jump from OUTPUT. Delete any stale jump first so a reused runner is
  # idempotent.
  "${ipt_cmd}" -D OUTPUT -j "${CHAIN}" 2>/dev/null || true
  "${ipt_cmd}" -I OUTPUT 1 -j "${CHAIN}"
}

# ---------------------------------------------------------------------------
# G1 — rule read-back. `iptables -A` exiting 0 proves the CLI parsed the
# arguments, not that the rule is in the table and reachable.
# ---------------------------------------------------------------------------
verify_installed() {
  local ipt_cmd="$1" label="$2" dump fail=0
  dump="$("${ipt_cmd}" -S "${CHAIN}" 2>/dev/null || true)"
  if [[ -z "${dump}" ]]; then
    err "G1 FAIL (${label}): chain ${CHAIN} is absent after install."
    return 1
  fi
  grep -qF -- "--log-prefix \"${LOG_PREFIX_LO}\"" <<< "${dump}" \
    || grep -qF -- "--log-prefix ${LOG_PREFIX_LO}" <<< "${dump}" \
    || { err "G1 FAIL (${label}): loopback LOG rule missing from ${CHAIN}."; fail=1; }
  grep -qF -- "--log-prefix \"${LOG_PREFIX_EXT}\"" <<< "${dump}" \
    || grep -qF -- "--log-prefix ${LOG_PREFIX_EXT}" <<< "${dump}" \
    || { err "G1 FAIL (${label}): external LOG rule missing from ${CHAIN}."; fail=1; }
  "${ipt_cmd}" -C OUTPUT -j "${CHAIN}" >/dev/null 2>&1 \
    || { err "G1 FAIL (${label}): OUTPUT does not jump to ${CHAIN}."; fail=1; }
  return "${fail}"
}

# ---------------------------------------------------------------------------
# Probes (G2/G3). A UDP datagram is used rather than a TCP connect: the kernel
# emits it unconditionally, so no listener, no handshake and no timeout are
# involved, and the OUTPUT chain sees it either way.
# ---------------------------------------------------------------------------
send_probe() {
  local addr="$1" port="$2"
  # bash's /dev/udp (Ubuntu builds enable net redirections). `nc` is the
  # fallback so a stripped bash cannot silently turn the gate into a no-op.
  if (printf 'haven-egress-probe' > "/dev/udp/${addr}/${port}") 2>/dev/null; then
    return 0
  fi
  if command -v nc >/dev/null 2>&1; then
    printf 'haven-egress-probe' | nc -u -w 1 "${addr}" "${port}" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

# await_log <prefix> <needle> — poll the kernel log for a matching line.
await_log() {
  local prefix="$1" needle="$2" deadline=$(( SECONDS + PROBE_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if read_dmesg | grep -aF -- "${prefix}" | grep -qaF -- "${needle}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Self-diagnosis for a failed probe gate.
#
# "No line appeared" has exactly two causes and they need opposite fixes, so
# the gate reports WHICH rather than making the next person reproduce the
# triage by hand. The kernel's own per-rule packet counter is the
# discriminator, and it is authoritative in a way our text parse is not:
#
#   counter > 0  → the rule MATCHED the probe; the packet was seen and the
#                  chain is correct. What failed is the READ — the kernel log
#                  is not reaching this process (kernel.dmesg_restrict with no
#                  working sudo, a seccomp/container policy, or netfilter's
#                  refusal to emit syslog from a netns owned by a non-initial
#                  user namespace, which is what makes this un-testable under
#                  `unshare -r`).
#   counter == 0 → the rule did NOT match. The chain is present (G1 passed) but
#                  is not on the path the probe took: wrong table, a jump
#                  inserted below a terminating rule, or a match expression
#                  that never fires.
diagnose_probe_failure() {
  local prefix="$1" pkts
  pkts="$(ipt -L "${CHAIN}" -n -v -x 2>/dev/null \
    | awk -v p="${prefix%%: *}" '$0 ~ p { s += $1 } END { print s + 0 }')"
  if [[ "${pkts}" != "0" ]]; then
    err "  DIAGNOSIS: the rule DID match (${pkts} packet(s) counted for" \
        "${prefix%%: *}), so the chain is correct and the KERNEL LOG IS NOT"
    err "  READABLE from here. Check kernel.dmesg_restrict (currently" \
        "$(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null || echo '?')) and that"
    err "  'sudo dmesg' works for this user."
  else
    err "  DIAGNOSIS: the rule matched ZERO packets, so the probe never reached" \
        "it. The chain exists but is not on the path the packet took."
  fi
}

# ---------------------------------------------------------------------------
# Ring-buffer follower. The ring wraps; the follower is what makes the capture
# survive a long lane. `report` also snapshots, so a dead follower degrades to
# "whatever the ring still holds" rather than to nothing.
# ---------------------------------------------------------------------------
start_follower() {
  local mode_flag=""
  if dmesg --help 2>&1 | grep -q -- '--follow-new'; then
    mode_flag="--follow-new"
  elif dmesg --help 2>&1 | grep -q -- '--follow'; then
    mode_flag="--follow"
  else
    log "NOTE: dmesg has no --follow; relying on the report-time snapshot alone." \
        "A long lane may lose early lines to ring wrap."
    return 0
  fi
  # setsid+nohup so the follower outlives the emulator-runner step that starts
  # it and is still draining when the separate `report` step runs.
  setsid nohup sudo dmesg "${mode_flag}" >> "${FOLLOWER_LOG}" 2>/dev/null &
  echo $! > "${FOLLOWER_PID}"
  disown 2>/dev/null || true
  log "Ring-buffer follower started (dmesg ${mode_flag}, pid $(cat "${FOLLOWER_PID}"))."
}

stop_follower() {
  local pid
  [[ -f "${FOLLOWER_PID}" ]] || return 0
  pid="$(cat "${FOLLOWER_PID}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || return 0
  # The follower runs under sudo, so its children need sudo to die.
  sudo kill "${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
  sudo pkill -f 'dmesg --follow' 2>/dev/null || true
  rm -f "${FOLLOWER_PID}"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
do_install() {
  if [[ "${SKIP_GUARD:-}" == "1" ]]; then
    log "SKIP_GUARD=1 — skipping iptables rules AND observation (local dev mode)."
    mkdir -p "${EGRESS_DIR}"
    printf 'skipped=1\nmode=%s\n' "${MODE}" > "${STATE_FILE}"
    return "${RC_OK}"
  fi

  case "${MODE}" in
    observe | enforce) ;;
    *)
      err "ERROR: HAVEN_EGRESS_MODE must be 'observe' or 'enforce', got '${MODE}'."
      return "${RC_USAGE}"
      ;;
  esac

  if ! command -v iptables >/dev/null 2>&1; then
    err "UNOBSERVABLE: iptables not found; the egress guard cannot be installed," \
        "so this run can prove nothing about egress."
    return "${RC_UNOBSERVABLE}"
  fi
  if ! sudo -n true 2>/dev/null; then
    err "UNOBSERVABLE: no passwordless sudo; iptables rules cannot be installed."
    return "${RC_UNOBSERVABLE}"
  fi

  # Validate the allow-list on EVERY run, not only in enforce mode. A file that
  # is only parsed the day someone flips the switch is a file that is broken
  # the day someone flips the switch.
  if ! parse_allowlist "${ALLOWLIST}" >/dev/null; then
    err "UNOBSERVABLE: ${ALLOWLIST} is invalid (see errors above)."
    return "${RC_UNOBSERVABLE}"
  fi

  mkdir -p "${EGRESS_DIR}"
  : > "${FOLLOWER_LOG}"

  log "Installing egress guard: mode=${MODE}, strfry port=${STRFRY_PORT}."
  if [[ "${MODE}" == "observe" ]]; then
    log "  observe: TCP 80/443 REJECTed exactly as before; everything else is" \
        "RECORDED but permitted."
  else
    log "  enforce: only ${ALLOWLIST} is permitted; everything else REJECTed."
  fi

  detect_ct_match
  log "  conntrack match: ${CT_MATCH[*]}"

  install_chain ipt v4

  local v6_state="absent"
  if have_ip6tables; then
    # IPv6 egress bypassed the pre-C7 guard entirely, ports 80/443 included.
    # Best-effort in observe mode (a runner without the ip6 tables loaded must
    # not redden three lanes); MANDATORY in enforce mode, where an unguarded
    # address family is an open door disguised as a closed one.
    if install_chain ipt6 v6 2>/dev/null; then
      v6_state="installed"
    else
      v6_state="failed"
      if [[ "${MODE}" == "enforce" ]]; then
        err "ERROR: enforce mode requires the IPv6 chain, and it failed to install." \
            "Enforcing on IPv4 only would leave a documented bypass."
        return "${RC_UNOBSERVABLE}"
      fi
      log "  NOTE: ip6tables chain could not be installed; IPv6 egress is" \
          "neither blocked nor observed on this runner."
    fi
  else
    log "  NOTE: ip6tables absent; IPv6 egress is neither blocked nor observed."
  fi

  # --- G1: read-back. ---
  if ! verify_installed ipt "IPv4"; then
    err "UNOBSERVABLE: the IPv4 chain did not read back as installed."
    return "${RC_UNOBSERVABLE}"
  fi
  if [[ "${v6_state}" == "installed" ]] && ! verify_installed ipt6 "IPv6"; then
    err "UNOBSERVABLE: the IPv6 chain did not read back as installed."
    return "${RC_UNOBSERVABLE}"
  fi
  log "G1 ok: both LOG rules present and OUTPUT jumps to ${CHAIN}."

  start_follower

  # --- G2: does the chain actually SEE traffic, and does the line reach us? ---
  if ! send_probe "${PROBE_LO_ADDR}" "${PROBE_PORT}"; then
    err "UNOBSERVABLE: could not emit the loopback probe (no /dev/udp, no nc)."
    return "${RC_UNOBSERVABLE}"
  fi
  if ! await_log "${LOG_PREFIX_LO}" "DST=${PROBE_LO_ADDR}"; then
    err "G2 FAIL: a deliberate loopback datagram to ${PROBE_LO_ADDR}:${PROBE_PORT}" \
        "did NOT appear in the kernel log within ${PROBE_TIMEOUT}s."
    err "  Either way the guard is BLIND, and a blind guard that returns 0 is the"
    err "  exact failure this gate exists for."
    diagnose_probe_failure "${LOG_PREFIX_LO}"
    return "${RC_UNOBSERVABLE}"
  fi
  log "G2 ok: loopback traffic is observed."

  # --- G3: does a deliberate UNEXPECTED destination appear? ---
  if ! send_probe "${PROBE_EXT_ADDR}" "${PROBE_PORT}"; then
    err "UNOBSERVABLE: could not emit the external probe."
    return "${RC_UNOBSERVABLE}"
  fi
  if ! await_log "${LOG_PREFIX_EXT}" "DST=${PROBE_EXT_ADDR}"; then
    err "G3 FAIL: a deliberate egress to the unexpected destination" \
        "${PROBE_EXT_ADDR}:${PROBE_PORT} did NOT appear in the kernel log."
    err "  This guard's entire job is to notice exactly that, so it is not"
    err "  installed in any useful sense. Failing loudly rather than watching"
    err "  the drive with an instrument known not to work."
    diagnose_probe_failure "${LOG_PREFIX_EXT}"
    return "${RC_UNOBSERVABLE}"
  fi
  log "G3 ok: a deliberate egress to an unexpected destination (${PROBE_EXT_ADDR})" \
      "was recorded."

  {
    printf 'skipped=0\n'
    printf 'mode=%s\n' "${MODE}"
    printf 'v6=%s\n' "${v6_state}"
    printf 'probe_ext=%s\n' "${PROBE_EXT_ADDR}"
    printf 'installed_epoch=%s\n' "$(date +%s)"
    # G5's precondition, written only on the path that really touched the
    # kernel. `report` cross-checks its text parse against the chain's packet
    # counters ONLY when this marker is present, so the hermetic --self-test
    # (which fabricates a state file without it) cannot be scored against
    # whatever chains happen to exist on the machine running it.
    printf 'chain_installed=1\n'
  } > "${STATE_FILE}"

  log "Rules installed (IPv4):"
  ipt -L "${CHAIN}" -n -v --line-numbers
  log "Done. Observation is live; run '${SELF_PATH} report' after the drive."
  return "${RC_OK}"
}

# ---------------------------------------------------------------------------
# Parsing + reporting
# ---------------------------------------------------------------------------

# Turn merged kernel lines into "STREAM PROTO DST PORT UID" records.
# Tolerant of both the `[  123.456]` and `--time-format iso` prefixes because
# the follower and the snapshot may not agree on which is in force.
parse_records() {
  local file="$1"
  awk '
    /HAVEN_EGRESS_(EXT|LO):/ {
      stream = /HAVEN_EGRESS_EXT:/ ? "EXT" : "LO"
      proto = ""; dst = ""; dpt = "-"; uid = "-"
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^PROTO=/) { proto = substr($i, 7) }
        else if ($i ~ /^DST=/) { dst = substr($i, 5) }
        else if ($i ~ /^DPT=/) { dpt = substr($i, 5) }
        else if ($i ~ /^UID=/) { uid = substr($i, 5) }
      }
      if (dst == "") next
      if (proto == "") proto = "?"
      print stream, proto, dst, dpt, uid
    }
  ' "${file}"
}

# Merge follower + snapshot, de-duplicating on the message body (the leading
# timestamp differs between the two sources). Distinct flows keep distinct
# lines because the kernel stamps each with its own IP ID and source port.
merge_capture() {
  local snapshot="${EGRESS_DIR}/.snapshot.log"
  read_dmesg > "${snapshot}" 2>/dev/null || true
  {
    [[ -f "${FOLLOWER_LOG}" ]] && cat "${FOLLOWER_LOG}"
    cat "${snapshot}"
  } 2>/dev/null \
    | grep -a 'HAVEN_EGRESS_' \
    | sed -E 's/^(\[[^]]*\]|[0-9T:,+.-]+)[[:space:]]*//' \
    | awk '!seen[$0]++' \
    > "${RAW_LOG}" || true
  rm -f "${snapshot}"
}

# G5 — the kernel's own accounting, cross-checking our text parse.
log_rule_packets() {
  local counts
  counts="$(ipt -L "${CHAIN}" -n -v -x 2>/dev/null | awk '/LOG/ {s += $1} END {print s + 0}')"
  echo "${counts:-0}"
}

do_report() {
  mkdir -p "${EGRESS_DIR}"

  if [[ -f "${STATE_FILE}" ]] && grep -q '^skipped=1$' "${STATE_FILE}"; then
    log "SKIP_GUARD was set at install time; no observation was made."
    return "${RC_OK}"
  fi
  if [[ ! -f "${STATE_FILE}" ]]; then
    err "UNOBSERVABLE: no install state at ${STATE_FILE} — 'report' ran without a" \
        "successful 'install'. Nothing was recorded, so this run carries NO" \
        "evidence about egress."
    return "${RC_UNOBSERVABLE}"
  fi

  stop_follower
  merge_capture

  # --- G4: the capture must exist and be non-empty. ---
  if [[ ! -s "${RAW_LOG}" ]]; then
    err "UNOBSERVABLE: ${RAW_LOG} is absent or empty. The guard installed and" \
        "passed its probes, so an empty capture means the recorder died mid-lane."
    err "  An empty egress log is NOT an empty egress set — cf. backlog A4,"
    err "  where 'nothing to scan' was reported as 'nothing leaked'."
    return "${RC_UNOBSERVABLE}"
  fi

  local records lo_count ext_count
  records="$(parse_records "${RAW_LOG}")"
  lo_count="$(grep -c '^LO ' <<< "${records}" || true)"
  ext_count="$(grep -c '^EXT ' <<< "${records}" || true)"

  # The liveness gate is on the LOOPBACK stream, deliberately. An empty
  # EXTERNAL set is the HEALTHY result for a hermetic lane, so failing on it
  # would invert the guard; but a run whose loopback stream is empty saw
  # nothing at all, because every one of these lanes talks to adb, the
  # emulator console, the VM service and the relay over loopback continuously.
  #
  # It also CANNOT false-red on a quiet lane, which is what makes it safe to
  # make fatal: the follower is started BEFORE the G2 probe, so a successful
  # install has already deposited its own loopback record in this stream. A
  # zero here therefore never means "the lane was quiet" — it means records
  # that provably existed at install time are no longer in the capture, i.e.
  # the recorder died or its output was lost.
  if (( lo_count == 0 )); then
    err "UNOBSERVABLE: the capture holds ${ext_count} external record(s) but ZERO" \
        "loopback records. Every lane that installs this guard drives adb, the"
    err "  emulator console and the relay over loopback throughout, so a zero"
    err "  there means the recorder stopped, not that the lane went quiet."
    return "${RC_UNOBSERVABLE}"
  fi

  # --- G5: cross-check against the kernel's own counters. ---
  # Runs only when THIS script installed the chain (see chain_installed in
  # do_install). Two failures are distinguished, because they mean different
  # things: a chain that vanished (someone tore it down before the report, so
  # the capture's coverage of the drive is unknown) and a chain whose LOG rules
  # matched nothing (contradicting a non-empty capture, i.e. the chain was
  # reinstalled mid-lane and the counters restarted).
  local kernel_packets="not-cross-checked"
  if grep -q '^chain_installed=1$' "${STATE_FILE}"; then
    if ! ipt -L "${CHAIN}" -n >/dev/null 2>&1; then
      err "UNOBSERVABLE: install recorded chain_installed=1 but ${CHAIN} is gone." \
          "Something removed the guard before the report ran, so the capture's"
      err "  coverage of the drive cannot be established."
      return "${RC_UNOBSERVABLE}"
    fi
    kernel_packets="$(log_rule_packets)"
    if [[ "${kernel_packets}" == "0" ]]; then
      err "UNOBSERVABLE: the chain's LOG rules report 0 matched packets, which" \
          "contradicts a non-empty capture. The chain was probably reinstalled or"
      err "  flushed mid-lane, so the capture does not cover the drive."
      return "${RC_UNOBSERVABLE}"
    fi
  fi

  local allow_triples verdict=0 violations=0
  allow_triples="$(parse_allowlist "${ALLOWLIST}" || true)"

  # Aggregate EXTERNAL destinations. Loopback is summarised by count only —
  # it is the liveness proof, and enumerating it would bury the finding.
  local agg
  agg="$(grep '^EXT ' <<< "${records}" \
    | awk '{ key = $2 " " $3 " " $4 " " $5; c[key]++ } END { for (k in c) print c[k], k }' \
    | sort -k3,3 -k4,4n -k1,1nr || true)"

  {
    echo "# Haven E2E egress observation"
    echo "#"
    echo "# mode:            ${MODE}"
    echo "# window:          the flutter-drive step only (guard installed after AVD"
    echo "#                  boot, removed before artifact upload)"
    echo "# attribution:     UID/GID only. On a GitHub-hosted runner the emulator"
    echo "#                  (QEMU SLIRP proxies guest sockets), flutter drive, adb"
    echo "#                  and Gradle all share one UID, so NO line below can be"
    echo "#                  attributed to the Haven app specifically. Read every"
    echo "#                  row as 'contacted during the drive', never as 'Haven"
    echo "#                  contacted'."
    echo "# ipv6 chain:      $(grep '^v6=' "${STATE_FILE}" | cut -d= -f2)"
    echo "# loopback recs:   ${lo_count} (rate-limited to 20/min; liveness proof, not a census)"
    echo "# external recs:   ${ext_count} (complete: the EXT LOG rule is unrate-limited)"
    echo "# kernel LOG pkts: ${kernel_packets}"
    echo "#"
    echo "# The install-time probe to ${PROBE_EXT_ADDR} (RFC 5737 TEST-NET-1) is"
    echo "# expected below: it is this guard proving it can see an unexpected"
    echo "# destination. Its absence would have failed the lane at install."
    echo "#"
    echo "# count proto destination port uid verdict"
    if [[ -z "${agg}" ]]; then
      echo "(no external destinations observed)"
    else
      local c proto dst port uid mark
      while read -r c proto dst port uid; do
        [[ -z "${c}" ]] && continue
        if allowlist_permits "${dst}" "${proto}" "${port}" <<< "${allow_triples}"; then
          mark="allowed"
        elif [[ "${dst}" == "${PROBE_EXT_ADDR}" ]]; then
          mark="self-probe"
        else
          mark="UNLISTED"
          violations=$(( violations + 1 ))
        fi
        printf '%6s %-5s %-39s %-6s %-6s %s\n' "${c}" "${proto}" "${dst}" "${port}" "${uid}" "${mark}"
      done <<< "${agg}"
    fi
  } > "${SUMMARY}"

  cat "${SUMMARY}"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Egress observation (\`${MODE}\` mode)"
      echo
      echo '```'
      cat "${SUMMARY}"
      echo '```'
    } >> "${GITHUB_STEP_SUMMARY}" || true
  fi

  # Secret scan of what we are about to upload.
  #
  # `-j LOG` copies IP/transport HEADERS only, so no payload byte — no pubkey,
  # coordinate, event id or ciphertext — can reach these files by construction,
  # and the disclosure review in this file's header concludes nothing needs
  # stripping. It is scanned anyway because "anything an artifact carries gets
  # scanned" is this repo's standing rule, and a per-artifact exemption argued
  # from first principles is exactly the kind of reasoning that goes stale.
  #
  # Run HERE, on the success path only, rather than as a separate workflow step:
  # G4 has just established that these files exist and are non-empty, so the
  # scanner can never be handed nothing — which keeps its rc-3 ("no evidence")
  # reserved for real capture failures instead of firing as a duplicate red
  # every time the report itself already declared the run unobservable.
  local scanner="${SCRIPT_DIR}/scan-logs-for-secrets.sh"
  if [[ -x "${scanner}" || -f "${scanner}" ]]; then
    local scan_rc=0
    bash "${scanner}" "${RAW_LOG}" "${SUMMARY}" || scan_rc=$?
    if (( scan_rc != 0 )); then
      err ""
      err "ERROR: the egress capture did not pass the secret scan (rc=${scan_rc})." \
          "Refusing to treat it as publishable."
      return "${RC_VIOLATION}"
    fi
  fi

  if (( violations > 0 )); then
    if [[ "${MODE}" == "enforce" ]]; then
      err ""
      err "ERROR: ${violations} destination(s) outside ${ALLOWLIST} were observed" \
          "(marked UNLISTED above). Enforce mode treats that as a failure."
      verdict="${RC_VIOLATION}"
    else
      log ""
      log "NOTE: ${violations} destination(s) are not in ${ALLOWLIST}. In observe" \
          "mode this is RECORDED, not enforced — that is the point of the mode."
      log "Once the nightly baseline is stable, see ${ALLOWLIST} for the flip."
    fi
  fi

  return "${verdict}"
}

do_teardown() {
  stop_follower
  ipt -D OUTPUT -j "${CHAIN}" 2>/dev/null || true
  ipt -F "${CHAIN}" 2>/dev/null || true
  ipt -X "${CHAIN}" 2>/dev/null || true
  if have_ip6tables; then
    ipt6 -D OUTPUT -j "${CHAIN}" 2>/dev/null || true
    ipt6 -F "${CHAIN}" 2>/dev/null || true
    ipt6 -X "${CHAIN}" 2>/dev/null || true
  fi
  log "Egress guard removed (if it was present)."
  return "${RC_OK}"
}

# ---------------------------------------------------------------------------
# --self-test — hermetic. No iptables, no sudo, no network, no toolchain, so it
# runs in the toolchain-free repo-guards job alongside every other harness
# self-test.
#
# It exercises the parts that decide a VERDICT: the allow-list parser, the CIDR
# matcher, the kernel-line parser, and the report's exit codes. The kernel-side
# machinery (rules, probes) is proven at install time by G1-G3 on the real
# runner, which is the only place it can be proven.
# ---------------------------------------------------------------------------
expect_rc() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  ( "$@" ) >/dev/null 2>&1 || got=$?
  if [[ "${got}" != "${want}" ]]; then
    echo "SELF-TEST FAIL: ${desc} — expected rc=${want}, got rc=${got}" >&2
    return 1
  fi
  return 0
}

self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # ---- CIDR matcher ----
  _ipv4_in_cidr 127.0.0.53 127.0.0.0/8 || { echo "SELF-TEST FAIL: 127.0.0.53 not in 127.0.0.0/8" >&2; fail=1; }
  _ipv4_in_cidr 172.17.0.2 172.16.0.0/12 || { echo "SELF-TEST FAIL: 172.17.0.2 not in 172.16.0.0/12" >&2; fail=1; }
  ! _ipv4_in_cidr 172.32.0.1 172.16.0.0/12 || { echo "SELF-TEST FAIL: 172.32.0.1 matched 172.16.0.0/12" >&2; fail=1; }
  ! _ipv4_in_cidr 8.8.8.8 127.0.0.0/8 || { echo "SELF-TEST FAIL: 8.8.8.8 matched loopback" >&2; fail=1; }
  _ipv4_in_cidr 10.0.2.2 10.0.2.2 || { echo "SELF-TEST FAIL: bare-address match" >&2; fail=1; }
  # /32 and the boundary cases, where an off-by-one shift silently widens the net.
  _ipv4_in_cidr 1.2.3.4 1.2.3.4/32 || { echo "SELF-TEST FAIL: /32 exact" >&2; fail=1; }
  ! _ipv4_in_cidr 1.2.3.5 1.2.3.4/32 || { echo "SELF-TEST FAIL: /32 over-matched" >&2; fail=1; }
  _ipv4_in_cidr 192.0.2.255 192.0.2.0/24 || { echo "SELF-TEST FAIL: /24 upper edge" >&2; fail=1; }
  ! _ipv4_in_cidr 192.0.3.0 192.0.2.0/24 || { echo "SELF-TEST FAIL: /24 over-matched" >&2; fail=1; }

  # ---- allow-list parser: the two refusals that keep enforce mode honest ----
  local al="${tmp}/al.txt"
  printf '%s\n' '0.0.0.0/0 * *' > "${al}"
  if parse_allowlist "${al}" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: a default route was accepted into the allow-list" >&2
    echo "  (that single line silently turns enforce mode into a no-op)" >&2
    fail=1
  fi
  printf '%s\n' '2001:db8::/32 * *' > "${al}"
  if parse_allowlist "${al}" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: a non-/128 IPv6 CIDR was accepted (matcher cannot evaluate it)" >&2
    fail=1
  fi
  printf '%s\n' '1.2.3.0/24 tcp' > "${al}"
  if parse_allowlist "${al}" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: a 2-field line was accepted" >&2
    fail=1
  fi
  printf '%s\n' '1.2.3.0/24 sctp *' > "${al}"
  if parse_allowlist "${al}" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: an unknown proto was accepted" >&2
    fail=1
  fi
  # The REAL checked-in allow-list must parse — otherwise the flip is broken
  # on the day someone attempts it, which is the worst possible day to find out.
  if ! parse_allowlist "${SCRIPT_DIR}/egress-allowlist.txt" >/dev/null; then
    echo "SELF-TEST FAIL: the checked-in egress-allowlist.txt does not parse" >&2
    fail=1
  fi

  # ---- allowlist_permits ----
  local triples
  triples="$(printf '%s\n' '127.0.0.0/8 * *' '172.16.0.0/12 * *' '10.1.2.3 TCP 7777')"
  allowlist_permits 127.0.0.1 UDP 53 <<< "${triples}" || { echo "SELF-TEST FAIL: loopback not permitted" >&2; fail=1; }
  allowlist_permits 10.1.2.3 TCP 7777 <<< "${triples}" || { echo "SELF-TEST FAIL: exact host:port not permitted" >&2; fail=1; }
  ! allowlist_permits 10.1.2.3 TCP 443 <<< "${triples}" || { echo "SELF-TEST FAIL: wrong port permitted" >&2; fail=1; }
  ! allowlist_permits 10.1.2.3 UDP 7777 <<< "${triples}" || { echo "SELF-TEST FAIL: wrong proto permitted" >&2; fail=1; }
  ! allowlist_permits 93.184.216.34 TCP 443 <<< "${triples}" || { echo "SELF-TEST FAIL: public address permitted" >&2; fail=1; }

  # ---- kernel-line parser, against REAL iptables LOG output shapes ----
  local kmsg="${tmp}/kmsg.log"
  printf '%s\n' \
    '[ 1234.567890] HAVEN_EGRESS_LO: IN= OUT=lo SRC=127.0.0.1 DST=127.0.0.1 LEN=48 TOS=0x00 PREC=0x00 TTL=64 ID=1 DF PROTO=UDP SPT=40001 DPT=9 LEN=28 UID=1001 GID=1001' \
    '[ 1234.600000] HAVEN_EGRESS_EXT: IN= OUT=eth0 SRC=10.1.0.4 DST=192.0.2.1 LEN=48 TOS=0x00 PREC=0x00 TTL=64 ID=2 DF PROTO=UDP SPT=40002 DPT=9 LEN=28 UID=1001 GID=1001' \
    '[ 1240.000000] HAVEN_EGRESS_EXT: IN= OUT=eth0 SRC=10.1.0.4 DST=140.82.121.4 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=3 DF PROTO=TCP SPT=54321 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0 UID=1001 GID=1001' \
    '2026-08-05T00:00:01,000000+00:00 HAVEN_EGRESS_EXT: IN= OUT=eth0 SRC=10.1.0.4 DST=168.63.129.16 LEN=68 PROTO=UDP SPT=33001 DPT=53 LEN=48 UID=101 GID=103' \
    '[ 1241.000000] kernel: unrelated line that must be ignored' \
    > "${kmsg}"
  local parsed
  parsed="$(parse_records "${kmsg}")"
  [[ "$(grep -c '^EXT ' <<< "${parsed}")" == "3" ]] \
    || { echo "SELF-TEST FAIL: expected 3 EXT records, got $(grep -c '^EXT ' <<< "${parsed}")" >&2; fail=1; }
  [[ "$(grep -c '^LO ' <<< "${parsed}")" == "1" ]] \
    || { echo "SELF-TEST FAIL: expected 1 LO record" >&2; fail=1; }
  grep -q '^EXT TCP 140.82.121.4 443 1001$' <<< "${parsed}" \
    || { echo "SELF-TEST FAIL: TCP/443 record not parsed correctly" >&2; fail=1; }
  grep -q '^EXT UDP 168.63.129.16 53 101$' <<< "${parsed}" \
    || { echo "SELF-TEST FAIL: iso-timestamp UDP record not parsed correctly" >&2; fail=1; }
  # The unrelated kernel line must NOT become a record — a parser that matches
  # loosely would manufacture destinations and make the baseline unusable.
  [[ "$(wc -l <<< "${parsed}")" == "4" ]] \
    || { echo "SELF-TEST FAIL: parser produced $(wc -l <<< "${parsed}") records, want 4" >&2; fail=1; }

  # ---- report verdicts, end to end, through the real do_report ----
  # Each case gets its own EGRESS_DIR so state cannot leak between them.
  # Each case runs the REAL `main` in a child shell, like scan-logs-for-secrets.sh
  # does — the A4 defect lived in `main`'s arg loop, not in the function a
  # reach-in test would have called, and the same hole is available here.
  # HAVEN_EGRESS_NO_SNAPSHOT keeps it hermetic: no dmesg, no iptables, no sudo.
  _report_case() {
    local case_dir="$1" mode="$2" al_file="$3"
    ( set +e
      env EGRESS_DIR="${case_dir}" \
          HAVEN_EGRESS_MODE="${mode}" \
          HAVEN_EGRESS_ALLOWLIST="${al_file}" \
          HAVEN_EGRESS_NO_SNAPSHOT=1 \
          GITHUB_STEP_SUMMARY= \
          bash "${SELF_PATH}" report
      echo "rc=$?" )
  }

  local case_al="${tmp}/case-al.txt"
  printf '%s\n' '127.0.0.0/8 * *' '168.63.129.16 UDP 53' > "${case_al}"

  # (a) No install state at all → UNOBSERVABLE, never "clean".
  local d_a="${tmp}/case-a"
  mkdir -p "${d_a}"
  [[ "$(_report_case "${d_a}" observe "${case_al}" | tail -1)" == "rc=3" ]] \
    || { echo "SELF-TEST FAIL: report without install state did not return 3" >&2; fail=1; }

  # (b) Installed, but the capture is EMPTY → UNOBSERVABLE (backlog A4).
  local d_b="${tmp}/case-b"
  mkdir -p "${d_b}"
  printf 'skipped=0\nmode=observe\nv6=absent\n' > "${d_b}/.state.env"
  : > "${d_b}/.follower.log"
  [[ "$(_report_case "${d_b}" observe "${case_al}" | tail -1)" == "rc=3" ]] \
    || { echo "SELF-TEST FAIL: empty capture did not return 3" >&2; fail=1; }

  # (c) Capture holds EXT records but ZERO loopback records → UNOBSERVABLE.
  # This is the subtle one: external-only looks like a rich result, but every
  # lane here drives adb/console/relay over loopback continuously, so zero
  # loopback means the recorder stopped rather than the lane going quiet.
  local d_c="${tmp}/case-c"
  mkdir -p "${d_c}"
  printf 'skipped=0\nmode=observe\nv6=absent\n' > "${d_c}/.state.env"
  grep 'HAVEN_EGRESS_EXT' "${kmsg}" > "${d_c}/.follower.log"
  [[ "$(_report_case "${d_c}" observe "${case_al}" | tail -1)" == "rc=3" ]] \
    || { echo "SELF-TEST FAIL: loopback-less capture did not return 3" >&2; fail=1; }

  # (d) Healthy capture, unlisted destination, OBSERVE → 0 (recorded, not enforced).
  local d_d="${tmp}/case-d"
  mkdir -p "${d_d}"
  printf 'skipped=0\nmode=observe\nv6=absent\n' > "${d_d}/.state.env"
  cp "${kmsg}" "${d_d}/.follower.log"
  [[ "$(_report_case "${d_d}" observe "${case_al}" | tail -1)" == "rc=0" ]] \
    || { echo "SELF-TEST FAIL: observe mode failed on an unlisted destination" >&2; fail=1; }
  grep -q 'UNLISTED' "${d_d}/egress-summary.txt" \
    || { echo "SELF-TEST FAIL: observe mode did not RECORD the unlisted destination" >&2; fail=1; }
  # The self-probe must be labelled as such, not counted as a finding.
  grep -q "${PROBE_EXT_ADDR}.*self-probe" "${d_d}/egress-summary.txt" \
    || { echo "SELF-TEST FAIL: the install probe was not labelled self-probe" >&2; fail=1; }
  # ...and the allow-listed resolver must be labelled allowed.
  grep -q '168.63.129.16.*allowed' "${d_d}/egress-summary.txt" \
    || { echo "SELF-TEST FAIL: an allow-listed destination was not marked allowed" >&2; fail=1; }

  # (e) Same capture, ENFORCE → 1. This is the flip, proven to bite.
  local d_e="${tmp}/case-e"
  mkdir -p "${d_e}"
  printf 'skipped=0\nmode=enforce\nv6=absent\n' > "${d_e}/.state.env"
  cp "${kmsg}" "${d_e}/.follower.log"
  [[ "$(_report_case "${d_e}" enforce "${case_al}" | tail -1)" == "rc=1" ]] \
    || { echo "SELF-TEST FAIL: enforce mode did not fail on an unlisted destination" >&2; fail=1; }

  # (f) Enforce with everything allow-listed → 0. Proves (e) failed for the
  # right reason and that enforce is not simply always-red.
  local d_f="${tmp}/case-f" wide_al="${tmp}/wide-al.txt"
  mkdir -p "${d_f}"
  printf '%s\n' '127.0.0.0/8 * *' '168.63.129.16 UDP 53' '140.82.121.4 TCP 443' \
    "${PROBE_EXT_ADDR} UDP ${PROBE_PORT}" > "${wide_al}"
  printf 'skipped=0\nmode=enforce\nv6=absent\n' > "${d_f}/.state.env"
  cp "${kmsg}" "${d_f}/.follower.log"
  [[ "$(_report_case "${d_f}" enforce "${wide_al}" | tail -1)" == "rc=0" ]] \
    || { echo "SELF-TEST FAIL: enforce mode failed with a complete allow-list" >&2; fail=1; }

  # (g) Usage error stays distinct from every verdict.
  expect_rc 2 "unknown subcommand" bash "${SELF_PATH}" not-a-subcommand || fail=1

  if (( fail )); then
    echo "setup-network-guard: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "setup-network-guard: self-test passed (CIDR matcher, allow-list refusals," \
       "kernel-line parser, and all four report verdicts: unobservable/observe/enforce)."
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-install}"
  case "${cmd}" in
    install) do_install ;;
    report) do_report ;;
    teardown) do_teardown ;;
    --self-test) self_test ;;
    -h | --help)
      sed -n '/^# USAGE/,/^# *HAVEN_EGRESS_ALLOWLIST/p' "${SELF_PATH}"
      exit "${RC_OK}"
      ;;
    *)
      err "Usage: $0 [install|report|teardown|--self-test]"
      exit "${RC_USAGE}"
      ;;
  esac
}

main "$@"
