#!/usr/bin/env bash
# CI guard: the Bluetooth mesh's radio reaches Rust through a fixed list of JNI
# exports that decide nothing, and the bridge crate writes `unsafe` in two
# files (docs/BLUETOOTH_MESH_M3_DESIGN.md §A.6, F-8, F-14).
#
# Android's radio service drives the mesh engine through
# `haven/rust_builder/src/mesh_jni.rs`: one `extern "system"` function for each
# native method of the Kotlin class `com.oblivioustech.haven.mesh.MeshNative`.
# Four things about that file are textual facts a review of a later change can
# miss, and none of them is a compile error when it breaks:
#
#   * A PANIC THAT LEAVES AN EXPORT ENDS THE PROCESS. An unwind out of an
#     `extern` function aborts, and the process is also the one that publishes
#     to relays. So every export makes its one `radio_*` call inside
#     `radio_guarded` (`catch_unwind`), and nothing else in the file calls an
#     entry.
#
#   * A JNI NAME OR TYPE THAT DOES NOT MATCH IS A RUN-TIME ERROR. Kotlin finds
#     a native method by its symbol when it is first called. The exports are
#     therefore pinned — name, JNI descriptor, Rust types — in
#     `haven/rust_builder/fixtures/mesh_radio_exports.txt`, and the shim is
#     held to that list here, both ways.
#
#   * THE SHIM CALLS NOTHING OF JAVA'S. It copies arrays in and one array out
#     and clears an exception; it keeps no `JavaVM`, no reference and no state,
#     so nothing of the engine can reach Kotlin except as an export's answer.
#
#   * `unsafe` IS CONFINED. The crate denies `unsafe_code` and allows it on
#     two modules: the generated bridge, and the shim, where the lint fires on
#     `#[no_mangle]`. An allowance moved to the crate, or to `api.rs`, would
#     compile.
#
# Pure-grep gate over comment-stripped Rust. Checks:
#   1. Under haven/rust_builder/src the keyword `unsafe`, the attribute
#      `no_mangle` and an ABI string (`extern "…"`) appear only in
#      `frb_generated.rs` and `mesh_jni.rs`.
#   2. `lib.rs` carries `#![deny(unsafe_code)]`, and `unsafe_code` is named
#      three times in the crate's hand-written source: that line, and one
#      `#[allow(unsafe_code)]` directly above each of `mod frb_generated;` and
#      `mod mesh_jni;`.
#   3. In `mesh_jni.rs`: every `#[no_mangle]` stands directly above a
#      `pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_…`
#      and every ABI string is on such a line; the file has no `unsafe`; each
#      export names `radio_guarded(` once, no `radio_*` before it and exactly
#      one after it, and under the guard stands that entry alone — by name, or
#      as a closure that is its call, with no call among its arguments; and
#      outside the exports and the one `use crate::api::{…}` nothing names a
#      `radio_*`.
#   4. The exports — name, Rust parameter types after the environment and the
#      receiver, Rust return type, and the JNI descriptor those types make —
#      are the lines of the fixture, in order, and no others.
#   5. The shim's JNI surface: a `JNIEnv` is bound only as `env` / `_env`, the
#      only calls on it are ENV_MAY_CALL, and the file names no `JavaVM`,
#      `GlobalRef`, `WeakRef`, `JNI_OnLoad`, `static` or `thread_local`.
#
# What this scan covers, and no more. It reads names. It cannot see `unsafe`
# a macro writes (the compiler's deny does), a `JNIEnv` passed on under a type
# alias, or what an entry does once called. That an export passes its
# arguments on unchanged is read in the shim; its conversions, the guard and
# what a panic leaves are held by tests in `haven/rust_builder/src`
# (`mesh_jni::tests`, `a_call_that_panics_under_the_guard_…`,
# `every_export_is_one_guarded_call`, `the_radio_entries_take_no_session`).
#
# Not here yet, each with the change that makes it checkable:
#   * The Kotlin half of check 4 — the `external fun`s of `MeshNative.kt`
#     against the same fixture — lands with that file. No Kotlin of the mesh
#     exists, and a check with nothing to read would report a parity it has
#     not seen.
#   * That the built library exports the symbols (`nm -D`) belongs to
#     `build-check.yml`, with the first unit that builds the radio for Android.
#
# Usage:
#   bash scripts/ci/check_mesh_radio.sh
#   bash scripts/ci/check_mesh_radio.sh --self-test
#
# Exit codes:
#   0  all checks pass (or the self-test passed)
#   1  a check failed (or the self-test failed)
#   2  an expected file is missing, or the shim or the fixture lists no export
#      — the scan would be reading nothing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly SRC='haven/rust_builder/src'
readonly LIB="${SRC}/lib.rs"
readonly SHIM="${SRC}/mesh_jni.rs"
readonly GENERATED="${SRC}/frb_generated.rs"
readonly EXPORTS='haven/rust_builder/fixtures/mesh_radio_exports.txt'
readonly HEADER='pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_'
# Every call the shim may make on a `JNIEnv`: two array reads with the length
# they are bounded by, one array made for the answer, and the clearing of an
# exception a failed call left.
readonly -a ENV_MAY_CALL=(
  get_array_length get_long_array_region convert_byte_array byte_array_from_slice exception_clear
)

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=44

readonly UNSAFE='(^|[^A-Za-z0-9_])unsafe([^A-Za-z0-9_]|$)'
readonly ABI='extern[[:space:]]*"'

FAILED=0

log() {
  printf '\033[1;34m[check_mesh_radio]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_mesh_radio] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

# Comment-stripped view of a Rust file, line numbering preserved. `//` starts a
# comment unless a `:` precedes it, or a `"wss://relay"` literal would truncate
# its own line.
code_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else {
          two = substr(line, i, 2)
          prev = (i > 1) ? substr(line, i - 1, 1) : ""
          if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//" && prev != ":") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

# A view on stdin with every string literal that opens and closes on one line
# emptied: the word `unsafe` in a string is not the keyword.
no_strings() {
  sed -E 's/"(\\.|[^"\\])*"/""/g'
}

# "<first> <last>" for each export in a view on stdin: from its declaration to
# the brace that closes it.
export_lines() {
  awk -v header="${HEADER}" '
    index($0, header) == 1 && !inside { inside = 1; first = NR; depth = 0; opened = 0 }
    inside {
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        if (chars[i] == "{") { depth++; opened = 1 }
        else if (chars[i] == "}") { depth-- }
      }
      if (opened && depth == 0) { inside = 0; print first, NR }
    }'
}

# The fixture's line for each export in a view on stdin, or `? <name>` for a
# signature that is not an export's.
export_rows() {
  awk -v header="${HEADER}" '
    function letter(type) {
      if (type == "jlong") return "J"
      if (type == "jint") return "I"
      if (type == "jboolean") return "Z"
      if (type == "JByteArray" || type == "jbyteArray") return "[B"
      if (type == "JLongArray") return "[J"
      return ""
    }
    index($0, header) == 1 { sig = ""; insig = 1 }
    insig {
      sig = sig $0
      if ($0 !~ /\{[[:space:]]*$/) next
      insig = 0
      gsub(/[[:space:]]/, "", sig)
      head = header; gsub(/[[:space:]]/, "", head)
      sig = substr(sig, length(head) + 1)
      name = substr(sig, 1, index(sig, "(") - 1)
      params = substr(sig, index(sig, "(") + 1)
      answer = substr(params, index(params, ")") + 1)
      params = substr(params, 1, index(params, ")") - 1)
      sub(/\{$/, "", answer)
      ok = (answer == "" || answer ~ /^->/)
      sub(/^->/, "", answer)
      count = split(params, each, ",")
      types = ""; taken = ""; seen = 0
      for (i = 1; i <= count; i++) {
        if (each[i] == "") continue
        type = each[i]; sub(/^[^:]*:/, "", type)
        seen++
        if (seen == 1) { if (type != "JNIEnv") ok = 0; continue }
        if (seen == 2) { if (type != "JObject") ok = 0; continue }
        if (letter(type) == "" || type == "jbyteArray") ok = 0
        types = types (types == "" ? "" : ",") type
        taken = taken letter(type)
      }
      if (seen < 2) ok = 0
      if (answer != "" && (letter(answer) == "" || answer == "JByteArray" || answer == "JLongArray")) ok = 0
      if (!ok) { print "? " name; next }
      print name, "(" taken ")" (answer == "" ? "V" : letter(answer)), (types == "" ? "-" : types), (answer == "" ? "-" : answer)
    }'
}

run_check() {
  local file rel view hits shim lines first last body name guards before after entries rows pinned names called alone

  [[ -d "${REPO_ROOT}/${SRC}" ]] || { echo "ERROR: ${REPO_ROOT}/${SRC} not found" >&2; exit 2; }
  for file in "${LIB}" "${SHIM}" "${GENERATED}" "${EXPORTS}"; do
    [[ -f "${REPO_ROOT}/${file}" ]] || { echo "ERROR: ${REPO_ROOT}/${file} not found" >&2; exit 2; }
  done
  # The shim as it ships: its own tests, which call no export, are not read.
  shim="$(code_view "${REPO_ROOT}/${SHIM}" | awk '$0 == "#[cfg(test)]" { exit } { print }')"
  lines="$(export_lines <<<"${shim}")"
  pinned="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/${EXPORTS}" || true)"
  if [[ -z "${lines}" || -z "${pinned}" ]]; then
    echo "ERROR: ${SHIM} declares no '${HEADER}…', or ${EXPORTS} lists none — the checks would be reading nothing. If the shim moved, move this guard with it." >&2
    exit 2
  fi

  log "Checking that unsafe is written in two files, and that the radio's JNI exports are the pinned ones, each one guarded call ..."

  # Check 1: where `unsafe`, `no_mangle` and an ABI string are written.
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    case "${rel}" in "${GENERATED}" | "${SHIM}") continue ;; esac
    view="$(code_view "${file}")"
    hits="$({
      grep -nE "no_mangle|${ABI}" <<<"${view}" || true
      no_strings <<<"${view}" | grep -nE "${UNSAFE}" || true
    } | cut -d: -f1 | LC_ALL=C sort -un | tr '\n' ' ')"
    if [[ -n "${hits}" ]]; then
      fail "${rel} writes unsafe, no_mangle or an ABI string (line(s) ${hits}). In the bridge crate only ${GENERATED} and ${SHIM} may: every other file is safe Rust the compiler checks whole, and a symbol exported from anywhere else is one no guard has read."
    fi
  done < <(find "${REPO_ROOT}/${SRC}" -type f -name '*.rs' | LC_ALL=C sort)

  # Check 2: the lint that makes check 1 the compiler's too.
  view="$(code_view "${REPO_ROOT}/${LIB}" | sed -E 's/[[:space:]]+$//; /^$/d')"
  if [[ "$(grep -cxF '#![deny(unsafe_code)]' <<<"${view}" || true)" != 1 ]]; then
    fail "${LIB} does not carry #![deny(unsafe_code)] exactly once. Without it nothing but check 1's reading of names keeps unsafe out of api.rs."
  fi
  hits="$(grep -A1 -xF '#[allow(unsafe_code)]' <<<"${view}" | grep -vxF -e '#[allow(unsafe_code)]' -e '--' | LC_ALL=C sort | tr '\n' ' ' || true)"
  if [[ "${hits}" != 'mod frb_generated; mod mesh_jni; ' || "$(grep -c 'unsafe_code' <<<"${view}" || true)" != 3 ]]; then
    fail "${LIB} names unsafe_code otherwise than as the crate's deny and one #[allow(unsafe_code)] directly above each of 'mod frb_generated;' and 'mod mesh_jni;' (found above: ${hits:-nothing}). An allowance on the crate or on another module lets unsafe into code no guard reads."
  fi
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    case "${rel}" in "${GENERATED}" | "${LIB}") continue ;; esac
    hits="$(code_view "${file}" | grep -n 'unsafe_code' | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names the unsafe_code lint (line(s) ${hits}). Its level is set in ${LIB} alone: an allow inside a file undoes the crate's deny for that file."
    fi
  done < <(find "${REPO_ROOT}/${SRC}" -type f -name '*.rs' | LC_ALL=C sort)

  # Check 3: every export is one guarded call.
  hits="$(awk -v header="${HEADER}" '
    index($0, header) == 1 && prev == "#[no_mangle]" { pairs++ }
    { prev = $0 }
    END { print pairs + 0 }' <<<"${shim}")"
  if [[ "$(grep -c 'no_mangle' <<<"${shim}" || true)" != "${hits}" \
    || "$(grep -cE "${ABI}" <<<"${shim}" || true)" != "${hits}" \
    || "$(wc -l <<<"${lines}" | tr -d ' ')" != "${hits}" ]]; then
    fail "${SHIM} exports something that is not '#[no_mangle]' directly above '${HEADER}…'. Every symbol the shim exports is a native method of MeshNative, declared one way, so that this guard reads every one."
  fi
  if no_strings <<<"${shim}" | grep -qE "${UNSAFE}"; then
    fail "${SHIM} writes unsafe. The lint is allowed on it for #[no_mangle] alone: jni's wrappers need no unsafe block, and a raw JNI call is one the wrappers' checks do not cover."
  fi
  local outside="${shim}"
  while read -r first last; do
    body="$(sed -n "${first},${last}p" <<<"${shim}")"
    name="${body#"${HEADER}"}"
    name="${name%%(*}"
    guards="$(grep -o 'radio_guarded(' <<<"${body}" | wc -l | tr -d ' ' || true)"
    before="${body%%radio_guarded(*}"
    after="${body#*radio_guarded(}"
    entries="$(grep -oE 'radio_[A-Za-z0-9_]+' <<<"${after}" | tr '\n' ' ' || true)"
    called="$(wc -w <<<"${entries}" | tr -d ' ')"
    # Under the guard: the answer with no engine, then the entry — itself, or a
    # closure that is its call on values converted before the guard.
    alone="$(tr -d '[:space:]{}' <<<"${after}" | grep -cE '^[^,]*,(\|\|)?radio_[A-Za-z0-9_]+(\([^()]*\))?\)' || true)"
    if [[ "${guards}" != 1 || "${before}" == *radio_* || "${called}" != 1 || "${alone}" != 1 ]]; then
      fail "the export ${name} is not one guarded call and nothing else: it names radio_guarded( ${guards} time(s) and, under it, ${entries:-no radio entry}. An entry called outside the guard takes the process — the relay path's too — with it when it panics; anything else under the guard is a decision made in the shim."
    fi
    outside="$(awk -v first="${first}" -v last="${last}" 'NR < first || NR > last { print; next } { print "" }' <<<"${outside}")"
  done <<<"${lines}"
  hits="$(awk '
    index($0, "use crate::api::{") == 1 { inuse = 1 }
    !inuse && /radio_/ { printf "%d ", NR }
    inuse && /};/ { inuse = 0 }' <<<"${outside}")"
  if [[ -n "${hits}" ]]; then
    fail "${SHIM} names a radio entry outside an export and its one 'use crate::api::{…}' (line(s) ${hits}). Only an export calls an entry, and only under the guard."
  fi

  # Check 4: the exports are the pinned ones.
  rows="$(export_rows <<<"${shim}")"
  if [[ "${rows}" != "${pinned}" ]]; then
    names="$(diff <(printf '%s\n' "${pinned}") <(printf '%s\n' "${rows}") | grep -E '^[<>]' | tr '\n' ';' || true)"
    fail "the exports of ${SHIM} are not the lines of ${EXPORTS} ('<' pinned, '>' exported, '?' a signature that is no export's: ${names}). Kotlin finds a native method by name and passes what its own declaration says; a name or a type that differs is found when the method is first called. Change the fixture, the shim and MeshNative.kt together."
  fi

  # Check 5: what the shim does with a JNIEnv.
  hits="$(grep -oE '[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*&?(mut[[:space:]]+)?JNIEnv' <<<"${shim}" | sed -E 's/[[:space:]]*:.*//' | grep -vxE '_?env' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${SHIM} binds a JNIEnv as '${hits% }'. It is bound as env or _env, so that every call made on one is read here."
  fi
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    local ok=0 may
    for may in "${ENV_MAY_CALL[@]}"; do
      [[ "${name}" == "${may}" ]] && ok=1
    done
    if (( ok == 0 )); then
      fail "${SHIM} calls ${name} on a JNIEnv. The shim reads two arrays, makes one and clears an exception (${ENV_MAY_CALL[*]}): it calls no method of Java's, makes no reference and reaches no JavaVM, so the engine reaches Kotlin only as an export's answer."
    fi
  done < <(tr -d '[:space:]' <<<"${shim}" | grep -oE '(^|[^A-Za-z0-9_])env\.[A-Za-z0-9_]+\(' | sed -E 's/.*env\.//; s/\($//' | LC_ALL=C sort -u || true)
  hits="$(grep -nE '(^|[^A-Za-z0-9_])(JavaVM|GlobalRef|WeakRef|JNI_OnLoad|static|thread_local)([^A-Za-z0-9_]|$)' <<<"${shim}" | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${SHIM} names a JavaVM, a reference that outlives a call, or state of its own (line(s) ${hits}). Every call is made by a Java thread and returns: the shim keeps nothing between two."
  fi

  if (( FAILED )); then
    exit 1
  fi
  log "OK: unsafe is written in the generated bridge and the shim alone, under the crate's deny; the $(wc -l <<<"${lines}" | tr -d ' ') exports are the pinned ones, each one guarded call of a radio entry, and the shim calls nothing of Java's."
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is a whole tree run through the real entry point, and
# must fail with the message of the check it breaks.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _tree() { # <tree>
    local t="$1"
    mkdir -p "${t}/${SRC}" "${t}/haven/rust_builder/fixtures"
    cat >"${t}/${LIB}" <<'RS'
//! Bridge.

// Allow unsafe in generated FFI code; never #![allow(unsafe_code)] here.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
#![deny(unsafe_code)]

pub mod api;

// The lint fires on `#[no_mangle]`.
#[cfg(any(target_os = "android", test))]
#[allow(unsafe_code)]
mod mesh_jni;

#[cfg(debug_assertions)]
mod test_keyring;

#[allow(unsafe_code)]
mod frb_generated;
pub use frb_generated::*;
RS
    cat >"${t}/${SRC}/api.rs" <<'RS'
// Never unsafe here, no #[no_mangle] and no extern "C": see lib.rs.
pub(crate) fn radio_left_ms() -> u64 {
    0
}
pub(crate) fn radio_receive(link: u64, frame: &[u8]) {}
pub(crate) fn radio_poll(ready: &[u64]) -> Option<Vec<u8>> {
    None
}
pub(crate) fn radio_guarded<T>(none: T, call: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
    std::panic::catch_unwind(call).unwrap_or(none)
}
fn qualifier(word: &str) -> bool {
    matches!(word, "pub" | "unsafe") || word == "wss://relay.example unsafe"
}
fn header(name: &str) -> String {
    format!("pub extern \"system\" fn Java_{name}(")
}
RS
    cat >"${t}/${GENERATED}" <<'RS'
#[no_mangle]
pub extern "C" fn frbgen_free(ptr: *mut u8) {
    unsafe { drop(Box::from_raw(ptr)) }
}
RS
    printf 'pub fn install() {}\n' >"${t}/${SRC}/test_keyring.rs"
    cat >"${t}/${SHIM}" <<'RS'
//! No unsafe block, no static, no JavaVM: env.new_global_ref( is never called.
use jni::objects::{JByteArray, JLongArray, JObject};
use jni::sys::{jbyteArray, jlong};
use jni::JNIEnv;

use crate::api::{
    radio_guarded, radio_left_ms, radio_poll, radio_receive,
};

fn millis_out(ms: u64) -> jlong {
    jlong::try_from(ms).unwrap_or(jlong::MAX)
}

fn settled<T>(env: &JNIEnv, answer: jni::errors::Result<T>) -> Option<T> {
    if answer.is_err() {
        let _ = env.exception_clear();
    }
    answer.ok()
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    millis_out(radio_guarded(0, radio_left_ms))
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_receive(
    env: JNIEnv,
    _this: JObject,
    link: jlong,
    frame: JByteArray,
) {
    let read = env
        .get_array_length(&frame)
        .and_then(|_| env.convert_byte_array(&frame));
    let Some(frame) = settled(&env, read) else {
        return;
    };
    let link = link.cast_unsigned();
    radio_guarded((), || radio_receive(link, &frame));
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_poll(env: JNIEnv, _this: JObject, ready: JLongArray) -> jbyteArray {
    let mut links = [0; 1];
    if settled(&env, env.get_long_array_region(&ready, 0, &mut links)).is_none() {
        return std::ptr::null_mut();
    }
    let links = links.map(jlong::cast_unsigned);
    let output = radio_guarded(None, || radio_poll(&links));
    output
        .and_then(|output| settled(&env, env.byte_array_from_slice(&output)))
        .map_or(std::ptr::null_mut(), JByteArray::into_raw)
}

#[cfg(test)]
mod tests {
    static CALLS: u8 = 0;
    fn reads() { let _ = super::radio_left_ms(); }
}
RS
    cat >"${t}/${EXPORTS}" <<'TXT'
# <name> <JNI descriptor> <Rust parameter types> <Rust return type>

leftMs ()J - jlong
receive (J[B)V jlong,JByteArray -
poll ([J)[B JLongArray jbyteArray
TXT
  }
  _case() { # <label> <want-rc> <want-msg-substring> <tree>
    local label="$1" want="$2" msg="$3" got=0 out
    checked=$(( checked + 1 ))
    out="$(REPO_ROOT_OVERRIDE="$4" bash "${BASH_SOURCE[0]}" 2>&1)" || got=$?
    if [[ "${got}" -ne "${want}" ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n%s\n' "${label}" "${want}" "${got}" "${out}" >&2
      fails=1
    elif [[ -n "${msg}" && "${out}" != *"${msg}"* ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (rc=%d, but no message matched %q)\n%s\n' "${label}" "${got}" "${msg}" "${out}" >&2
      fails=1
    else
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    fi
  }
  # Replaces the one line of <file> that contains <text> by <replacement>, in
  # which awk reads `\n` as a line break.
  _line() { # <file> <text> <replacement>
    awk -v text="$2" -v with="$3" 'index($0, text) { print with; next } { print }' "$1" >"$1.new"
    mv "$1.new" "$1"
  }

  echo "check_mesh_radio.sh --self-test"
  local t="${tmp}/ok"; _tree "${t}"
  _case "the tree shape passes: three exports, comments and strings that only mention unsafe, a static in the shim's tests" 0 '' "${t}"

  # Check 1: where unsafe, no_mangle and an ABI string are written.
  t="${tmp}/unsafe-block"; _tree "${t}"
  printf 'fn read(ptr: *const u8) -> u8 { unsafe { *ptr } }\n' >>"${t}/${SRC}/api.rs"
  _case "an unsafe block in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/unsafe-fn"; _tree "${t}"
  printf 'pub unsafe fn install() {}\n' >"${t}/${SRC}/test_keyring.rs"
  _case "an unsafe fn in the test keyring fails" 1 "${SRC}/test_keyring.rs writes unsafe" "${t}"

  t="${tmp}/unsafe-impl"; _tree "${t}"
  printf 'struct Raw(*mut u8);\nunsafe impl Send for Raw {}\n' >"${t}/${SRC}/raw.rs"
  _case "an unsafe impl in a new file fails" 1 "${SRC}/raw.rs writes unsafe" "${t}"

  t="${tmp}/no-mangle"; _tree "${t}"
  printf '#[no_mangle]\npub fn haven_probe() {}\n' >>"${t}/${SRC}/api.rs"
  _case "a no_mangle in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/unsafe-attribute"; _tree "${t}"
  printf '#[unsafe(no_mangle)]\npub fn haven_probe() {}\n' >"${t}/${SRC}/probe.rs"
  _case "the 2024 spelling of no_mangle in a new file fails" 1 "${SRC}/probe.rs writes unsafe" "${t}"

  t="${tmp}/extern-fn"; _tree "${t}"
  printf 'pub extern "C" fn haven_probe() {}\n' >>"${t}/${SRC}/api.rs"
  _case "an extern fn in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/extern-block"; _tree "${t}"
  printf 'extern "C" {\n    fn getpid() -> i32;\n}\n' >"${t}/${SRC}/sys.rs"
  _case "an extern block in a new file fails" 1 "${SRC}/sys.rs writes unsafe" "${t}"

  # Check 2: the lint.
  t="${tmp}/no-deny"; _tree "${t}"
  sed -i '/^#!\[deny(unsafe_code)\]$/d' "${t}/${LIB}"
  _case "the crate's deny removed fails" 1 'does not carry #![deny(unsafe_code)]' "${t}"

  t="${tmp}/warn"; _tree "${t}"
  sed -i 's/^#!\[deny(unsafe_code)\]$/#![warn(unsafe_code)]/' "${t}/${LIB}"
  _case "the crate's deny lowered to a warning fails" 1 'does not carry #![deny(unsafe_code)]' "${t}"

  t="${tmp}/crate-allow"; _tree "${t}"
  sed -i 's/^#!\[deny(unsafe_code)\]$/#![deny(unsafe_code)]\n#![allow(unsafe_code)]/' "${t}/${LIB}"
  _case "the allowance widened to the crate fails" 1 'names unsafe_code otherwise' "${t}"

  t="${tmp}/api-allow"; _tree "${t}"
  sed -i 's/^pub mod api;$/#[allow(unsafe_code)]\npub mod api;/' "${t}/${LIB}"
  _case "an allowance on a third module fails" 1 'names unsafe_code otherwise' "${t}"

  t="${tmp}/moved-allow"; _tree "${t}"
  sed -i 's/^mod test_keyring;$/mod test_keyring;\nmod mesh_jni;/; 0,/^mod mesh_jni;$/{/^mod mesh_jni;$/d}' "${t}/${LIB}"
  _case "the shim's allowance left on the module declared after it fails" 1 'names unsafe_code otherwise' "${t}"

  t="${tmp}/inner-allow"; _tree "${t}"
  sed -i '1s/^/#![allow(unsafe_code)]\n/' "${t}/${SRC}/api.rs"
  _case "an inner allowance in api.rs fails" 1 "${SRC}/api.rs names the unsafe_code lint" "${t}"

  t="${tmp}/item-allow"; _tree "${t}"
  printf '#[allow(unsafe_code)]\nfn raw() {}\n' >>"${t}/${SRC}/test_keyring.rs"
  _case "an allowance on one item of the test keyring fails" 1 "${SRC}/test_keyring.rs names the unsafe_code lint" "${t}"

  # Check 3: every export is one guarded call.
  t="${tmp}/bare"; _tree "${t}"
  _line "${t}/${SHIM}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_left_ms())'
  _case "an export that calls its entry bare fails" 1 'the export leftMs is not one guarded call' "${t}"

  t="${tmp}/before-guard"; _tree "${t}"
  _line "${t}/${SHIM}" 'radio_guarded((), || radio_receive(' '    let _ = radio_left_ms();\n    radio_guarded((), || radio_receive(link, &frame));'
  _case "an entry called before the guard fails" 1 'the export receive is not one guarded call' "${t}"

  t="${tmp}/two-under"; _tree "${t}"
  _line "${t}/${SHIM}" 'radio_guarded((), || radio_receive(' '    radio_guarded((), || { let _ = radio_left_ms(); radio_receive(link, &frame) });'
  _case "two entries under one guard fail" 1 'the export receive is not one guarded call' "${t}"

  t="${tmp}/two-guards"; _tree "${t}"
  _line "${t}/${SHIM}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_guarded(0, radio_left_ms) + radio_guarded(0, radio_left_ms))'
  _case "two guarded calls in one export fail" 1 'the export leftMs is not one guarded call' "${t}"

  t="${tmp}/beside"; _tree "${t}"
  _line "${t}/${SHIM}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_guarded(0, || { crate::api::mesh_stop(); radio_left_ms() }))'
  _case "something else called under the guard, beside the entry, fails" 1 'the export leftMs is not one guarded call' "${t}"

  t="${tmp}/converted-under"; _tree "${t}"
  _line "${t}/${SHIM}" 'radio_guarded((), || radio_receive(' '    radio_guarded((), || radio_receive(link.rotate_left(1), &frame));'
  _case "a call made under the guard, among the entry's arguments, fails" 1 'the export receive is not one guarded call' "${t}"

  t="${tmp}/not-an-entry"; _tree "${t}"
  _line "${t}/${SHIM}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_guarded(0, crate::api::mesh_empty))'
  _case "an export that calls something that is no radio entry fails" 1 'the export leftMs is not one guarded call' "${t}"

  t="${tmp}/helper-calls"; _tree "${t}"
  _line "${t}/${SHIM}" 'jlong::try_from(ms).unwrap_or(jlong::MAX)' '    jlong::try_from(ms.max(radio_left_ms())).unwrap_or(jlong::MAX)'
  _case "an entry called from a helper, outside every export, fails" 1 'names a radio entry outside an export' "${t}"

  t="${tmp}/unsafe-in-shim"; _tree "${t}"
  _line "${t}/${SHIM}" 'jlong::try_from(ms).unwrap_or(jlong::MAX)' '    unsafe { i64::try_from(ms).unwrap_unchecked() }'
  _case "an unsafe block in the shim fails" 1 "${SHIM} writes unsafe" "${t}"

  t="${tmp}/c-abi"; _tree "${t}"
  sed -i 's/^pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(/pub extern "C" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(/' "${t}/${SHIM}"
  _case "an export declared with another ABI fails" 1 'exports something that is not' "${t}"

  t="${tmp}/mangled"; _tree "${t}"
  sed -i '0,/^#\[no_mangle\]$/{/^#\[no_mangle\]$/d}' "${t}/${SHIM}"
  _case "an export without no_mangle fails" 1 'exports something that is not' "${t}"

  t="${tmp}/on-load"; _tree "${t}"
  sed -i 's/^#\[cfg(test)\]$/#[no_mangle]\npub extern "system" fn JNI_OnLoad(vm: *mut u8, _reserved: *mut u8) -> i32 {\n    0x0001_0006\n}\n\n#[cfg(test)]/' "${t}/${SHIM}"
  _case "a symbol exported from the shim that is no method of MeshNative fails" 1 'exports something that is not' "${t}"

  # Check 4: the exports are the pinned ones.
  t="${tmp}/tenth"; _tree "${t}"
  sed -i 's/^#\[cfg(test)\]$/#[no_mangle]\npub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_reset(\n    _env: JNIEnv,\n    _this: JObject,\n) -> jlong {\n    millis_out(radio_guarded(0, radio_left_ms))\n}\n\n#[cfg(test)]/' "${t}/${SHIM}"
  _case "an export the fixture does not list fails" 1 '> reset ()J - jlong' "${t}"

  t="${tmp}/missing"; _tree "${t}"
  printf 'wakeInMs ()J - jlong\n' >>"${t}/${EXPORTS}"
  _case "a pinned method the shim does not export fails" 1 '< wakeInMs ()J - jlong' "${t}"

  t="${tmp}/renamed"; _tree "${t}"
  sed -i 's/MeshNative_leftMs(/MeshNative_left(/' "${t}/${SHIM}"
  _case "an export under another name fails" 1 '> left ()J - jlong' "${t}"

  t="${tmp}/type"; _tree "${t}"
  sed -i 's/^    link: jlong,$/    link: jint,/' "${t}/${SHIM}"
  _case "a parameter of another type fails" 1 '> receive (I[B)V jint,JByteArray -' "${t}"

  t="${tmp}/answer"; _tree "${t}"
  sed -i 's/^) -> jlong {$/) -> jboolean {/' "${t}/${SHIM}"
  _case "an answer of another type fails" 1 '> leftMs ()Z - jboolean' "${t}"

  t="${tmp}/descriptor"; _tree "${t}"
  sed -i 's/^leftMs ()J - jlong$/leftMs ()I - jlong/' "${t}/${EXPORTS}"
  _case "a pinned descriptor its own types do not make fails" 1 '< leftMs ()I - jlong' "${t}"

  t="${tmp}/order"; _tree "${t}"
  sed -i 's/^    link: jlong,$/    frame: JByteArray,/; 0,/^    frame: JByteArray,$/! s/^    frame: JByteArray,$/    link: jlong,/' "${t}/${SHIM}"
  _case "two parameters in the other order fail" 1 '> receive ([BJ)V JByteArray,jlong -' "${t}"

  t="${tmp}/no-receiver"; _tree "${t}"
  sed -i '0,/^    _this: JObject,$/{/^    _this: JObject,$/d}' "${t}/${SHIM}"
  _case "an export that takes no receiver fails" 1 '> ? leftMs' "${t}"

  t="${tmp}/unknown-type"; _tree "${t}"
  sed -i 's/^    link: jlong,$/    link: jshort,/' "${t}/${SHIM}"
  _case "a parameter of a type the descriptors have no letter for fails" 1 '> ? receive' "${t}"

  # Check 5: what the shim does with a JNIEnv.
  t="${tmp}/global-ref"; _tree "${t}"
  _line "${t}/${SHIM}" 'let mut links = [0; 1];' '    let mut links = [0; 1];\n    let _ = env.new_global_ref(&ready);'
  _case "a global reference made in the shim fails" 1 'calls new_global_ref on a JNIEnv' "${t}"

  t="${tmp}/callback"; _tree "${t}"
  sed -i 's/^    let read = env$/    let read = env\n        .call_method(&frame, "size", "()I", &[])\n        .and_then(|_| env.get_array_length(&frame))\n        .map(drop);\n    let read = env/' "${t}/${SHIM}"
  _case "a call into Java, split over two lines, fails" 1 'calls call_method on a JNIEnv' "${t}"

  t="${tmp}/other-name"; _tree "${t}"
  sed -i 's/^fn settled<T>(env: &JNIEnv, /fn settled<T>(jni: \&JNIEnv, /; s/let _ = env.exception_clear();/let _ = jni.exception_clear();/' "${t}/${SHIM}"
  _case "a JNIEnv bound under another name fails" 1 "binds a JNIEnv as 'jni'" "${t}"

  t="${tmp}/vm"; _tree "${t}"
  _line "${t}/${SHIM}" 'use jni::JNIEnv;' 'use jni::{JNIEnv, JavaVM};'
  _case "a JavaVM named in the shim fails" 1 'names a JavaVM' "${t}"

  t="${tmp}/state"; _tree "${t}"
  sed -i 's/^fn millis_out(ms: u64) -> jlong {$/static LAST: std::sync::Mutex<u64> = std::sync::Mutex::new(0);\n\nfn millis_out(ms: u64) -> jlong {/' "${t}/${SHIM}"
  _case "state kept in the shim between calls fails" 1 'names a JavaVM' "${t}"

  # Misconfiguration.
  t="${tmp}/no-shim"; _tree "${t}"
  rm "${t}/${SHIM}"
  _case "a missing shim is a misconfiguration" 2 '' "${t}"

  t="${tmp}/vacuous"; _tree "${t}"
  sed -i 's/Java_com_oblivioustech_haven_mesh_MeshNative_/Java_com_oblivioustech_haven_radio_Native_/' "${t}/${SHIM}"
  _case "a shim that declares no export of MeshNative is a misconfiguration, not a pass" 2 'would be reading nothing' "${t}"

  t="${tmp}/unpinned"; _tree "${t}"
  sed -i '/^[a-zA-Z]/d' "${t}/${EXPORTS}"
  _case "a fixture that lists no method is a misconfiguration, not a pass" 2 'would be reading nothing' "${t}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  '') run_check ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
