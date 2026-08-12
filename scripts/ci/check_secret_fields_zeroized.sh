#!/usr/bin/env bash
# CI guard: a secret-shaped struct field must be zeroized (Security Rule 7 —
# "use `Zeroizing<T>` for secret bytes; structs holding secrets must derive
# `ZeroizeOnDrop`").
#
# ## Why source-scanning, when a compile-time test already exists
#
# `haven-core/tests/zeroization_security.rs` instantiates
# `assert_zeroize_on_drop::<T>()` for a HAND-MAINTAINED list of types. That is
# the strongest possible proof for the types on it — a removed derive fails to
# compile — and it says nothing whatever about the type somebody adds tomorrow.
# It has never grown past two entries while the tree grew to five secret-bearing
# types, and one of the two (`EphemeralKeypair`) has had no production caller
# since the Dark Matter migration, so the list was simultaneously incomplete and
# partly aimed at dead code.
#
# The two checks are complements, not substitutes: the test proves the derive
# WORKS, this proves nobody added a raw secret field without one. Rule 7 is a
# property of every struct in the tree, so its guard has to be a scan.
#
# ## What counts as a secret-shaped field
#
# A field whose TYPE is a raw byte/string container (`[u8; N]`, `Vec<u8>`,
# `String`, `Box<[u8]>`, `&[u8]`, `&str`) and whose NAME — or whose enclosing
# STRUCT's name — reads as secret material (`secret`, `seed`, `salt`, `keypair`,
# `passphrase`, a `*_key`/`key_*` shape, …). Public-by-design shapes are
# excluded by name (`pubkey`, `key_id`, `key_package` — a KeyPackage is
# published as kind 30443 — `keyring`, `keystore`).
#
# The struct name matters as much as the field name: `ProfileRelaySalt { bytes:
# [u8; 32] }` is the per-install unlinkability secret and its field is called
# `bytes`. A field-name-only rule would have missed it entirely.
#
# Composed fields (`keypair: IdentityKeypair`) are deliberately NOT flagged: the
# obligation belongs to the inner type, and the inner type is scanned by this
# same guard. Every raw container in the tree is therefore covered, and
# composition is handled by induction rather than by a type whitelist that would
# rot exactly like the one above.
#
# The boundary a name-shaped scan cannot cross: a secret whose field name says
# nothing (`ProcessedAvatar.canonical` is decrypted image plaintext). Those keep
# their `Zeroizing<…>` by review and by a per-field projection witness in
# `haven-core/tests/zeroization_security.rs` (RM-Z2), whose return type is the
# wrapper — so demoting one of those fields is a build error, not a silent
# change this scan cannot see.
#
# ## Suppressing a reviewed field
#
#   pub key_id: String,  // zeroize-ok: a keyring entry name, never the secret
#
# The marker must sit on the field's own line or the line immediately above it,
# and must carry a reason — it cannot be hoisted to bless a whole struct.
#
# Exit codes:
#   0  all checks pass
#   1  a secret-shaped field is neither `Zeroizing`-wrapped nor in a
#      `ZeroizeOnDrop` struct
#   2  expected paths missing / self-test failed (the guard itself is broken)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_secret_fields_zeroized'

# Anti-vacuity floors. A scan that has stopped recognising `struct` bodies
# reports "0 secret fields, all zeroized" and looks identical to a clean tree,
# which is the failure mode every guard in repo-guards.yml carries a floor for.
# Measured when this landed: 143 structs, 5 secret-shaped fields. Both floors
# keep real headroom on purpose — a floor set at the measured value is a
# tripwire that reds on ordinary churn instead of on a broken scan.
readonly MIN_STRUCTS=110
readonly MIN_SECRET_FIELDS=3

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

read -r -d '' SCAN_AWK <<'AWK' || true
BEGIN {
  SECRET = "(secret|privkey|priv_key|private_key|seckey|nsec|passphrase|password|seed|psk|entropy|exporter|salt|keypair)"
  # `key`, `keys`, `db_key`, `key_bytes`, `group_event_key`.
  KEYLIKE = "^([a-z0-9_]*_)?keys?(_[a-z0-9_]*)?$"
  # Checked FIRST: these are public protocol material or identifiers.
  PUBLIC = "(pubkey|public_key|npub|key_id|key_slot|key_package|keyring|keystore)"
  # A raw container: bytes or text this code owns outright. Anything else is a
  # composed type whose own definition carries the obligation.
  RAW = "(\\[[ \t]*u8[ \t]*;|Vec<u8>|String|Box<\\[u8\\]>|&\\[u8\\]|&str)"
  MARKER = "zeroize-ok:[ \t]*[^ \t]"
}

function secret_shaped(name) {
  if (name ~ PUBLIC) return 0
  return (name ~ SECRET || name ~ KEYLIKE)
}

# A field named for public material vetoes the struct-name rule: `IdentityKeypair`
# is secret-shaped as a whole, but naming its `pubkey_bytes` in the failure would
# make the report argue for zeroizing a published value.
function public_shaped(name) { return (name ~ PUBLIC) }

# `ProfileRelaySalt` -> `profile_relay_salt`, so one vocabulary serves both a
# snake_case field name and a CamelCase struct name.
function decamel(s,   i, n, c, p, out) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c ~ /[A-Z]/) {
      p = (i > 1) ? substr(s, i - 1, 1) : "_"
      if (p ~ /[a-z0-9]/) out = out "_"
    }
    out = out c
  }
  return tolower(out)
}

FNR == 1 { instruct = 0; attrs = ""; prev_supp = 0 }
{
  line = $0
  sub(/[ \t\r]*$/, "", line)
  supp_here = (line ~ MARKER)
  code = line
  sub(/\/\/.*$/, "", code)

  if (!instruct) {
    # Attributes accumulate until the item they decorate; a blank or code line
    # that is not a struct header discards them, so a derive cannot drift onto
    # the NEXT type.
    if (code ~ /^[ \t]*#\[/) { attrs = attrs " " code; prev_supp = supp_here; next }
    if (line ~ /^[ \t]*(\/\/|\/\*|\*)/) { prev_supp = supp_here; next }
    if (match(code, /(^|[ \t])struct[ \t]+[A-Za-z_][A-Za-z0-9_]*/) && code ~ /\{[ \t]*$/) {
      instruct = 1
      zod = (attrs ~ /ZeroizeOnDrop/)
      sname = substr(code, RSTART, RLENGTH); sub(/^.*struct[ \t]+/, "", sname)
      s_secret = secret_shaped(decamel(sname))
      structs++
      attrs = ""
      prev_supp = supp_here
      next
    }
    attrs = ""
    prev_supp = supp_here
    next
  }

  if (code ~ /^[ \t]*\}/) { instruct = 0; prev_supp = supp_here; next }
  if (line ~ /^[ \t]*(\/\/|#\[|\/\*|\*)/) { prev_supp = supp_here; next }

  if (match(code, /^[ \t]*(pub([ \t]*\([^)]*\))?[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
    fname = substr(code, RSTART, RLENGTH)
    # The trailing `[ \t]+` is load-bearing: without it the visibility strip
    # eats the `pub` out of `pubkey` and turns a public key into `key`.
    sub(/^[ \t]*/, "", fname); sub(/^pub([ \t]*\([^)]*\))?[ \t]+/, "", fname); sub(/[ \t]*:$/, "", fname)
    ftype = substr(code, RSTART + RLENGTH)
    dfname = decamel(fname)
    if (ftype ~ RAW && !public_shaped(dfname) && (secret_shaped(dfname) || s_secret)) {
      secrets++
      if (ftype !~ /Zeroizing</ && !zod && !(prev_supp || supp_here))
        printf "%s:%d: %s.%s is a raw secret container with no Zeroizing<> and no ZeroizeOnDrop on %s\n", \
          FILENAME, FNR, sname, fname, sname
    }
  }
  prev_supp = supp_here
}
END { printf "#structs %d\n#secrets %d\n", structs, secrets }
AWK
readonly SCAN_AWK

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state.
#
# The critical fixtures are the two shapes the compile-time whitelist cannot
# see: a NEW type with a raw secret field and no derive, and a `Zeroizing<>`
# demoted to a bare container. The rest pin the false-positive directions,
# because a Rule-7 scan that flags every `String` named `key` is one that gets
# blanket-suppressed.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # `want` is the EXACT number of findings, not a boolean: an over-eager rule
  # that reports a published field beside the secret one is a report nobody can
  # act on, and a boolean would call it a pass.
  _case() { # _case <label> <expect-findings> <content>
    local label="$1" want="$2" content="$3" out got
    printf '%s' "${content}" > "${tmp}/f.rs"
    out="$(awk "${SCAN_AWK}" "${tmp}/f.rs")"
    got=$(grep -cv '^#' <<<"${out}" || true)
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want %d finding(s), got %d)\n' "${label}" "${want}" "${got}" >&2
      printf '%s\n' "${out}" | sed 's/^/        /' >&2
      fails=1
    fi
  }

  # THE fixture this guard exists for: a new secret-bearing type, no derive.
  _case "a raw secret field with no derive FAILS" 1 \
'pub struct SessionKeys {
    secret_bytes: [u8; 32],
}
'
  # ...and the regression on an existing one: `Zeroizing<Vec<u8>>` demoted.
  _case "a demoted Zeroizing wrapper FAILS" 1 \
'pub struct Signer {
    signing_key: Vec<u8>,
}
'
  # The struct name is the only secret-shaped name in ProfileRelaySalt.
  _case "a secret-shaped STRUCT name with a neutral field FAILS" 1 \
'pub struct ProfileRelaySalt {
    bytes: [u8; 32],
}
'
  _case "ZeroizeOnDrop on the struct passes" 0 \
'#[derive(Clone, ZeroizeOnDrop)]
pub struct IdentityKeypair {
    secret_bytes: [u8; 32],
    key_bytes: [u8; 32],
}
'
  _case "a Zeroizing-wrapped field passes" 0 \
'pub struct LiveSyncCore {
    salt: Zeroizing<[u8; 16]>,
}
'
  # A derive must not drift onto the next type — the shape that would silently
  # bless every struct following a zeroized one.
  _case "a derive does not carry to the NEXT struct" 1 \
'#[derive(ZeroizeOnDrop)]
pub struct Safe {
    secret_bytes: [u8; 32],
}

pub struct Unsafe {
    secret_bytes: [u8; 32],
}
'
  _case "a public key is not a secret" 0 \
'pub struct Contact {
    pubkey: String,
    public_key: Vec<u8>,
}
'
  # The struct-name rule must not drag a published value into the report: only
  # `secret_bytes` here is the finding.
  _case "a public field inside a secret-shaped struct is not the finding" 1 \
'pub struct IdentityKeypair {
    secret_bytes: [u8; 32],
    pubkey_bytes: [u8; 32],
}
'
  # A KeyPackage is published as kind 30443; flagging it would make the guard
  # look wrong on its first real run.
  _case "a KeyPackage blob is not a secret" 0 \
'pub struct StoredKeyPackage {
    key_package: Vec<u8>,
    key_package_json: String,
}
'
  # Composition: the obligation belongs to the inner type, which this same scan
  # covers. Flagging here would force a type whitelist — the exact thing this
  # guard replaces.
  _case "a composed secret type is left to its own definition" 0 \
'pub struct Manager {
    signing_key: IdentityKeypair,
    keypair: EphemeralKeypair,
}
'
  _case "a non-secret raw field passes" 0 \
'pub struct Circle {
    name: String,
    nostr_group_id: String,
}
'
  _case "an inline suppression with a reason passes" 0 \
'pub struct Entry {
    key_hex: String,  // zeroize-ok: a keyring entry name, never the secret
}
'
  _case "a suppression with NO reason does not suppress" 1 \
'pub struct Entry {
    // zeroize-ok:
    key_hex: String,
}
'
  # A file-level marker must not bless the struct below it.
  _case "a distant suppression does NOT blanket the struct" 1 \
'// zeroize-ok: this whole file is fine, honest
pub struct Entry {
    name: String,
    secret_key: Vec<u8>,
}
'
  # A doc comment describing the rule must not satisfy the rule.
  _case "prose mentioning ZeroizeOnDrop is not a derive" 1 \
'/// Secret bytes are zeroized on drop via `ZeroizeOnDrop`.
pub struct Signer {
    secret_bytes: [u8; 32],
}
'
  # A commented-out field is not a field.
  _case "a commented-out field is not scanned" 0 \
'pub struct Signer {
    // secret_bytes: [u8; 32],
    name: String,
}
'

  log "self-test: anti-vacuity counters"
  local out
  printf 'pub struct A {\n    name: String,\n}\n' > "${tmp}/one.rs"
  out="$(awk "${SCAN_AWK}" "${tmp}/one.rs")"
  if [[ "$(sed -n 's/^#structs //p' <<<"${out}")" == "1" ]]; then
    printf '  \033[1;32mPASS\033[0m the scan reports its struct count\n'
  else
    printf '  \033[1;31mFAIL\033[0m expected #structs 1\n' >&2; fails=1
  fi
  # An `enum`-only file must collapse the count, which is what the floor turns
  # into a red when the struct extractor stops matching.
  printf 'pub enum A {\n    B,\n}\n' > "${tmp}/none.rs"
  out="$(awk "${SCAN_AWK}" "${tmp}/none.rs")"
  if [[ "$(sed -n 's/^#structs //p' <<<"${out}")" == "0" ]]; then
    printf '  \033[1;32mPASS\033[0m a file with no structs collapses the count (floor reds)\n'
  else
    printf '  \033[1;31mFAIL\033[0m expected #structs 0\n' >&2; fails=1
  fi

  if (( fails )); then
    fail "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (18 fixtures)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  local core="${REPO_ROOT}/haven-core/src"
  local ffi="${REPO_ROOT}/haven/rust_builder/src"
  [[ -d "${core}" ]] || misconfig "${core} not found"
  [[ -d "${ffi}"  ]] || misconfig "${ffi} not found"

  local -a files
  mapfile -t files < <(find "${core}" "${ffi}" -name '*.rs' ! -name 'frb_generated.rs' | sort)
  (( ${#files[@]} > 0 )) || misconfig "no Rust sources found under ${core} / ${ffi}"

  local out structs secrets hits
  out="$(awk "${SCAN_AWK}" "${files[@]}")"
  structs="$(sed -n 's/^#structs //p' <<<"${out}")"
  secrets="$(sed -n 's/^#secrets //p' <<<"${out}")"
  hits="$(grep -v '^#' <<<"${out}" || true)"

  if (( structs < MIN_STRUCTS )) || (( secrets < MIN_SECRET_FIELDS )); then
    fail "scanned ${structs} struct(s) and found ${secrets} secret-shaped field(s); expected >= ${MIN_STRUCTS} / ${MIN_SECRET_FIELDS}."
    echo "  The extractor has stopped matching, so a clean result proves nothing." >&2
    echo "  Fix the scan (or move the floor deliberately) — do not ignore it." >&2
    exit 2
  fi

  if [[ -n "${hits}" ]]; then
    fail "a secret-shaped field is not zeroized (Security Rule 7)."
    printf '%s\n' "${hits}" | sed "s|${REPO_ROOT}/||" | sed 's/^/    /' >&2
    echo "  Wrap the field in Zeroizing<…>, or derive ZeroizeOnDrop on the struct." >&2
    echo "  If the value is not secret, say why on the line:  // zeroize-ok: <why>" >&2
    exit 1
  fi

  log "OK: ${secrets} secret-shaped field(s) across ${structs} struct(s), all zeroized."
}

main "$@"
