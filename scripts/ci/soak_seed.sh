#!/usr/bin/env bash
#
# The ONE definition of a scheduled soak seed.
#
#   seed(profile, date, slot) = "0x" + sha256("<profile>|<date>|<slot>")[:16]
#
# ## Why this exists
#
# Two callers need the same seed for the same night: soak-nightly.yml's
# `prepare` job, which hands each matrix slot its seed, and the flakiness
# monitor, which names the seed each slot ran. A second copy of the formula is
# a copy that can be narrowed on its own, and the monitor would then name a
# seed no slot ran.
#
# 16 hex is the rig's `seed: u64`, which `parse_u64` accepts with its `0x`
# prefix — and never more: the banner is scanned as a `soak` sink, and
# logscan's structural rule S2 reds any 32–63 hex run. Every preimage (a
# profile name, the run's public `created_at`, a slot name) is public
# repository metadata, so the seed identifies a SHAPE, never a user, a circle
# or a device (Rule 15).
#
# ## The date is the RUN's created_at, never the local clock
#
# `--derive-run` reads `GET /repos/<repo>/actions/runs/<id>` and keeps the
# first ten characters of `created_at`. That value is fixed for the life of the
# run: this repository's one `run_attempt > 1` run (29182810586) answered the
# same `created_at` on attempt 2, nine hours after the re-run, while
# `/attempts/2` answered the re-run's own instant. So `/attempts/<n>` is
# NEVER read — a well-meaning "be precise" edit there would give a re-run a
# different seed, i.e. a different experiment under the same run id. A
# fixture runs this under a recording `gh` and fails if that URL appears.
# `date -u` is the one wrong answer (a matrix job crossing midnight, a re-run
# landing next day), so an API failure is exit 2 and never a fallback.
# `created_at` must end `Z`: the first ten characters are the UTC date only
# then.
#
# Usage:
#   soak_seed.sh --seed <profile> <YYYY-MM-DD> <slot>    pure; prints the seed
#   soak_seed.sh --derive-run <profile> <slot>...         reads GITHUB_RUN_ID,
#       GITHUB_REPOSITORY; writes seeds=/date=/slot_list= to $GITHUB_OUTPUT
#   soak_seed.sh --pinned-seed <seed> <slot>...           a workflow_dispatch
#       repro: every slot runs <seed>; NO network call, `date=` is empty
#   soak_seed.sh --prepare <profile>                      the workflow's entry:
#       SOAK_SLOT_COUNT (empty = DEFAULT_SLOTS, else 1-4) slots s1..sN, pinned when
#       SOAK_PINNED_SEED is non-empty, derived from the run otherwise
#   soak_seed.sh --default-slots                          the slots a scheduled
#       night runs, one per line — what the flakiness monitor expects a night
#       to hold, from the same constant --prepare reads
#   soak_seed.sh --self-test
#
# Exit codes: 0 done; 2 refused (bad argument, API failure, malformed
# created_at or seed, bad slot count). Nothing seed-shaped is printed or
# written on a refusal.
#
# Linux (`sha256sum`) — it runs on ubuntu-latest and the owner's machine.

set -euo pipefail

readonly SCRIPT_NAME='soak_seed.sh'
readonly MAX_SLOTS=4
# A scheduled night's slot count. Separate from the bound so the night-one
# checkpoint (a warm slot over 40 min cuts the night to two) is this one line
# and leaves a four-slot dispatch possible.
readonly DEFAULT_SLOTS=4
(( DEFAULT_SLOTS >= 1 && DEFAULT_SLOTS <= MAX_SLOTS )) || { printf 'soak_seed.sh: DEFAULT_SLOTS is outside 1-%s.\n' "${MAX_SLOTS}" >&2; exit 2; }

die() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

valid_profile() { [[ "$1" =~ ^(pr|nightly|weekly)$ ]]; }
valid_date()    { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }
valid_slot()    { [[ "$1" =~ ^s[1-4]$ ]]; }
valid_seed()    { [[ "$1" =~ ^0x[0-9a-f]{16}$ ]]; }

seed_of() { # <profile> <date> <slot>
  local digest
  digest="$(printf '%s|%s|%s' "$1" "$2" "$3" | sha256sum)"
  printf '0x%s\n' "${digest:0:16}"
}

check_slots() { # <slot>...
  (( $# >= 1 && $# <= MAX_SLOTS )) || die "a run takes 1 to ${MAX_SLOTS} slots."
  local s seen=' '
  for s in "$@"; do
    valid_slot "${s}" || die "a slot is named s1 to s${MAX_SLOTS}."
    [[ "${seen}" != *" ${s} "* ]] || die "a slot is named twice."
    seen="${seen}${s} "
  done
}

# `seeds=` / `date=` / `slot_list=` for $GITHUB_OUTPUT, composed in full before
# anything is written so a refusal leaves the file untouched.
emit() { # <date> <seed-or-empty> <profile> <slot>...
  local date="$1" pinned="$2" profile="$3" s seeds='' list='' seed
  shift 3
  [[ -n "${GITHUB_OUTPUT:-}" ]] || die 'GITHUB_OUTPUT is not set; nowhere to write the seeds.'
  for s in "$@"; do
    if [[ -n "${pinned}" ]]; then seed="${pinned}"; else seed="$(seed_of "${profile}" "${date}" "${s}")"; fi
    seeds="${seeds:+${seeds},}\"${s}\":\"${seed}\""
    list="${list:+${list},}\"${s}\""
  done
  printf 'seeds={%s}\ndate=%s\nslot_list=[%s]\n' "${seeds}" "${date}" "${list}" >>"${GITHUB_OUTPUT}"
  printf '%s: wrote the per-slot seeds to the step outputs.\n' "${SCRIPT_NAME}"
}

derive_run() { # <profile> <slot>...
  local profile="$1" created
  shift
  valid_profile "${profile}" || die 'unknown profile.'
  check_slots "$@"
  [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] || die 'GITHUB_RUN_ID is not a run id.'
  [[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'GITHUB_REPOSITORY is not owner/name.'
  created="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" --jq .created_at 2>/dev/null)" \
    || die "the run's created_at could not be read; refusing to fall back to the local clock."
  [[ "${created}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] \
    || die "the run's created_at is not an RFC 3339 UTC instant; refusing to guess a date."
  emit "${created:0:10}" '' "${profile}" "$@"
}

pinned_seed() { # <seed> <slot>...
  local seed="$1"
  shift
  valid_seed "${seed}" || die 'a pinned seed is 0x followed by 16 lowercase hex.'
  check_slots "$@"
  emit '' "${seed}" nightly "$@"
}

slots_upto() { # <n>: s1..s<n>, one per line
  local i
  for (( i = 1; i <= $1; i++ )); do printf 's%s\n' "${i}"; done
}

prepare() { # <profile>
  local profile="$1" n="${SOAK_SLOT_COUNT:-}" slots=()
  valid_profile "${profile}" || die 'unknown profile.'
  [[ -n "${n}" ]] || n="${DEFAULT_SLOTS}"
  # One nonzero digit, then the bound, BEFORE `(( ))` or the loop sees it: a
  # dispatch input reaching arithmetic unchecked is command substitution
  # (`a[$(…)]`), a leading zero is octal (`08` is an arithmetic error, not a
  # refusal), and an unbounded count builds its array before check_slots can
  # refuse it.
  [[ "${n}" =~ ^[1-9]$ ]] && (( n <= MAX_SLOTS )) || die "a run takes 1 to ${MAX_SLOTS} slots."
  mapfile -t slots < <(slots_upto "${n}")
  if [[ -n "${SOAK_PINNED_SEED:-}" ]]; then
    pinned_seed "${SOAK_PINNED_SEED}" "${slots[@]}"
  else
    derive_run "${profile}" "${slots[@]}"
  fi
}

# ---------------------------------------------------------------------------
# --self-test — hermetic: `gh` is a stub on PATH that records its argv.
# ---------------------------------------------------------------------------

# Pinned by equality against the fixtures that ran, because a fixture that
# stops running is the one way a deleted fixture reports success.
readonly SELF_TEST_FIXTURES=29

self_test() {
  local tmp fails=0 n=0 self
  self="${BASH_SOURCE[0]}"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _ok() { # <0-if-passed> <label>
    n=$((n + 1))
    if [[ "$1" == 0 ]]; then printf '  PASS %s\n' "$2"; else printf '  FAIL %s\n' "$2" >&2; fails=1; fi
  }
  # <condition> is evaluated in this scope, so a fixture reads as one sentence.
  _c() { if eval "$1"; then echo 0; else echo 1; fi; }

  local bin="${tmp}/bin" calls="${tmp}/calls" out="${tmp}/out" err="${tmp}/err" gho="${tmp}/gho"
  mkdir -p "${bin}"
  # STUB_MODE: ok (prints STUB_CREATED), fail (an unreachable API).
  cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CALLS}"
if [[ "${STUB_MODE}" == fail ]]; then
  printf 'error connecting to api.github.com\n' >&2
  exit 1
fi
printf '%s\n' "${STUB_CREATED}"
STUB
  chmod +x "${bin}/gh"

  _run() { # <stub-mode> <created_at> <script args...>; env via caller
    local mode="$1" created="$2" rc=0
    shift 2
    : >"${calls}"; : >"${out}"; : >"${err}"; : >"${gho}"
    PATH="${bin}:${PATH}" STUB_CALLS="${calls}" STUB_MODE="${mode}" STUB_CREATED="${created}" \
      GITHUB_OUTPUT="${gho}" GITHUB_RUN_ID="${RUN_ID-35000000001}" \
      GITHUB_REPOSITORY="${REPO-owner/repo}" GITHUB_RUN_ATTEMPT=2 \
      bash "${self}" "$@" >"${out}" 2>"${err}" || rc=$?
    echo "${rc}"
  }
  _no_seed_anywhere() { ! grep -qE '0x[0-9a-f]{16}' "${out}" "${err}" "${gho}"; }

  printf 'self-test: %s\n' "${SCRIPT_NAME}"

  # (1) THE KNOWN VECTOR, from a second, independent expression: Python's
  #     hashlib (`hashlib.sha256(b"nightly|2026-07-12|s1").hexdigest()[:16]`),
  #     cross-checked with `openssl dgst -sha256`, never this script's pipeline.
  local a b c d
  a="$(bash "${self}" --seed nightly 2026-07-12 s1)"
  _ok "$(_c '[[ "${a}" == 0x3cc8bd9e9ea551e0 ]]')" \
      '(1) the known vector matches an independently computed digest'

  b="$(bash "${self}" --seed nightly 2026-07-12 s2)"
  c="$(bash "${self}" --seed nightly 2026-07-13 s1)"
  d="$(bash "${self}" --seed weekly 2026-07-12 s1)"
  _ok "$(_c '[[ "${a}" != "${b}" ]]')" '(2) the slot changes the seed'
  _ok "$(_c '[[ "${a}" != "${c}" ]]')" '(3) the date changes the seed'
  _ok "$(_c '[[ "${a}" != "${d}" ]]')" '(4) the profile changes the seed'
  local shape=0 s
  for s in "${a}" "${b}" "${c}" "${d}"; do
    [[ "${s}" =~ ^0x[0-9a-f]{16}$ && ${#s} -eq 18 ]] || shape=1
  done
  _ok "${shape}" '(5) every seed is exactly 0x + 16 lowercase hex, length 18'
  bash "${self}" --seed nightly 2026-07-12 s3 >"${tmp}/d1"
  bash "${self}" --seed nightly 2026-07-12 s3 >"${tmp}/d2"
  _ok "$(_c 'cmp -s "${tmp}/d1" "${tmp}/d2"')" '(6) --seed is byte-identical across runs'

  local rc want
  rc="$(_run ok 2026-07-12T06:32:34Z --derive-run nightly s1 s2)"
  want="seeds={\"s1\":\"${a}\",\"s2\":\"${b}\"}
date=2026-07-12
slot_list=[\"s1\",\"s2\"]"
  _ok "$(_c '[[ "${rc}" == 0 && "$(cat "${gho}")" == "${want}" ]]')" \
      '(7) --derive-run writes each slot the seed --seed gives for the run date'
  # (8) THE /attempts/ TRAP. GITHUB_RUN_ATTEMPT=2 is in the environment, which
  #     is the temptation; the one call made must be the run itself.
  _ok "$(_c '[[ "$(cat "${calls}")" == "api repos/owner/repo/actions/runs/35000000001 --jq .created_at" ]]')" \
      '(8) exactly one API call, for the RUN — no /attempts/ URL is constructed'
  cp "${gho}" "${tmp}/g1"
  _run ok 2026-07-12T06:32:34Z --derive-run nightly s1 s2 >/dev/null
  _ok "$(_c 'cmp -s "${gho}" "${tmp}/g1"')" '(9) --derive-run is byte-identical across runs'
  rc="$(_run ok 2026-07-12T23:59:59.123Z --derive-run nightly s1)"
  _ok "$(_c '[[ "${rc}" == 0 ]] && grep -qx "date=2026-07-12" "${gho}"')" \
      '(10) fractional seconds keep the UTC date'

  rc="$(_run fail '' --derive-run nightly s1 s2)"
  _ok "$(_c '[[ "${rc}" == 2 ]] && _no_seed_anywhere && [[ ! -s "${gho}" ]]')" \
      '(11) an unreachable API exits 2, prints no seed and writes no output'
  rc="$(_run ok 'Sun Jul 12 06:32:34 UTC 2026' --derive-run nightly s1)"
  _ok "$(_c '[[ "${rc}" == 2 ]] && _no_seed_anywhere && [[ ! -s "${gho}" ]]')" \
      '(12) a non-RFC-3339 created_at exits 2 and prints no seed'
  rc="$(_run ok 2026-07-12T23:32:34-05:00 --derive-run nightly s1)"
  _ok "$(_c '[[ "${rc}" == 2 ]] && _no_seed_anywhere')" \
      '(13) an offset created_at exits 2 (its first ten characters are not the UTC date)'
  rc="$(RUN_ID='' _run ok 2026-07-12T06:32:34Z --derive-run nightly s1)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${calls}" ]]')" \
      '(14) no GITHUB_RUN_ID exits 2 before any API call'

  rc="$(_run ok 2026-07-12T06:32:34Z --derive-run nightly s1 s2 s3 s4 s1)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${gho}" ]]')" '(15) five slots exit 2'
  rc="$(_run ok 2026-07-12T06:32:34Z --derive-run nightly)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${gho}" ]]')" '(16) zero slots exit 2'
  rc="$(_run ok 2026-07-12T06:32:34Z --derive-run nightly s1 s1)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${gho}" ]]')" '(17) a slot named twice exits 2'

  rc="$(_run ok '' --pinned-seed 0x0123456789abcdef s1 s2 s3)"
  want='seeds={"s1":"0x0123456789abcdef","s2":"0x0123456789abcdef","s3":"0x0123456789abcdef"}
date=
slot_list=["s1","s2","s3"]'
  _ok "$(_c '[[ "${rc}" == 0 && "$(cat "${gho}")" == "${want}" && ! -s "${calls}" ]]')" \
      '(18) a pinned seed runs on every slot and makes no API call'
  rc="$(_run ok '' --pinned-seed 0x0123456789abcdef0123456789abcdef s1)"
  _ok "$(_c '[[ "${rc}" == 2 ]] && _no_seed_anywhere')" \
      '(19) a 32-hex pinned seed exits 2 and is not echoed'
  rc="$(_run ok '' --pinned-seed 0x0123456789ABCDEF s1)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${gho}" ]]')" '(20) an upper-case pinned seed exits 2'

  rc="$(SOAK_SLOT_COUNT='' SOAK_PINNED_SEED='' _run ok 2026-07-12T06:32:34Z --prepare nightly)"
  _ok "$(_c '[[ "${rc}" == 0 ]] && grep -qxF "slot_list=[\"s1\",\"s2\",\"s3\",\"s4\"]" "${gho}"')" \
      '(21) --prepare on a schedule (no inputs) derives four slots'
  rc="$(SOAK_SLOT_COUNT=2 SOAK_PINNED_SEED=0x0123456789abcdef _run ok 2026-07-12T06:32:34Z --prepare nightly)"
  _ok "$(_c '[[ "${rc}" == 0 && ! -s "${calls}" ]] && grep -qxF "slot_list=[\"s1\",\"s2\"]" "${gho}"')" \
      '(22) --prepare with a pinned seed honours the slot count and makes no API call'
  rc="$(SOAK_SLOT_COUNT=5 _run ok 2026-07-12T06:32:34Z --prepare nightly)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${calls}" ]]')" \
      '(23) --prepare with slots outside 1-4 exits 2 before any API call'
  rc="$(SOAK_SLOT_COUNT="a[\$(touch ${tmp}/pwned)]" _run ok 2026-07-12T06:32:34Z --prepare nightly)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -e "${tmp}/pwned" && ! -s "${calls}" ]]')" \
      '(24) a non-numeric slot count is refused before arithmetic can run it'
  rc=0; bash "${self}" --seed nightly 2026-7-12 s1 >"${out}" 2>&1 || rc=$?
  : >"${err}"; : >"${gho}"
  _ok "$(_c '[[ "${rc}" == 2 ]] && _no_seed_anywhere')" '(25) --seed refuses a malformed date'
  rc="$(SOAK_SLOT_COUNT=08 _run ok 2026-07-12T06:32:34Z --prepare nightly)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${calls}" && ! -s "${gho}" && "$(cat "${err}")" == "${SCRIPT_NAME}: a run takes 1 to ${MAX_SLOTS} slots." ]]')" \
      '(26) a zero-padded slot count is this script'"'"'s refusal alone, never an octal arithmetic error'
  rc="$(SOAK_SLOT_COUNT=1000000000 _run ok 2026-07-12T06:32:34Z --prepare nightly)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${calls}" && ! -s "${gho}" ]]')" \
      '(27) a huge slot count is refused before any slot list is built'
  rc="$(SOAK_SLOT_COUNT=0 _run ok 2026-07-12T06:32:34Z --prepare nightly)"
  _ok "$(_c '[[ "${rc}" == 2 && ! -s "${calls}" ]]')" '(28) a slot count of zero is refused'
  # (29) The monitor's expectation and a scheduled night's slots are one list.
  local listed json
  rc=0; listed="$(bash "${self}" --default-slots 2>/dev/null)" || rc=$?
  json="$(printf '"%s",' ${listed})"
  SOAK_SLOT_COUNT='' SOAK_PINNED_SEED='' _run ok 2026-07-12T06:32:34Z --prepare nightly >/dev/null
  _ok "$(_c '[[ "${rc}" == 0 && -n "${listed}" ]] && grep -qxF "slot_list=[${json%,}]" "${gho}"')" \
      '(29) --default-slots prints exactly the slots --prepare derives for a scheduled night'

  if (( fails )); then echo 'self-test: FAILED' >&2; return 1; fi
  if (( n != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${n} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin." >&2
    return 1
  fi
  echo "self-test: OK (${n}/${SELF_TEST_FIXTURES} fixtures)"
}

case "${1:-}" in
  --seed)
    (( $# == 4 )) || die 'usage: --seed <profile> <YYYY-MM-DD> <slot>'
    valid_profile "$2" || die 'unknown profile.'
    valid_date "$3" || die 'a date is YYYY-MM-DD.'
    valid_slot "$4" || die "a slot is named s1 to s${MAX_SLOTS}."
    seed_of "$2" "$3" "$4"
    ;;
  --derive-run)  (( $# >= 2 )) || die 'usage: --derive-run <profile> <slot>...'; shift; derive_run "$@" ;;
  --pinned-seed) (( $# >= 2 )) || die 'usage: --pinned-seed <seed> <slot>...'; shift; pinned_seed "$@" ;;
  --prepare)     (( $# == 2 )) || die 'usage: --prepare <profile>'; prepare "$2" ;;
  --default-slots) (( $# == 1 )) || die 'usage: --default-slots'; slots_upto "${DEFAULT_SLOTS}" ;;
  --self-test)   self_test ;;
  *)             die 'usage: --seed | --derive-run | --pinned-seed | --prepare | --default-slots | --self-test (see the header)' ;;
esac
