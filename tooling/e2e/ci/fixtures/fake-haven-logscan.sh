#!/usr/bin/env bash
#
# The ONE fake `haven-logscan` this tree's shell self-tests inject through
# HAVEN_LOGSCAN_BIN, standing in for the release binary
# (tooling/logscan/target/release/haven-logscan) in the toolchain-free jobs that
# cannot build it.
#
# ## Why it is checked in rather than printf'd inline
#
# Four self-tests used to write a fake of their own — two answering `seal` and
# `scan` and exiting 9 for anything else, two exiting 0 for ANY argv at all.
# None of them read a flag, so all four accepted argv the real binary refuses:
# a renamed flag, a new required argument or a changed exit code would have kept
# every self-test green while every lane went rc 2, or worse, while a gate
# stopped scanning. That is the shape that cost CI run 35536892150 a whole
# Android matrix, where `provision-android-sdk.sh`'s fake emulator was `exit 0`
# for any argv.
#
# So there is one fake, it models the real binary's ARGUMENT CONTRACT, and
# `tooling/logscan/tests/cli_contract.rs` drives the same argv table through
# this file and through the real binary in the one job that builds it, failing
# if either side moves alone. Every verdict below is MEASURED there.
#
# ## What is modelled
#
# Every verdict decidable from argv ALONE: the verb roster, the per-verb flag
# vocabulary, a flag missing its value, the `<key>=<value>` shapes, the numeric
# values, `--declared-plants`' two words, the required flags, and the three
# `scan` mode refusals — each rc 2, in the real binary's own order, with its
# reason on stderr.
#
# Plus the one SIDE EFFECT a shell self-test reads back afterwards: an accepted
# `scan` creates its `--report` path, truncating whatever was there, and
# answers rc 2 for a path it cannot write. That is what makes scan-logs.sh's
# "a leak verdict deleted the sinks and KEPT the findings report" an assertion
# about a file that exists. MEASURED against the release binary with
# `--rules-only` scans (2026-09-21): the report is written after the scan —
# empty on a clean one, on an absent sink and on an unmet line floor, one
# NDJSON object per finding on a leak — and a REFUSED invocation never touches
# it, leaving an existing file byte for byte. Only existence is modelled; the
# findings are a fact about the capture.
#
# ## What is deliberately NOT modelled
#
# Everything that is a fact about the CAPTURE or the POLICY rather than about
# argv, because a self-test runs in a scratch directory with no capture and no
# sealed manifest: the `--out` path discipline, the `create_new` refusal, an
# unreadable `--decl` (rc 3), an absent manifest (rc 4 — which the real binary
# answers BEFORE writing a report, so a caller staging FAKE_SCAN_RC=4 gets one
# where the binary would have left none), the declaration and
# line floors (rc 4), the mislabelled-channel refusal (rc 2), whether a `--sink`
# class exists (rc 2), and the scan verdict itself (rc 0/1/3/4). The caller
# stages that verdict with FAKE_SEAL_RC / FAKE_SCAN_RC; cli_contract.rs measures
# each unmodelled rule against the real binary, so every omission here is a
# listed exclusion rather than a silent gap.
#
# ## Interface
#
#   FAKE_SEAL_ARGV / FAKE_SCAN_ARGV  where an ACCEPTED invocation writes its
#       argv, one word per line, the verb first. Unset or empty means "do not
#       record". A REFUSED invocation records nothing, because it did nothing.
#   FAKE_SEAL_RC / FAKE_SCAN_RC      the verdict an accepted invocation
#       returns (default 0).
#
# Security Rule 15 applies to this file's own output as it does to the binary's:
# every message below names a FLAG and never a value, so a `--host-decl` or a
# `--sink` path cannot reach a job log through a refusal.
#
# Written for bash 3.2: the iOS lanes run the self-tests that inject this on
# macOS runners, whose /bin/bash has no mapfile, no associative arrays and no
# case conversion.

set -u

# The real binary answers an unrecognised first word with its whole usage block.
# The phrase the two share is what cli_contract.rs matches on; spelling out the
# block here would be a second copy to keep in step.
fake_usage() {
  echo "haven-logscan — runtime log-privacy scanner" >&2
  echo "this fake answers \`seal\` and \`scan\`, the verbs the lane scripts invoke" >&2
}

fake_refuse() { # <reason...>
  echo "haven-logscan: $*" >&2
  exit 2
}

fake_require_pair() { # <flag> <value> — a value the real parser splits at its FIRST `=`
  case "$2" in
    *=*) ;;
    *) fake_refuse "$1 needs <key>=<value>" ;;
  esac
}

fake_require_count() { # <flag> <value> <shape> — what follows the first `=` is a count
  # `+7` is deliberate: Rust's integer parse accepts a leading sign, and a fake
  # that refused it would disagree with the binary over a value neither rejects.
  # The sign is a bracket expression rather than `\+`, which is undefined in
  # POSIX ERE and so is not the same pattern on every regcomp this runs under.
  [[ "${2#*=}" =~ ^[+]?[0-9]+$ ]] || fake_refuse "$1 needs $3"
}

argv=("$@")
verb="${1:-}"
case "${verb}" in
  seal|scan) shift ;;
  *) fake_usage; exit 2 ;;
esac

have_run_id=0 have_out=0 sinks=0 have_manifest=0 rules_only=0 plants_in=0 exempt=0
flag='' val='' report=''
while [ $# -gt 0 ]; do
  flag="$1"
  case "${verb}:${flag}" in
    scan:--rules-only) rules_only=1; shift; continue ;;
    scan:--disclose-values) shift; continue ;;
    seal:--run-id|seal:--decl|seal:--host-decl|seal:--host-seed|seal:--declared-plants|\
    seal:--expect|seal:--floor|seal:--exempt-endpoint|seal:--out|\
    scan:--manifest|scan:--exempt-endpoint|scan:--sink|scan:--segments|\
    scan:--plants-in|scan:--report) ;;
    *) fake_refuse "unknown flag \`${flag}\`" ;;
  esac
  [ $# -ge 2 ] || fake_refuse "${flag} needs a value"
  val="$2"
  shift 2
  case "${flag}" in
    --run-id) have_run_id=1 ;;
    --out) have_out=1 ;;
    --manifest) have_manifest=1 ;;
    --report) report="${val}" ;;
    --exempt-endpoint) exempt=$(( exempt + 1 )) ;;
    --sink) fake_require_pair "${flag}" "${val}"; sinks=$(( sinks + 1 )) ;;
    --plants-in) fake_require_pair "${flag}" "${val}"; plants_in=$(( plants_in + 1 )) ;;
    --host-decl) fake_require_pair "${flag}" "${val}" ;;
    --expect)
      fake_require_pair "${flag}" "${val}"
      fake_require_count "${flag}" "${val}" '<class>=<min-count>'
      ;;
    --floor)
      fake_require_pair "${flag}" "${val}"
      fake_require_count "${flag}" "${val}" '<sink>=<min-lines>'
      ;;
    --segments)
      fake_require_pair "${flag}" "${val}"
      fake_require_count "${flag}" "${val}" '<class>=<count>'
      ;;
    --declared-plants)
      case "${val}" in
        dart|none) ;;
        *) fake_refuse "--declared-plants takes \`dart\` (a lane with the proxy's declaration channel) or \`none\`" ;;
      esac
      ;;
  esac
done

if [ "${verb}" = seal ]; then
  # The real binary reads --run-id before --out; a fixture that omits both must
  # be refused for the same one, or the two sides agree on rc and disagree on why.
  [ "${have_run_id}" = 1 ] || fake_refuse "seal needs --run-id"
  [ "${have_out}" = 1 ] || fake_refuse "seal needs --out"
  [ -z "${FAKE_SEAL_ARGV:-}" ] || printf '%s\n' "${argv[@]}" > "${FAKE_SEAL_ARGV}"
  exit "${FAKE_SEAL_RC:-0}"
fi

# scan. The vacuity check comes before the mode check, as it does in the real
# parser, so an invocation that is both sink-less and mis-moded is refused for
# the missing sink on both sides.
[ "${sinks}" -gt 0 ] || fake_refuse "scan needs at least one --sink"
if [ "${rules_only}" = 1 ]; then
  [ "${have_manifest}" = 0 ] \
    || fake_refuse "--rules-only and --manifest are mutually exclusive: one certifies that the rules ran, the other that a run's declared values are absent"
  [ "${plants_in}" = 0 ] \
    || fake_refuse "--plants-in reconciles positive controls, which --rules-only does not do; a flag that is silently ignored is a false claim of coverage"
else
  [ "${exempt}" = 0 ] \
    || fake_refuse "--exempt-endpoint belongs to \`seal\` when there is a manifest; only --rules-only takes it, because a rules-only scan has no seal to carry it"
fi
# Last, because the binary writes the report only once the scan is behind it:
# every refusal above leaves the path alone. The redirection's own message is
# discarded — it would name the path, and Rule 15 governs this file's output as
# it governs the binary's.
if [ -n "${report}" ]; then
  : > "${report}" 2>/dev/null || fake_refuse "cannot write the report"
fi
[ -z "${FAKE_SCAN_ARGV:-}" ] || printf '%s\n' "${argv[@]}" > "${FAKE_SCAN_ARGV}"
exit "${FAKE_SCAN_RC:-0}"
