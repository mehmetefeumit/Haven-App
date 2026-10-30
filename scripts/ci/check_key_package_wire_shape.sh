#!/usr/bin/env bash
# CI guard: every KeyPackage Haven constructs asserts its protocol profile.
#
# ## Why this exists
#
# MDK v0.10.4's `KeyPackage::new` and `KeyPackage::with_source_event_id` stamp
# the package with the LEGACY protocol profile (cgka-traits
# `src/engine.rs:60-95`, `protocol_profile: ProtocolProfile::Legacy`). Every
# create, invite and metadata read on a Current session then refuses it — a
# failure that compiles cleanly and surfaces only at run time, as a circle that
# cannot be founded or a KeyPackage that cannot be read back. Haven publishes
# and consumes only Current packages, so every construction must chain
# `.with_protocol_profile(...)` onto the constructor in the same expression.
#
# ## What it enforces
#
#   K1. In production Rust, every `KeyPackage::new(` and
#       `KeyPackage::with_source_event_id(` expression carries
#       `.with_protocol_profile(` before the expression ends — at a `;`, a `,`
#       or a brace at its own nesting depth, or at the `)` that closes the call
#       it is an argument of. A `.with_protocol_profile(` in a LATER statement
#       does not count: the Legacy package already escaped.
#
#   K1b. No production Rust spells a 30443 capability tag value as a literal
#       (a `"0x"` + four hex digits string). Receivers reject a KeyPackage
#       whose `mls_ciphersuite` / `mls_extensions` / `mls_proposals` /
#       `app_components` tags differ from what its bytes decode to (MDK
#       `marmot-app/src/key_package_records.rs:376-394,836-857`), so the values
#       are read off `key_package_metadata`, never written down.
#   K1c. A production file that builds the `app_components` tag derives it the
#       way MDK's publisher does (`marmot-app/src/lib.rs:6560-6578`): from
#       `key_package_metadata`, restricted to
#       `PRIVATE_USE_APP_COMPONENT_ID_START` and above.
#
#   K2. The kind-30443 event is MDK's own template, not a hand-built tag list:
#       (a) no production `const MLS_EXTENSIONS`, `MLS_PROPOSALS` or
#           `APP_COMPONENTS` (the hard-coded id-lists this replaced);
#       (b) a production file that signs a kind-30443 (`EventBuilder::new(`
#           with `KIND_MARMOT_KEY_PACKAGE` or `30443` in the same expression)
#           fills `NostrKeyPackagePublication` and calls `.to_event_at(` —
#           never `.to_event()`, which stamps the wall clock and loses the
#           slot's monotonic `created_at`;
#       (c) `client_name` is only ever `None`: a client label on a public,
#           identity-signed event names the app to every relay;
#       (d) `NostrKeyPackagePublisher` is not used: Haven signs a package's
#           event once and republishes those exact bytes.
#
# The expression is read across lines (rustfmt splits the chain the moment it
# exceeds the width), bounded at twelve lines.
#
# Production Rust means `haven-core/src` + `haven/rust_builder/src` with
# `#[cfg(test)]` module bodies brace-walked out, whole-line comments dropped and
# `frb_generated` excluded — the view `check_inner_location_kind.sh` and
# `check_privacy_invariants.sh` rule 13 take, so the guards cannot disagree
# about what ships.
#
# Pure-grep gate (no Rust toolchain), belongs in the shared repo-guards job.
#
# Usage:
#   check_key_package_wire_shape.sh            # check the repo
#   check_key_package_wire_shape.sh --self-test
#
# Exit codes:
#   0  the check passes
#   1  a violation (including "no construction found": a renamed type scans
#      nothing, which is a guard failure, not a pass)
#   2  the guard itself is broken or misconfigured

set -Eeuo pipefail
LITERAL_FREE="$(cat "$(dirname "${BASH_SOURCE[0]}")/lib/literal_free.awk")"
readonly LITERAL_FREE

SCRIPT_NAME="check_key_package_wire_shape"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROD_DIRS=("haven-core/src" "haven/rust_builder/src")

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=36

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }

# Production view of one file as `<line-no>:<text>` (lifted from
# check_inner_location_kind.sh on purpose).
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

prod_files() { # prod_files <root>
  local root="$1" d
  local -a dirs=()
  for d in "${PROD_DIRS[@]}"; do [[ -d "${root}/${d}" ]] && dirs+=("${root}/${d}"); done
  (( ${#dirs[@]} > 0 )) || return 0
  find "${dirs[@]}" -name '*.rs' 2>/dev/null | grep -v 'frb_generated' | sort
}

# `<line-no><TAB><ok|bare>` for every KeyPackage construction in a file's
# production view: `ok` when its expression chains `.with_protocol_profile(`.
construction_sites() { # construction_sites <file>
  prod_view "$1" | awk '
    {
      n = index($0, ":")
      NUM[NR] = substr($0, 1, n - 1)
      TXT[NR] = substr($0, n + 1)
    }
    # The expression starting at column p of line i, up to where it ends.
    function expression(i, p,   depth, j, t, k, ch, out) {
      depth = 0; out = ""
      for (j = i; j <= NR && j - i < 12; j++) {
        t = (j == i) ? substr(TXT[j], p) : TXT[j]
        for (k = 1; k <= length(t); k++) {
          ch = substr(t, k, 1)
          if (ch == "(") depth++
          else if (ch == ")") { depth--; if (depth < 0) return out }
          else if (depth == 0 && (ch == ";" || ch == "," || ch == "{" || ch == "}")) return out
          out = out ch
        }
        out = out " "
      }
      return out
    }
    END {
      for (i = 1; i <= NR; i++) {
        rest = TXT[i]; off = 0
        while (match(rest, /KeyPackage::(new|with_source_event_id)\(/)) {
          e = expression(i, off + RSTART)
          printf "%s\t%s\n", NUM[i], (index(e, ".with_protocol_profile(") ? "ok" : "bare")
          off += RSTART + RLENGTH - 1
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
  '
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
  local root="$1" fail=0 f sites=0 line verdict
  local -a files=()
  mapfile -t files < <(prod_files "${root}")
  if (( ${#files[@]} == 0 )); then
    fail_msg "[K1] no production Rust found under $(printf '%s ' "${PROD_DIRS[@]}")— with \
nothing to scan, K1 would pass vacuously."
    return 1
  fi
  for f in "${files[@]}"; do
    while IFS=$'\t' read -r line verdict; do
      [[ -n "${line}" ]] || continue
      sites=$(( sites + 1 ))
      if [[ "${verdict}" != ok ]]; then
        fail_msg "[K1] ${f#"${root}/"}:${line} constructs a KeyPackage without \
\`.with_protocol_profile(...)\` in the same expression. MDK v0.10.4 defaults it to the Legacy \
profile, which every Current create, invite and metadata read refuses."
        fail=1
      fi
    done < <(construction_sites "${f}")
  done
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      fail_msg "[K1b] ${f#"${root}/"}:${line%%:*} spells a capability tag value as a literal. \
Read it off \`key_package_metadata\`: a tag that differs from the decoded package is rejected."
      fail=1
    done < <(prod_view "${f}" | grep -E '"0x[0-9a-fA-F]{4}"' || true)
    local view
    view="$(prod_view "${f}")"
    if grep -q '"app_components"' <<<"${view}"; then
      if ! grep -q 'key_package_metadata' <<<"${view}" \
        || ! grep -q 'PRIVATE_USE_APP_COMPONENT_ID_START' <<<"${view}"; then
        fail_msg "[K1c] ${f#"${root}/"} builds the app_components tag without deriving it from \
\`key_package_metadata\` filtered at \`PRIVATE_USE_APP_COMPONENT_ID_START\`."
        fail=1
      fi
    fi
  done
  local signs_30443=0 view
  for f in "${files[@]}"; do
    view="$(prod_view "${f}")"
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      fail_msg "[K2a] ${f#"${root}/"}:${line%%:*} declares a hard-coded 30443 id-list. The \
lists are read off \`key_package_metadata\` into MDK's \`NostrKeyPackagePublication\`."
      fail=1
    done < <(grep -E 'const[[:space:]]+(MLS_EXTENSIONS|MLS_PROPOSALS|APP_COMPONENTS)[[:space:]]*:' <<<"${view}" || true)
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      fail_msg "[K2c] ${f#"${root}/"}:${line%%:*} sets a 30443 \`client_name\`. A client label on \
a public, identity-signed event names the app to every relay."
      fail=1
    done < <(grep -E 'client_name[[:space:]]*:' <<<"${view}" | grep -vE 'client_name[[:space:]]*:[[:space:]]*None[[:space:]]*,' || true)
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      fail_msg "[K2d] ${f#"${root}/"}:${line%%:*} uses \`NostrKeyPackagePublisher\`. Haven signs a \
package's 30443 once and republishes those exact bytes."
      fail=1
    done < <(grep -E 'NostrKeyPackagePublisher' <<<"${view}" || true)
    if signs_key_package_event <<<"${view}"; then
      signs_30443=$(( signs_30443 + 1 ))
      if ! grep -q 'NostrKeyPackagePublication' <<<"${view}" \
        || ! grep -q '\.to_event_at(' <<<"${view}" \
        || grep -q '\.to_event()' <<<"${view}"; then
        fail_msg "[K2b] ${f#"${root}/"} signs a kind-30443 without MDK's template \
(\`NostrKeyPackagePublication\` + \`.to_event_at(\`, never \`.to_event()\`)."
        fail=1
      fi
    fi
  done
  if (( signs_30443 == 0 )); then
    fail_msg "[K2b] no production file signs a kind-30443. Haven publishes its KeyPackage \
through one; a guard that finds none is scanning a renamed builder, not a clean tree."
    return 1
  fi
  if (( sites == 0 )); then
    fail_msg "[K1] no \`KeyPackage::new(\` or \`KeyPackage::with_source_event_id(\` found in \
production Rust. Haven builds its KeyPackages through these; a guard that finds none is \
scanning a renamed API, not a clean tree."
    return 1
  fi
  (( fail == 0 )) || return 1
  log "OK: all ${sites} KeyPackage construction(s) in production Rust assert their protocol profile, no capability tag value is written as a literal, and the kind-30443 is MDK's template."
}

# Whether a production view (stdin) signs a kind-30443: an `EventBuilder::new(`
# whose first argument, read across at most three lines, names the kind.
signs_key_package_event() {
  awk '
    { n = index($0, ":"); TXT[NR] = substr($0, n + 1) }
    END {
      for (i = 1; i <= NR; i++) {
        if (index(TXT[i], "EventBuilder::new(") == 0) continue
        e = substr(TXT[i], index(TXT[i], "EventBuilder::new("))
        for (j = i + 1; j <= NR && j <= i + 2; j++) e = e " " TXT[j]
        cut = index(e, ",")
        if (cut > 0) e = substr(e, 1, cut)
        if (e ~ /KIND_MARMOT_KEY_PACKAGE|30443/) { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # The 30443 signing site every tree carries, so that a K1 fixture is judged
  # on K1 alone. `_case_k2` replaces it.
  local template='fn sign(p: NostrKeyPackagePublication, keys: &Keys) -> Event {
    let t = p.to_event_at(1).unwrap();
    EventBuilder::new(Kind::Custom(KIND_MARMOT_KEY_PACKAGE), t.content).sign_with_keys(keys).unwrap()
}'
  # _case <label> <want-rc> <rust source for haven-core/src/probe.rs> [signer source]
  _case() {
    local label="$1" want="$2" body="$3" signer="${4-${template}}" t got=0
    checked=$(( checked + 1 ))
    t="${tmp}/case${checked}"
    mkdir -p "${t}/haven-core/src"
    [[ -z "${body}" ]] || printf '%s\n' "${body}" >"${t}/haven-core/src/probe.rs"
    [[ -z "${body}" || -z "${signer}" ]] || printf '%s\n' "${signer}" >"${t}/haven-core/src/signer.rs"
    ( run_checks "${t}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  echo "${SCRIPT_NAME}.sh --self-test"
  _case "a one-line construction with its profile passes" 0 \
'fn a(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current) }'
  _case "a rustfmt-split chain with its profile passes" 0 \
'fn a(b: Vec<u8>, s: EventId) -> Result<KeyPackage> {
    Ok(KeyPackage::with_source_event_id(b, s)
        .with_protocol_profile(ProtocolProfile::Current))
}'
  _case "a path-qualified construction in a struct field passes" 0 \
'fn a(b: Vec<u8>) -> P { P {
    key_package: types::KeyPackage::new(b)
        .with_protocol_profile(types::ProtocolProfile::Current),
    d: 1,
} }'
  _case "a one-line construction without a profile FAILS" 1 \
'fn a(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b) }'
  _case "a split construction whose arguments span lines and carry no profile FAILS" 1 \
'fn a(b: Vec<u8>, s: EventId) -> KeyPackage {
    let k = KeyPackage::with_source_event_id(
        b,
        s,
    );
    k
}'
  _case "a profile set in a LATER statement FAILS" 1 \
'fn a(b: Vec<u8>) -> KeyPackage {
    let k = KeyPackage::new(b);
    k.with_protocol_profile(ProtocolProfile::Current)
}'
  _case "a bare construction as a call argument FAILS, a profiled sibling notwithstanding" 1 \
'fn a(b: Vec<u8>) { f(&KeyPackage::new(b.clone()), KeyPackage::new(b).with_protocol_profile(P::Current)); }'
  _case "a bare construction inside #[cfg(test)] is not production" 0 \
'fn a(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current) }
#[cfg(test)]
mod tests {
    fn decoy(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b) }
}'
  _case "a capability tag value written as a literal FAILS (K1b)" 1 \
'const APP: [&str; 1] = ["0x8001"];
fn a(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current) }'
  _case "an app_components tag derived from the metadata passes (K1c)" 0 \
'fn a(b: Vec<u8>) -> Vec<u16> {
    let m = key_package_metadata(&KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current));
    let n = "app_components";
    m.app_components.into_iter().filter(|id| *id >= PRIVATE_USE_APP_COMPONENT_ID_START).collect()
}'
  _case "an app_components tag not derived from the metadata FAILS (K1c)" 1 \
'fn a(b: Vec<u8>) -> &str {
    let k = KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current);
    "app_components"
}'
  _case "a literal inside #[cfg(test)] is not production (K1b)" 0 \
'fn a(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current) }
#[cfg(test)]
mod tests {
    fn pin() -> &str { "0x8009" }
}'
  _case "a brace inside a test module's string hides no later production code" 1 \
'fn a(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current) }
#[cfg(test)]
mod tests {
    fn opener() -> &str { "{" }
}
fn late(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b) }'
  _case "a tree with no construction at all FAILS" 1 \
'fn a() -> u8 { 1 }'
  _case "a tree with no production Rust FAILS" 1 ''

  local ok='fn a(b: Vec<u8>) -> KeyPackage { KeyPackage::new(b).with_protocol_profile(ProtocolProfile::Current) }'
  _case "a hard-coded id-list constant FAILS (K2a)" 1 \
"${ok}
const MLS_PROPOSALS: [u16; 2] = [8, 10];"
  _case "a 30443 signed without the template FAILS (K2b)" 1 "${ok}" \
'fn sign(c: String, keys: &Keys) -> Event {
    EventBuilder::new(Kind::Custom(KIND_MARMOT_KEY_PACKAGE), c).sign_with_keys(keys).unwrap()
}'
  _case "a 30443 whose kind is on the next line is still a signing site (K2b)" 1 "${ok}" \
'fn sign(c: String, keys: &Keys) -> Event {
    EventBuilder::new(
        Kind::Custom(30443),
        c,
    )
    .sign_with_keys(keys)
    .unwrap()
}'
  _case "the wall-clock template call FAILS (K2b)" 1 "${ok}" \
'fn sign(p: NostrKeyPackagePublication, keys: &Keys) -> Event {
    let t = p.to_event_at(1).unwrap(); let u = p.to_event().unwrap();
    EventBuilder::new(Kind::Custom(KIND_MARMOT_KEY_PACKAGE), t.content).sign_with_keys(keys).unwrap()
}'
  _case "a tree that signs no 30443 at all FAILS (K2b)" 1 "${ok}" ''
  _case "a client label FAILS (K2c)" 1 \
"${ok}
fn p() -> NostrKeyPackagePublication { NostrKeyPackagePublication { client_name: Some(\"haven\".into()), ..d() } }"
  _case "MDK's re-signing publisher FAILS (K2d)" 1 \
"${ok}
fn p(c: Arc<dyn NostrRelayClient>) -> NostrKeyPackagePublisher { NostrKeyPackagePublisher::new(c) }"

  # literal_free, which every brace-walking guard counts on: each source line
  # (odd lines below) and exactly what is left of it to count (even lines),
  # trailing blanks aside.
  local src want got
  while IFS= read -r src && IFS= read -r want; do
    checked=$(( checked + 1 ))
    got="$(printf '%s\n' "${src}" | awk "${LITERAL_FREE}"'{ print literal_free($0) }' | sed 's/[[:space:]]*$//')"
    if [[ "${got}" == "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m literal_free: %s\n' "${src}"
    else
      printf '  \033[1;31mFAIL\033[0m literal_free: %s (want [%s], got [%s])\n' "${src}" "${want}" "${got}" >&2
      fails=1
    fi
  done <<'LITERALS'
let s = "a { \" }"; x {
let s = ; x {
let s = r#"say "}" here"#; x {
let s = ; x {
'{' => d += 1,
 => d += 1,
let q = ['\'', '\\', '\u{7d}', '}'];
let q = [, , , ];
let b = [b'\'', b'{'];
let b = [b, b];
fn f<'a>(x: &'a str) -> &'a str {
fn f<'a>(x: &'a str) -> &'a str {
  f('${a ? ', b' : ''}');
  f('${a ? ', b' : ''}');
  f('${e?.m ?? 'IO error'}');
  f('${e?.m ?? 'IO error'}');
    work { commits: \"0\" }"
    work { commits: 0 }"
let u = "wss:
let u = "wss:
for n in ["wss://", "npub"] {
for n in [, ] {
x { // a } in prose
x {
let s = br#"a "}" b"#; x {
let s = b; x {
let s = br"\"; x {
let s = b; x {
LITERALS

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
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
