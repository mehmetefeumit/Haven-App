#!/usr/bin/env bash
# CI guard: the Bluetooth mesh's radio reaches Rust through a fixed list of JNI
# exports that decide nothing, and the bridge crate writes `unsafe` in three
# files (docs/BLUETOOTH_MESH_M3_DESIGN.md §A.6, F-8, F-14, §N.1.1); and the
# radio's Kotlin logs nothing, names its modes at one site and keeps its JVM
# tests (§B.1, §B.8–B.10).
#
# Android's radio service drives the mesh engine through two files of
# `haven/rust_builder/src`:
#
#   * `mesh_jni.rs` — the exports: one `extern "system"` function for each
#     native method of the Kotlin class `com.oblivioustech.haven.mesh.MeshNative`.
#     The crate's `unsafe_code` deny is lifted for this module, because the
#     lint fires on `#[no_mangle]`; so INSIDE IT THE COMPILER CHECKS NOTHING
#     of that kind — not an `unsafe` block, not a second exported symbol. Two
#     things read the file in its place: this guard, and the Rust test
#     `every_export_is_one_guarded_call`. The guard takes each of its lines
#     for blank, a comment, a one-line `use`, or part of an export — the file
#     holds nothing else, has no quote but an export's `"system"`, and each
#     export is one call that hands its parameters on.
#   * `mesh_radio.rs` — what each export forwards to: the conversions, the one
#     `radio_*` call under the panic guard, the answer. It is under the deny.
#
# And before it makes a Bluetooth object the service is to install the log
# lever (§M.2, §N.1), a third file:
#
#   * `log_lever.rs` — five functions of the platform's `liblog` found by name
#     at run time, a logger of Haven's own handed to it, and the check that it
#     is the one in force. The deny is lifted for this module too, because a
#     symbol lookup, a C callback and a call through a function pointer are
#     each `unsafe`; so here as well the compiler reports nothing, and check
#     13 reads the file in its place. What the lever decides — which tags are
#     Haven's, what a build writes, what a check comes to — is `lever_*` in
#     `api.rs`, under the deny.
#
# What a review of a later change can miss, none of it a compile error:
#
#   * A PANIC THAT LEAVES AN EXPORT ENDS THE PROCESS. An unwind out of an
#     `extern` function aborts, and the process is also the one that publishes
#     to relays. So every call makes its one `radio_*` call inside
#     `radio_guarded` (`catch_unwind`), with nothing else under it, and
#     nothing else in the file calls an entry.
#
#   * A JNI NAME OR TYPE THAT DOES NOT MATCH IS A RUN-TIME ERROR. Kotlin finds
#     a native method by its symbol when it is first called. The exports are
#     therefore pinned — name, JNI descriptor, Rust types — in
#     `haven/rust_builder/fixtures/mesh_radio_exports.txt`, and held to that
#     list here, both ways.
#
#   * THE SHIM CALLS NOTHING OF JAVA'S. It copies arrays in and one array out
#     and clears an exception; it keeps no `JavaVM`, no reference and no state,
#     so nothing of the engine can reach Kotlin except as an export's answer.
#
#   * `unsafe` IS CONFINED. The crate denies `unsafe_code` and allows it on
#     three modules: the generated bridge, the exports' file and the log
#     lever. An allowance moved to the crate, or to `api.rs`, would compile.
#
#   * AN API-30 SYMBOL IMPORTED STOPS THE LIBRARY LOADING ON ANDROID 6 TO 10 —
#     all of Haven there, not the mesh. The lever's five functions are
#     therefore looked up with `dlsym`, never declared `extern`, and named in
#     no other file; `android_log_sys`, which declares one ready to call, is
#     named in none.
#
#   * THE LEVER'S LOGGER RUNS INSIDE THE PLATFORM'S LOG CALL, on whichever
#     thread logs. A log call, a lock or an allocation there can deadlock or
#     recurse, and an unwind out of it aborts the process.
#
# WHAT THIS GUARD IS. A reader of text, not the compiler. It stops ordinary
# and careless erosion — an `unsafe` block added to `api.rs`, a helper grown
# in the exports' file, a log line in an adapter — and makes a deliberate one
# conspicuous in review. It is no proof against someone who sets out to hide
# code from it, and who could as well edit this file. It reads the Rust files
# under `haven/rust_builder/src` and nothing else of the crate: not a file
# outside `src/`, and not a lint level set outside it — a `[lints]` table,
# `RUSTFLAGS`, `--cap-lints`, a `build.rs`. Today the crate has no `[lints]`
# table and no `build.rs`, and the one `RUSTFLAGS` its Android build passes
# is a library search path (cargokit); nothing here pins that. What no text
# check stands in for is a check of the built library: that its exported
# `Java_*` symbols are the eleven of the fixture and the keyring's one, and
# that it imports no `__android_log_*` symbol newer than the oldest Android
# Haven runs on — `check_mesh_radio_symbols.sh`, on the library
# `build-check.yml` builds.
#
# How it reads Rust: line by line, with comments taken out by a small lexer
# of its own — a `//` or `/*` inside a string is text, on whichever line the
# string began; a raw string ends at its own hashes; a character literal is
# taken whole and a lifetime or label is not one; block comments nest. That
# is what the review plants needed, not the language's whole grammar. Checks:
#   1. Under haven/rust_builder/src, outside `frb_generated.rs`,
#      `mesh_jni.rs` and `log_lever.rs`: no keyword `unsafe`, no keyword
#      `extern` (with an ABI string or bare), and no `no_mangle`,
#      `export_name` or `link_section`.
#   2. `lib.rs` carries `#![deny(unsafe_code)]`, and `unsafe_code` is named
#      four times in the crate's hand-written source: that line, and one
#      `#[allow(unsafe_code)]` directly above each of `mod frb_generated;`,
#      `mod mesh_jni;` and `mod log_lever;`.
#   3. `mesh_jni.rs` is exactly `use`s and exports. Every line of code belongs
#      to a `use …;` or to an item of the one shape — `#[no_mangle]` directly
#      above `pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_<name>(`
#      — whose body is one call, `mesh_radio::<name in snake case>(…)`, on the
#      export's own parameters in the order declared (`&env` first when the
#      export names its environment; an array by reference). The file names no
#      `unsafe`, `export_name`, `link_section`, `used`, `mod`, `impl`,
#      `static`, `cfg` or `JNIEnv::` and invokes no macro, and it has as many
#      `extern` keywords, and as many `no_mangle`, as exports. A `use` is
#      one line — `use a::b;` or `use a::{B, C};` — with no rename, no glob
#      and nothing after it; what the exports forward to is imported as
#      `use crate::mesh_radio;` and in no other way; and the one quote in the
#      file is the `"system"` of an export's header.
#   4. The exports — name, Rust parameter types after the environment and the
#      receiver, Rust return type, and the JNI descriptor those types make —
#      are the lines of the fixture, in whatever order, and no others.
#   5. `mesh_radio.rs`, up to its tests: for every pinned method, one
#      `pub(crate) fn <name in snake case>(` that names `radio_guarded(` once,
#      no `radio_*` before it, and under the guard `radio_<that name>` alone —
#      by name, or as a closure that is its call, with no call among its
#      arguments; outside those functions and the one `use crate::api::{…}`
#      nothing names a `radio_*`. A `JNIEnv` is only ever a parameter
#      `env: &JNIEnv`, used to call ENV_MAY_CALL or handed on as an argument:
#      never bound under another name, never named as a path (`JNIEnv::`). The
#      file names no `JavaVM`, `GlobalRef`, `WeakRef`, `JNI_OnLoad`, `static`
#      or `thread_local`. Its tests are the one `#[cfg(test)]` directly above
#      `mod tests {`, and nothing follows them: this check reads no further,
#      so nothing that ships may sit there.
#   6. The ways found so far of building one of the three modules from a
#      file other than the one read above: no file of the crate's hand-written
#      source writes `path` and an `=` where an attribute's argument starts
#      (`#[path = …]`, bare, under `cfg_attr` or from a macro; a variable
#      named `path` may be assigned) or invokes `include!`; and `lib.rs` names
#      `mesh_jni`, `mesh_radio` and `log_lever` once each, as `mod <name>;`
#      directly under the pinned attribute lines —
#      `#[cfg(any(target_os = "android", test))]`, and for `mesh_jni` and
#      `log_lever` the allowance — which follow the end of another item.
#
# And over the radio's Kotlin — every `.kt` under a `mesh/` directory of
# `haven/android/app/src`, whatever the source set — with comments stripped
# the same way:
#   7. No log call, logger or standard stream (`Log.` or `Log::`, `Timber`
#      the same, `println(`, `print(`, `printStackTrace(`, `System.out`,
#      `System.err`, `Logger`, `logging`), no import of `android.util.Log`, a
#      `timber` package or `java.util.logging` under any name, and no UUID in
#      canonical form there or in the JVM tests.
#   8. `MeshRadioConstants.kt` names the Android scan mode, advertise mode,
#      advertise power and connection priority it holds, and no other file
#      names one. And it alone builds a UUID — the service's, the
#      characteristic's and the descriptor's, from the six numbers the JVM
#      test `theUuidsAreTheOnesDrawn` holds: no other file calls `UUID(`,
#      names a member of `UUID` or `ParcelUuid.fromString`, or imports `UUID`
#      under another name.
#   9. `scripts/ci/native_log_allowlist.txt` has no row for a file under a
#      `mesh/` directory.
#  10. No `AndroidManifest.xml` under `haven/android/app/src` but the mesh's
#      own (`src/mesh/`) names Bluetooth, `connectedDevice` or the mesh.
#  11. The tests of `haven/android/mesh-jvm/src/test` are JVM_TEST_NAMES, each
#      `@Test` directly above `fun <name>()`, and none is ignored or assumes
#      its way out. That each of them ran is `run_mesh_jvm_tests.sh`'s to
#      say; that its body still asserts anything is nobody's but a reviewer's.
#  12. `MeshRadioConstants.RSSI_FLOOR` is the engine's default `rssi_floor`:
#      the first `rssi_floor: <integer>,` after the line
#      `impl Default for Config {` of `haven-core/src/mesh/engine.rs`, against
#      the line `const val RSSI_FLOOR = <integer>`.
#
# And over the log lever, back in the crate's Rust:
#  13. `log_lever.rs`. Its `unsafe` is LEVER_UNSAFE_BLOCKS blocks — no
#      `unsafe fn`, no `unsafe impl` — and the function-pointer types it
#      declares as `type <Name> = unsafe extern "C" fn(…`; its one `extern`
#      function is the logger. Up to its tests: it names no `no_mangle`,
#      `export_name`, `link_section`, `used`, `static mut`, `thread_local`,
#      `impl`, `mod`, `macro_rules`, `JNIEnv`, `radio_`, `log::`, `unwrap`,
#      `expect(`, `Box`, `Vec`, `String`, `Mutex` or `RwLock`; invokes no
#      macro but `cfg!` and the struct layout's one compile-time
#      `assert!(matches!(… offset_of!(…`; holds no string but the library's
#      name, the five functions', the ABI of a pointer type and the target of
#      its one `cfg!`; names of
#      `libc` only `dlopen`, `dlsym` and `RTLD_NOW`, each by its path; and of
#      the bridge only `lever_*` and `LEVER_*`, in one `use crate::api::{…};`.
#      Its tests are the one `#[cfg(test)]` directly above `mod tests {`, and
#      nothing follows them. No file of the crate names `android_log_sys`,
#      and none but this one names any of the five functions.
#
# The Kotlin is read with the lexer made for Rust: comments and plain strings
# as above, not Kotlin's string templates or raw strings.
#
# That the pure package imports nothing of Android is not checked here: its
# JVM build has no Android SDK, so the compiler holds it (android-unit.yml).
#
# What this scan covers, and no more. It reads names. In the files under the
# deny it cannot see `unsafe` that a macro writes: the compiler reports what a
# macro of this crate expands to, and is not relied on here for one that comes
# from another crate — which is why the exports' file, where the compiler
# reports nothing either way, may invoke no macro at all. It cannot see a
# `JNIEnv` handed to a function that calls Java, nor what an entry does once
# called. Of the lever it cannot see an index that could panic, nor that an
# `unsafe` block's argument is true: the count is pinned so that a new block
# is a change to this file, which a reviewer reads. What each call does with
# its arguments is held by tests in
# `haven/rust_builder/src`: `mesh_radio::tests` (the conversions),
# `the_calls_a_jni_export_forwards_reach_their_entries_each_argument_in_its_place`
# (the seven calls that take no array, against the engine),
# `a_call_that_panics_under_the_guard_…`, `every_export_is_one_guarded_call`,
# `the_radio_entries_take_no_session`; and for the lever by `log_lever::tests`
# and, in `api.rs`, `the_levers_tags_are_the_scanners`,
# `a_tag_is_havens_when_it_is_an_entry_or_an_entry_and_two_colons`,
# `a_release_build_reads_and_writes_no_line_and_a_debug_build_writes_only_havens`,
# `the_lever_holds_when_its_logger_took_the_sentinel_and_a_release_builds_floor_stands`,
# `the_levers_two_calls_answer_no_lever_off_android_and_nothing_else_reaches_it`,
# `the_lever_holds_nothing_that_panics_allocates_or_locks`.
#
# Not here yet, each with the change that makes it checkable:
#   * The Kotlin half of check 4 — the `external fun`s of `MeshNative.kt`
#     against the same fixture — lands with that file, which does not exist:
#     a check with nothing to read would report a parity it has not seen. The
#     two interfaces `MeshNative` will implement, `MeshEngineApi` and
#     `LogLever`, are held to the fixture by the JVM test
#     `theTwoNativeInterfacesAreTheElevenExportsOfTheFixture`.
#   * The mesh's own manifest (no `android:process`, `connectedDevice`, the
#     receiver not exported, `neverForLocation`), that every adapter callback
#     runs inside `MeshThread.run`, and what an advertisement may not carry:
#     with the adapters.
#
# Usage:
#   bash scripts/ci/check_mesh_radio.sh
#   bash scripts/ci/check_mesh_radio.sh --self-test
#
# Exit codes:
#   0  all checks pass (or the self-test passed)
#   1  a check failed (or the self-test failed)
#   2  an expected file or directory is missing, or the exports' file or the
#      fixture lists no export — the scan would be reading nothing
#      (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly SRC='haven/rust_builder/src'
readonly LIB="${SRC}/lib.rs"
readonly SHIM="${SRC}/mesh_jni.rs"
readonly CALLS="${SRC}/mesh_radio.rs"
readonly LEVER="${SRC}/log_lever.rs"
readonly GENERATED="${SRC}/frb_generated.rs"
readonly EXPORTS='haven/rust_builder/fixtures/mesh_radio_exports.txt'
readonly HEADER='pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_'
# Every call the shim may make on a `JNIEnv`: two array reads with the length
# they are bounded by, one array made for the answer, and the clearing of an
# exception a failed call left.
readonly -a ENV_MAY_CALL=(
  get_array_length get_long_array_region convert_byte_array byte_array_from_slice exception_clear
)

# The `unsafe` blocks of LEVER, each with its SAFETY argument: two for the
# lookup and one for the cast of what it found, three for a message's size,
# tag pointer and tag bytes, one for each of the five calls through a function
# of `liblog`. Pinned, because a twelfth compiles.
readonly LEVER_UNSAFE_BLOCKS=11
# What LEVER looks up: the only strings it holds beside an ABI and the target
# of its `cfg!`.
readonly -a LEVER_STRINGS=(
  liblog.so
  __android_log_set_logger
  __android_log_logd_logger
  __android_log_write_log_message
  __android_log_set_minimum_priority
  __android_log_get_minimum_priority
)

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=170

# The Kotlin of the radio (design §B): the app's mesh packages, whatever the
# source set, and the JVM build of the pure one with its tests.
readonly APP_SRC='haven/android/app/src'
readonly CORE="${APP_SRC}/main/kotlin/com/oblivioustech/haven/mesh/core"
readonly CONSTANTS="${CORE}/MeshRadioConstants.kt"
readonly JVM_TESTS='haven/android/mesh-jvm/src/test'
readonly LOG_ALLOWLIST='scripts/ci/native_log_allowlist.txt'
readonly ENGINE='haven-core/src/mesh/engine.rs'
# What lib.rs has above each of the two modules' declarations, and nothing more.
readonly RADIO_CFG='#[cfg(any(target_os = "android", test))]'
# The platform's radio modes: named in CONSTANTS, used by no other file.
readonly MODES='(SCAN_MODE|ADVERTISE_MODE|ADVERTISE_TX_POWER|CONNECTION_PRIORITY)_[A-Z]'
# The JVM tests, by name: design §B.10's, the ones M3f added, and from
# `aLeverThatStopsHoldingIsPutBackAndStopsTheRadio` on those of M3g's second
# unit (§N.2). Pinned, because a test that is deleted, renamed or ignored
# fails nothing.
readonly -a JVM_TEST_NAMES=(
  aPolledFrameIsSentOrItsLinkIsClosed
  aLinkWithAFrameInFlightIsNotReady
  everyInputChecksTheDeadlineBeforeAnythingElse
  anAddressNeverReachesTheEngine
  aConnectForAPeerNoLongerKnownFailsAtOnce
  thePumpStopsAtItsBudgetAndComesBack
  theWakeIsTheEnginesAndTheLockIsCapped
  bluetoothOffTellsEveryLinkDownAndSendsNothing
  unlinkedConnectionsAreCappedAndTimedOut
  aRadioPortThatThrowsStopsTheRadioAndNothingEscapes
  aFrameWhoseCompletionNeverComesClosesItsLink
  theScanRestartIsATermOfTheAlarm
  aStartWithoutTheBluetoothPermissionIsAStopWithTheNotice
  outputsDecodeAsTheFixtureSays
  theScanIsRestartedBeforeThirtyMinutesAndNeverTwiceInSixSeconds
  theReminderComesOnceAtThirtyMinutesAndTheStopAtZero
  whatIsAskedAndWhetherItCanSearchPerApiLevel
  theAdvertisementIsTheServiceUuidAlone
  theRadioModesComeFromOneSite
  theTwoNativeInterfacesAreTheElevenExportsOfTheFixture
  thePeerTableHoldsSixtyFourAndForgetsOnePickedAmongThoseNotHeld
  aFloodOfAddressesDoesNotPushOutAPeerUnlessItIsPicked
  theTableABuildHasForgetsByNoFixedRule
  anAddressBeingDialledOrLinkedIsNeverForgotten
  aWeakAddressNotYetKnownTakesNoPlaceAndIsNeverToldToTheEngine
  aWeakSightingOfAKnownAddressIsToldToTheEngine
  aCompletionWhileARefusedFrameWaitsClosesItsLink
  aLinkTheEngineClosesAtOnceHoldsNoLock
  aLinkBeyondTheEnginesEightIsClosed
  aLinkTheEngineClosesIsClosedAndALinkLostIsToldDown
  anEngineThatAnswersNoWakeIsGone
  aStopTheUserDidNotMakeIsAStopWithTheNoticeAndIsFinal
  anEngineWhoseTimeIsUpStopsTheServiceWithTheNotice
  aLeverThatStopsHoldingIsPutBackAndStopsTheRadio
  inTheServiceTheForegroundComesBeforeAnyRefusal
  belowApiThirtyAStartIsUnsupportedAndTouchesNothing
  aLeverThatIsMissingIsUnsupportedAndOneThatDoesNotHoldIsFailed
  aStartBehindALogoutIsAStopWithNoNotice
  theStopCancelsTheAlarmAfterTheRadioIsDown
  theUuidsAreTheOnesDrawn
  aConnectionThatNeverWritesHavensDescriptorIsNeverKnown
  aSubscriberLinksAtOnceWhereItsConnectionsMtuIsKnownAndAtItsNextMtuWhereNot
  theMtuThisPhonesOwnDialWasToldServesThatDevicesSubscription
  anMtuNoteGoesAtDisconnectAtTheCapAndWithTheRadio
  aLongAnOffsetOrAnAnsweredWriteIsRefusedAndItsLinkClosed
  aDeviceThatStartsToBondIsDroppedOnlyIfItIsHavens
  aCloseForgetsASubscriberAndAFrameGoesToItsDeviceAlone
  anOutgoingLinkIsMtuThenDiscoveryThenSubscription
  aStepThatFailsOrTwentyFiveSecondsIsOneFailedConnect
  aConnectionThatFailsBeforeItsLinkIsTriedOnceMore
  aClientIsClosedAfterEveryDisconnectAndAtTheRadiosStop
  theChannelsWordsAreTheseAndTheStatusIsOneFunction
  onlyThreeChannelMethodsAreBehindTheLever
  theTapHeldForAnEngineIsKeepOnIfAnyWas
)

readonly B='(^|[^A-Za-z0-9_])'
readonly E='([^A-Za-z0-9_]|$)'

FAILED=0

log() {
  printf '\033[1;34m[check_mesh_radio]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_mesh_radio] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

# Comment-stripped view of a Rust file, line numbering preserved, read as the
# compiler reads it: a comment opener inside a string or a character literal is
# text, on whichever line the literal began; a raw string ends at its own
# hashes; block comments nest. With `blank`, the text of every string literal
# is dropped too: a keyword in a string is not the keyword.
code_view() { # <file> [blank]
  LC_ALL=C awk -v blank="${2:-}" -v sq="'" '
    function ident(at) { return at >= 1 && substr(line, at, 1) ~ /[A-Za-z0-9_]/ }
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1); two = substr(line, i, 2)
        if (mode == "block") {
          if (two == "*/") { i += 2; if (--depth == 0) mode = "" }
          else if (two == "/*") { depth++; i += 2 }
          else i++
        } else if (mode == "str") {
          if (c == "\\") { if (!blank) out = out two; i += 2 }
          else if (c == "\"") { out = out c; mode = ""; i++ }
          else { if (!blank) out = out c; i++ }
        } else if (mode == "raw") {
          if (substr(line, i, length(fin)) == fin) { out = out fin; i += length(fin); mode = "" }
          else { if (!blank) out = out c; i++ }
        }
        else if (two == "/*") { mode = "block"; depth = 1; i += 2 }
        else if (two == "//") { i = n + 1 }
        else if (c == sq) {
          # A character literal — an escape up to its closing quote, or one
          # character, which is several bytes when it is not ASCII — is taken
          # whole. Anything else is a lifetime or a label: the quote alone.
          k = i + 1; len = 1
          if (substr(line, k, 1) == "\\") {
            k = index(substr(line, i + 3), sq)
            if (k) len = k + 3
          } else if (substr(line, k, 1) != sq) {
            if (substr(line, k, 1) >= "\200") { while (k <= n && substr(line, k, 1) >= "\200") k++ } else k++
            if (substr(line, k, 1) == sq) len = k - i + 1
          }
          out = out substr(line, i, len); i += len
        }
        else if (c == "\"") {
          # `r"…"`, `r#"…"#`, and the same after `b` or `c`: no escape inside.
          r = i - 1; fin = "\""
          while (r >= 1 && substr(line, r, 1) == "#") { fin = fin "#"; r-- }
          raw = r >= 1 && substr(line, r, 1) == "r" \
            && (!ident(r - 1) || (substr(line, r - 1, 1) ~ /[bc]/ && !ident(r - 2)))
          mode = raw ? "raw" : "str"; out = out c; i++
        }
        else { out = out c; i++ }
      }
      print out
    }' "$1"
}

# "<first> <last>" for each item of a view on stdin declared `<prefix>…` at
# the start of a line: from its declaration to the brace that closes it.
item_lines() { # <declaration prefix>
  awk -v prefix="$1" '
    index($0, prefix) == 1 && !inside { inside = 1; first = NR; depth = 0; opened = 0 }
    inside {
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        if (chars[i] == "{") { depth++; opened = 1 }
        else if (chars[i] == "}") { depth-- }
      }
      if (opened && depth == 0) { inside = 0; print first, NR }
    }'
}

# For each export of a view on stdin, on one line and tab-separated: its name;
# the fixture's row for it, or `? <name>` for a signature that is not an
# export's; the one call its body must be; and its body. The last two have no
# whitespace.
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
    function snake(name,    out, i, c) {
      out = ""
      for (i = 1; i <= length(name); i++) {
        c = substr(name, i, 1)
        out = out ((c ~ /[A-Z]/) ? "_" tolower(c) : c)
      }
      return out
    }
    index($0, header) == 1 && !insig && !inbody { sig = ""; insig = 1 }
    insig {
      sig = sig $0
      if ($0 !~ /\{[[:space:]]*$/) next
      insig = 0; inbody = 1; body = ""
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
      types = ""; taken = ""; handed = ""; seen = 0
      for (i = 1; i <= count; i++) {
        if (each[i] == "") continue
        type = each[i]; sub(/^[^:]*:/, "", type)
        param = each[i]; sub(/:.*$/, "", param)
        seen++
        if (seen == 1) {
          if (type != "JNIEnv" || (param != "env" && param != "_env")) ok = 0
          if (param == "env") handed = "&env"
          continue
        }
        if (seen == 2) { if (type != "JObject" || param != "_this") ok = 0; continue }
        if (letter(type) == "" || type == "jbyteArray") ok = 0
        types = types (types == "" ? "" : ",") type
        taken = taken letter(type)
        handed = handed (handed == "" ? "" : ",") ((type ~ /^J/) ? "&" : "") param
      }
      if (seen < 2) ok = 0
      if (answer != "" && (letter(answer) == "" || answer == "JByteArray" || answer == "JLongArray")) ok = 0
      row = ok ? name " (" taken ")" (answer == "" ? "V" : letter(answer)) " " (types == "" ? "-" : types) " " (answer == "" ? "-" : answer) : "? " name
      forward = "mesh_radio::" snake(name) "(" handed ")"
      next
    }
    inbody {
      if ($0 == "}") {
        inbody = 0
        sub(/;$/, "", body); sub(/,\)$/, ")", body)
        printf "%s\t%s\t%s\t%s\n", name, row, forward, body
        next
      }
      line = $0; gsub(/[[:space:]]/, "", line); body = body line
    }'
}

# The line of the `#[cfg(test)]` directly above `mod tests {` in a view on
# stdin, or 0.
tests_at() {
  awk '$0 == "#[cfg(test)]" { at = NR } $0 == "mod tests {" && at == NR - 1 && !found { found = at } END { print found + 0 }'
}

# The lines of a view on stdin that a reader which stops at the tests would
# not read as shipped: a cfg(test) that is not the tests', or anything after
# their module.
beyond_tests() { # <the tests' line>
  awk -v tests="$1" '
    /cfg/ && /(^|[^A-Za-z0-9_])test([^A-Za-z0-9_]|$)/ && NR != tests { printf "%d ", NR }
    tests && NR > tests + 1 && closed && !/^[[:space:]]*$/ { printf "%d ", NR }
    tests && NR > tests + 1 && $0 == "}" { closed = 1 }'
}

run_check() {
  local file rel view hits shim calls shipped rows pinned names name row forward body first last
  local guards before after entries called alone outside tests want range method may ok
  local kotlin jvm found floor lever

  [[ -d "${REPO_ROOT}/${SRC}" ]] || { echo "ERROR: ${REPO_ROOT}/${SRC} not found" >&2; exit 2; }
  for file in "${LIB}" "${SHIM}" "${CALLS}" "${LEVER}" "${GENERATED}" "${EXPORTS}" "${CONSTANTS}" "${LOG_ALLOWLIST}" "${APP_SRC}/main/AndroidManifest.xml" "${ENGINE}"; do
    [[ -f "${REPO_ROOT}/${file}" ]] || { echo "ERROR: ${REPO_ROOT}/${file} not found" >&2; exit 2; }
  done
  [[ -d "${REPO_ROOT}/${JVM_TESTS}" ]] || { echo "ERROR: ${REPO_ROOT}/${JVM_TESTS} not found" >&2; exit 2; }
  shim="$(code_view "${REPO_ROOT}/${SHIM}")"
  calls="$(code_view "${REPO_ROOT}/${CALLS}")"
  rows="$(export_rows <<<"${shim}")"
  pinned="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/${EXPORTS}" || true)"
  if [[ -z "${rows}" || -z "${pinned}" ]]; then
    echo "ERROR: ${SHIM} declares no '${HEADER}…', or ${EXPORTS} lists none — the checks would be reading nothing. If the shim moved, move this guard with it." >&2
    exit 2
  fi

  log "Checking that unsafe is written in three files, that the radio's JNI exports are the pinned ones, each one forward to one guarded call, the log lever's file, and the radio's Kotlin ..."

  # Check 1: where `unsafe`, `extern` and an exported symbol are written.
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    case "${rel}" in "${GENERATED}" | "${SHIM}" | "${LEVER}") continue ;; esac
    view="$(code_view "${file}" blank)"
    hits="$(grep -nE "${B}(unsafe|extern|no_mangle|export_name|link_section)${E}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} writes unsafe, extern, or an attribute that exports a symbol (line(s) ${hits}). In the bridge crate only ${GENERATED}, ${SHIM} and ${LEVER} may write unsafe or extern, and only the first two export a symbol: every other file is safe Rust the compiler checks whole, and a symbol exported from anywhere else is one no guard has read."
    fi
  done < <(find "${REPO_ROOT}/${SRC}" -type f -name '*.rs' | LC_ALL=C sort)

  # Check 2: the lint that makes check 1 the compiler's too.
  view="$(code_view "${REPO_ROOT}/${LIB}" | sed -E 's/[[:space:]]+$//; /^$/d')"
  if [[ "$(grep -cxF '#![deny(unsafe_code)]' <<<"${view}" || true)" != 1 ]]; then
    fail "${LIB} does not carry #![deny(unsafe_code)] exactly once. Without it nothing but check 1's reading of names keeps unsafe out of api.rs."
  fi
  hits="$(grep -A1 -xF '#[allow(unsafe_code)]' <<<"${view}" | grep -vxF -e '#[allow(unsafe_code)]' -e '--' | LC_ALL=C sort | tr '\n' ' ' || true)"
  if [[ "${hits}" != 'mod frb_generated; mod log_lever; mod mesh_jni; ' || "$(grep -c 'unsafe_code' <<<"${view}" || true)" != 4 ]]; then
    fail "${LIB} names unsafe_code otherwise than as the crate's deny and one #[allow(unsafe_code)] directly above each of 'mod frb_generated;', 'mod mesh_jni;' and 'mod log_lever;' (found above: ${hits:-nothing}). An allowance on the crate or on another module lets unsafe into code no guard reads."
  fi
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    case "${rel}" in "${GENERATED}" | "${LIB}") continue ;; esac
    view="$(code_view "${file}")"
    hits="$(grep -n 'unsafe_code' <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names the unsafe_code lint (line(s) ${hits}). Its level is set in ${LIB} alone: an allow inside a file undoes the crate's deny for that file."
    fi
  done < <(find "${REPO_ROOT}/${SRC}" -type f -name '*.rs' | LC_ALL=C sort)

  # Check 3: the exports' file is uses and exports, and each export one call.
  hits="$(awk -v header="${HEADER}" '
    function bad(n) { printf "%d ", n }
    state == "attr" {
      if (index($0, header) != 1) { bad(NR); state = ""; next }
      state = ($0 ~ /\{[[:space:]]*$/) ? "body" : "sig"; next
    }
    state == "sig" { if ($0 ~ /\{[[:space:]]*$/) state = "body"; next }
    state == "body" { if ($0 == "}") state = ""; next }
    /^[[:space:]]*$/ { next }
    /^use [A-Za-z0-9_]+(::[A-Za-z0-9_]+)*(::\{[A-Za-z0-9_]+(, [A-Za-z0-9_]+)*\})?;$/ { next }
    $0 == "#[no_mangle]" { state = "attr"; next }
    { bad(NR) }
    END { if (state != "") bad(NR) }' <<<"${shim}")"
  if [[ -n "${hits}" ]]; then
    fail "${SHIM} holds something that is neither a use nor an export — '#[no_mangle]' directly above '${HEADER}…' (line(s) ${hits}). The crate's unsafe_code deny is lifted for this file, so nothing else may be in it: a function, a second way to export a symbol, a block of code after the exports. A use is one line, 'use a::b;' or 'use a::{B, C};', with nothing after it: no rename, no glob, none over several lines. Put anything else in ${CALLS}, under the deny."
  fi
  if [[ "$(grep -E "^use .*${B}mesh_radio${E}" <<<"${shim}" || true)" != 'use crate::mesh_radio;' ]]; then
    fail "${SHIM} does not import what its exports forward to as the one line 'use crate::mesh_radio;'. Under any other import the exports call a module check 5 has not read."
  fi
  hits="$(sed -E 's/^pub extern "system" fn /pub extern fn /' <<<"${shim}" | grep -n '"' | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${SHIM} has a quote that is not the \"system\" of an export's header (line(s) ${hits}). The file needs no string and no character literal, and what follows one is read as text by whoever reads the file less exactly than the compiler."
  fi
  view="$(code_view "${REPO_ROOT}/${SHIM}" blank)"
  hits="$(grep -nE "${B}(unsafe|export_name|link_section|used|mod|impl|static|cfg)${E}|JNIEnv[[:space:]]*::|[A-Za-z0-9_]![^=]" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${SHIM} names unsafe, export_name, link_section, used, mod, impl, static, cfg or JNIEnv::, or invokes a macro (line(s) ${hits}). None has a place in a file of uses and one-call exports, and here the compiler would report none of it."
  fi
  want="$(wc -l <<<"${rows}" | tr -d ' ')"
  if [[ "$(grep -oE "${B}extern${E}" <<<"${shim}" | wc -l | tr -d ' ' || true)" != "${want}" \
    || "$(grep -o 'no_mangle' <<<"${shim}" | wc -l | tr -d ' ' || true)" != "${want}" ]]; then
    fail "${SHIM} has ${want} export(s) of MeshNative and another number of extern keywords or of no_mangle. Every symbol the file exports is a native method of MeshNative, declared one way, so that this guard reads every one."
  fi
  while IFS=$'\t' read -r name row forward body; do
    if [[ "${body}" != "${forward}" ]]; then
      fail "the export ${name} is not the one call ${forward}: its body is '${body}'. An export hands its own parameters on, in the order declared, and does nothing else — what it would do here the compiler does not check, and no test can call it."
    fi
  done <<<"${rows}"

  # Check 4: the exports are the pinned ones.
  rows="$(cut -f2 <<<"${rows}" | LC_ALL=C sort)"
  if [[ "${rows}" != "$(LC_ALL=C sort <<<"${pinned}")" ]]; then
    names="$(diff <(LC_ALL=C sort <<<"${pinned}") <(printf '%s\n' "${rows}") | grep -E '^[<>]' | tr '\n' ';' || true)"
    fail "the exports of ${SHIM} are not the lines of ${EXPORTS} ('<' pinned, '>' exported, '?' a signature that is no export's: ${names}). Kotlin finds a native method by name and passes what its own declaration says; a name or a type that differs is found when the method is first called. Change the fixture, the shim and MeshNative.kt together."
  fi

  # Check 5: what the exports forward to. Its tests are not read, so nothing
  # that ships may sit in or behind them.
  tests="$(tests_at <<<"${calls}")"
  hits="$(beyond_tests "${tests}" <<<"${calls}")"
  if [[ -n "${hits}" ]]; then
    fail "${CALLS} has a cfg(test) that is not the one '#[cfg(test)]' directly above 'mod tests {', or something after that module (line(s) ${hits}). This guard stops reading at the tests: code under another cfg(test), or behind the tests, is code it has not read."
  fi
  shipped="${calls}"
  if (( tests > 0 )); then
    shipped="$(sed -n "1,$(( tests - 1 ))p" <<<"${calls}")"
  fi
  outside="${shipped}"
  while read -r name _; do
    [[ -n "${name}" ]] || continue
    name="$(sed -E 's/([A-Z])/_\L\1/g' <<<"${name}")"
    range="$(item_lines "pub(crate) fn ${name}(" <<<"${shipped}")"
    if [[ "$(grep -c . <<<"${range}" || true)" != 1 ]]; then
      fail "${CALLS} does not declare 'pub(crate) fn ${name}(' exactly once. Each pinned method has one function there, named for its radio entry, and its export forwards to it."
      continue
    fi
    read -r first last <<<"${range}"
    body="$(sed -n "${first},${last}p" <<<"${shipped}")"
    guards="$(grep -o 'radio_guarded(' <<<"${body}" | wc -l | tr -d ' ' || true)"
    before="${body%%radio_guarded(*}"
    after="${body#*radio_guarded(}"
    entries="$(grep -oE 'radio_[A-Za-z0-9_]+' <<<"${after}" | tr '\n' ' ' || true)"
    called="$(wc -w <<<"${entries}" | tr -d ' ')"
    # Under the guard: the answer with no engine, then the entry — itself, or a
    # closure that is its call on values converted before the guard.
    alone="$(tr -d '[:space:]{}' <<<"${after}" | grep -cE "^[^,]*,(\\|\\|)?radio_${name}(\\([^()]*\\))?\\)" || true)"
    if [[ "${guards}" != 1 || "${before}" == *radio_* || "${called}" != 1 || "${alone}" != 1 ]]; then
      fail "the call ${name} of ${CALLS} is not one guarded call of radio_${name} and nothing else: it names radio_guarded( ${guards} time(s) and, under it, ${entries:-no radio entry}. An entry called outside the guard takes the process — the relay path's too — with it when it panics; anything else under the guard is a decision made in the shim."
    fi
    outside="$(awk -v first="${first}" -v last="${last}" 'NR < first || NR > last { print; next } { print "" }' <<<"${outside}")"
  done <<<"${pinned}"
  hits="$(awk '
    index($0, "use crate::api::{") == 1 { inuse = 1 }
    !inuse && /radio_/ { printf "%d ", NR }
    inuse && /};/ { inuse = 0 }' <<<"${outside}")"
  if [[ -n "${hits}" ]]; then
    fail "${CALLS} names a radio entry outside the pinned methods' functions and its one 'use crate::api::{…}' (line(s) ${hits}). Only such a function calls an entry, and only under the guard."
  fi

  # What it does with a JNIEnv, read with no whitespace so that a call broken
  # over two lines is one call.
  view="$(tr -d '[:space:]' <<<"${shipped}")"
  while IFS= read -r method; do
    [[ -n "${method}" ]] || continue
    ok=0
    for may in "${ENV_MAY_CALL[@]}"; do
      [[ "${method}" == "${may}" ]] && ok=1
    done
    if (( ok == 0 )); then
      fail "${CALLS} calls ${method} on a JNIEnv. The shim reads two arrays, makes one and clears an exception (${ENV_MAY_CALL[*]}): it calls no method of Java's, makes no reference and reaches no JavaVM, so the engine reaches Kotlin only as an export's answer."
    fi
  done < <(grep -oE "${B}env\.[A-Za-z0-9_]+\(" <<<"${view}" | sed -E 's/.*env\.//; s/\($//' | LC_ALL=C sort -u || true)
  hits="$(sed -E 's/usejni::JNIEnv;//g; s/([(,])env:&JNIEnv/\1/g; s/([^A-Za-z0-9_])env\.[A-Za-z0-9_]+\(/\1(/g; s/([(,])env([,)])/\1\2/g; s/([(,])env([,)])/\1\2/g' <<<"${view}" | grep -oE "${B}(env|JNIEnv)${E}.{0,24}" | head -n 3 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${CALLS} uses a JNIEnv otherwise than as a parameter 'env: &JNIEnv' that a whitelisted method is called on or that is handed on as an argument (at: ${hits}). Bound under another name, or named as a path, a call on it is one this guard does not read."
  fi
  hits="$(grep -nE "${B}(JavaVM|GlobalRef|WeakRef|JNI_OnLoad|static|thread_local)${E}" <<<"${shipped}" | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${CALLS} names a JavaVM, a reference that outlives a call, or state of its own (line(s) ${hits}). Every call is made by a Java thread and returns: the shim keeps nothing between two."
  fi

  # Check 6: what would make the files read above not the files built, as far
  # as text shows it.
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    [[ "${rel}" == "${GENERATED}" ]] && continue
    view="$(code_view "${file}" blank)"
    if tr -d '[:space:]' <<<"${view}" | grep -qE "[[(,]path=([^=]|\$)"; then
      fail "${rel} gives something a path (the word 'path' and an '=' where an attribute's argument starts, as in #[path = …], bare, under cfg_attr or written by a macro). A module declared in ${SRC} is the file of its name there: under a path attribute the compiler builds another file, and every check here — and the Rust tests that read ${SHIM##*/} — goes on reading the one it left."
    fi
    hits="$(grep -nE "${B}include[[:space:]]*!" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} includes a file as source (include!, line(s) ${hits}). What it includes is compiled where it stands and read by no check here, which reads the crate's .rs files; include_str! and include_bytes! take a file as data and are not this."
    fi
  done < <(find "${REPO_ROOT}/${SRC}" -type f -name '*.rs' | LC_ALL=C sort)
  view="$(code_view "${REPO_ROOT}/${LIB}" | sed -E 's/[[:space:]]+$//; /^$/d')"
  hits="$(awk -v cfg="${RADIO_CFG}" '
    { line[NR] = $0 }
    /(^|[^A-Za-z0-9_])mesh_jni([^A-Za-z0-9_]|$)/ { jni++; j = NR }
    /(^|[^A-Za-z0-9_])mesh_radio([^A-Za-z0-9_]|$)/ { radio++; r = NR }
    /(^|[^A-Za-z0-9_])log_lever([^A-Za-z0-9_]|$)/ { lever++; l = NR }
    END {
      if (jni != 1 || radio != 1 || lever != 1) { print "it names mesh_jni " jni + 0 " time(s), mesh_radio " radio + 0 " and log_lever " lever + 0; exit }
      if (line[j] != "mod mesh_jni;" || line[j - 1] != "#[allow(unsafe_code)]" || line[j - 2] != cfg || line[j - 3] !~ /[;}]$/) { print "above and at mesh_jni: " line[j - 3] " | " line[j - 2] " | " line[j - 1] " | " line[j]; exit }
      if (line[r] != "mod mesh_radio;" || line[r - 1] != cfg || line[r - 2] !~ /[;}]$/) { print "above and at mesh_radio: " line[r - 2] " | " line[r - 1] " | " line[r]; exit }
      if (line[l] != "mod log_lever;" || line[l - 1] != "#[allow(unsafe_code)]" || line[l - 2] != cfg || line[l - 3] !~ /[;}]$/) { print "above and at log_lever: " line[l - 3] " | " line[l - 2] " | " line[l - 1] " | " line[l]; exit }
    }' <<<"${view}")"
  if [[ -n "${hits}" ]]; then
    fail "${LIB} does not declare the radio's three modules as pinned — '${RADIO_CFG}' and '#[allow(unsafe_code)]' above 'mod mesh_jni;' and above 'mod log_lever;', '${RADIO_CFG}' above 'mod mesh_radio;', each after the end of another item, and none of the names anywhere else in the file (${hits}). Under another condition, a body, a second declaration, an import under the same name or a macro, what an Android build compiles as one of them need not be ${SRC}/<name>.rs, which is the file read here."
  fi

  # Check 7: the radio's Kotlin writes no log line and holds no UUID.
  kotlin="$(find "${REPO_ROOT}/${APP_SRC}" -type f -name '*.kt' -path '*/mesh/*' | LC_ALL=C sort)"
  jvm="$(find "${REPO_ROOT}/${JVM_TESTS}" -type f -name '*.kt' | LC_ALL=C sort)"
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    view="$(code_view "${file}")"
    hits="$(grep -nE "${B}(Log|Timber)[[:space:]]*(\\.|::)|${B}(println|print|printStackTrace)[[:space:]]*\\(|System[[:space:]]*\\.[[:space:]]*(out|err)${E}|${B}(Logger|logging)${E}|^[[:space:]]*import[[:space:]]+(android\\.util\\.Log|timber\\.|java\\.util\\.logging)${E}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} writes a log line, names a logger or a standard stream, or imports one — under whatever name (line(s) ${hits}). The radio's Kotlin logs nothing, in any build (Security Rule 15): what it could say is a Bluetooth address, or a throwable that renders one."
    fi
  done <<<"${kotlin}"
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    rel="${file#"${REPO_ROOT}/"}"
    hits="$(grep -nE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "${file}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} holds a UUID in its canonical form (line(s) ${hits}). The service's and the characteristic's are kept as two Long constants each and built at run time: a canonical one in a tracked file fails check_no_committed_secrets.sh."
    fi
  done <<<"${kotlin}"$'\n'"${jvm}"

  # Check 8: the platform's radio modes are named, and the radio's UUIDs
  # built, at one site.
  if [[ "$(grep -oE "${B}${MODES}" "${REPO_ROOT}/${CONSTANTS}" | grep -oE '(SCAN_MODE|ADVERTISE_MODE|ADVERTISE_TX_POWER|CONNECTION_PRIORITY)' | LC_ALL=C sort -u | tr '\n' ' ' || true)" != 'ADVERTISE_MODE ADVERTISE_TX_POWER CONNECTION_PRIORITY SCAN_MODE ' ]]; then
    fail "${CONSTANTS} does not name the scan mode, the advertise mode, the advertise power and the connection priority it holds — each the Android constant whose integer it is. It is the one site of the radio's modes (T-PWR-1)."
  fi
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    [[ "${rel}" == "${CONSTANTS}" ]] && continue
    view="$(code_view "${file}")"
    hits="$(grep -nE "${B}${MODES}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names a scan, advertise or connection-priority constant of the platform (line(s) ${hits}). An adapter passes on the value ${CONSTANTS##*/} holds: a mode chosen anywhere else is one the power table does not have."
    fi
    hits="$(grep -nE "${B}UUID[[:space:]]*(\\(|\\.|::)|${B}ParcelUuid[[:space:]]*(\\.|::)[[:space:]]*fromString${E}|${B}UUID[[:space:]]+as${E}" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} builds a UUID, or takes the class under another name (line(s) ${hits}). The service's, the characteristic's and the descriptor's are the three ${CONSTANTS##*/} builds from its six numbers, which a JVM test holds: one made anywhere else is a service no other phone looks for, under a number nobody pinned."
    fi
  done <<<"${kotlin}"

  # Check 9: no log call of the radio's is allowlisted.
  hits="$(grep -nE '^[^#|]*/mesh/[^|]*\|' "${REPO_ROOT}/${LOG_ALLOWLIST}" | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${LOG_ALLOWLIST} has a row for a file of the mesh (line(s) ${hits}). check_native_log_allowlist.sh passes a call that has a row; the radio has none to list."
  fi

  # Check 10: a build with the flag off declares nothing of the mesh.
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    [[ "${rel}" == "${APP_SRC}/mesh/AndroidManifest.xml" ]] && continue
    hits="$(grep -niE 'bluetooth|connectedDevice|mesh' "${file}" | cut -d: -f1 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names Bluetooth, the connectedDevice service type or the mesh (line(s) ${hits}; a comment counts). Every permission and component of the mesh is in ${APP_SRC}/mesh/AndroidManifest.xml, merged only into a build with HAVEN_MESH: a release with the flag off asks for nothing new."
    fi
  done < <(find "${REPO_ROOT}/${APP_SRC}" -type f -name 'AndroidManifest.xml' | LC_ALL=C sort)

  # Check 11: the JVM tests are the pinned ones, and none is switched off.
  view="$(while IFS= read -r file; do [[ -n "${file}" ]] && code_view "${file}"; done <<<"${jvm}")"
  found="$(grep -A1 -E '^[[:space:]]*@Test[[:space:]]*$' <<<"${view}" | sed -nE 's/^[[:space:]]*fun ([A-Za-z0-9_]+)\(\).*/\1/p' | LC_ALL=C sort)"
  if [[ "${found}" != "$(printf '%s\n' "${JVM_TEST_NAMES[@]}" | LC_ALL=C sort)" ]]; then
    names="$(diff <(printf '%s\n' "${JVM_TEST_NAMES[@]}" | LC_ALL=C sort) <(printf '%s\n' "${found}") | grep -E '^[<>]' | tr '\n' ';' || true)"
    fail "the tests of ${JVM_TESTS} — each '@Test' directly above 'fun <name>()' — are not the pinned ones ('<' pinned, '>' found: ${names}). A test that is gone or renamed fails nothing; change JVM_TEST_NAMES in the same change, where a reviewer sees it."
  fi
  hits="$(grep -cE "${B}(Ignore|Disabled|Assume|assumeTrue|assumeFalse|assumeThat)${E}" <<<"${view}" || true)"
  if [[ "${hits}" != 0 ]]; then
    fail "a test of ${JVM_TESTS} is ignored, or assumes its way out (${hits} line(s)). A skipped test reports a proof it did not make."
  fi

  # Check 12: the floor under which an unknown address gets no number is the
  # engine's. Read: the first `rssi_floor: <integer>,` after the line
  # `impl Default for Config {` of the engine, and `const val RSSI_FLOOR =
  # <integer>` of the constants, each in the file's code.
  view="$(code_view "${REPO_ROOT}/${ENGINE}")"
  floor="$(awk '/^impl Default for Config \{/ { on = 1 } on && match($0, /rssi_floor:[[:space:]]*-?[0-9]+,/) { v = substr($0, RSTART, RLENGTH); gsub(/[^-0-9]/, "", v); print v; exit }' <<<"${view}")"
  view="$(code_view "${REPO_ROOT}/${CONSTANTS}")"
  found="$(sed -nE 's/^[[:space:]]*const val RSSI_FLOOR = (-?[0-9]+)[[:space:]]*$/\1/p' <<<"${view}" | tr '\n' ' ')"
  if [[ -z "${floor}" || "${found}" != "${floor} " ]]; then
    fail "${CONSTANTS} holds RSSI_FLOOR '${found% }' and the default of ${ENGINE} is rssi_floor '${floor}'. They are one number: below it the engine takes in no peer it does not know, and the radio gives such an address no number. Move both, or neither."
  fi

  # Check 13: the log lever's file, which the deny does not cover either.
  # `unsafe` and `extern` are counted in the whole file, its tests too; the
  # rest is read up to the tests.
  lever="$(code_view "${REPO_ROOT}/${LEVER}")"
  hits="$(awk -v pin="${LEVER_UNSAFE_BLOCKS}" '
    {
      line = $0
      if (line ~ /^type [A-Za-z0-9_]+ = unsafe extern "C" fn\(/) sub(/^type [A-Za-z0-9_]+ = unsafe extern "C" fn\(/, "", line)
      else if (line == "extern \"C\" fn logger(message: *const Message) {") { loggers++; line = "" }
      blocks += gsub(/(^|[^A-Za-z0-9_])unsafe \{/, " ", line)
      if (line ~ /(^|[^A-Za-z0-9_])(unsafe|extern)([^A-Za-z0-9_]|$)/) other = other NR " "
    }
    END { if (blocks != pin || loggers != 1 || other != "") printf "%d unsafe block(s), %d logger(s), other line(s): %s", blocks, loggers, (other == "" ? "none" : other) }' <<<"${lever}")"
  if [[ -n "${hits}" ]]; then
    fail "${LEVER} writes unsafe or extern otherwise than as its ${LEVER_UNSAFE_BLOCKS} unsafe blocks, its function-pointer types — 'type <Name> = unsafe extern \"C\" fn(…' — and the one logger 'extern \"C\" fn logger(message: *const Message) {' (found: ${hits}). No unsafe fn, no unsafe impl, no extern block and no second function liblog could call; a new unsafe block is a new argument a reviewer has to read, so the count moves here, in the same change."
  fi
  tests="$(tests_at <<<"${lever}")"
  hits="$(beyond_tests "${tests}" <<<"${lever}")"
  if [[ -n "${hits}" ]]; then
    fail "${LEVER} has a cfg(test) that is not the one '#[cfg(test)]' directly above 'mod tests {', or something after that module (line(s) ${hits}). This guard reads the lever up to its tests: code under another cfg(test), or behind the tests, is code it has not read."
  fi
  shipped="${lever}"
  if (( tests > 0 )); then
    shipped="$(sed -n "1,$(( tests - 1 ))p" <<<"${lever}")"
  fi
  view="$(code_view "${REPO_ROOT}/${LEVER}" blank)"
  if (( tests > 0 )); then
    view="$(sed -n "1,$(( tests - 1 ))p" <<<"${view}")"
  fi
  hits="$(grep -nE "${B}(no_mangle|export_name|link_section|used|thread_local|impl|mod|macro_rules|JNIEnv|Box|Vec|String|Mutex|RwLock|Arc|Rc|HashMap|BTreeMap|LazyLock|to_vec|from_ptr)${E}|${B}static[[:space:]]+mut${E}|radio_|${B}log::|unwrap|expect[[:space:]]*\(" <<<"${view}" | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -n "${hits}" ]]; then
    fail "${LEVER} names what the lever has no use for (line(s) ${hits}): an attribute that exports or keeps a symbol, static mut or thread_local, an impl, a module or a macro of its own, JNIEnv, a radio entry, the log crate, unwrap or expect, Box, Vec, String, Mutex, RwLock, Arc, Rc, a map, LazyLock, to_vec or from_ptr. Its logger runs inside the platform's log call, on whichever thread logs: it must not log, lock, allocate or panic, and the file exports nothing."
  fi
  hits="$(grep -oE "[A-Za-z_][A-Za-z0-9_]*![[:space:]]*[([{]" <<<"${view}" | sed -E 's/!.*$//' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
  if [[ "${hits}" != 'assert cfg matches offset_of ' \
    || "$(grep -c 'assert!' <<<"${shipped}" || true)" != 1 \
    || "$(grep -cE '^const _: \(\) = assert!\(matches!\($' <<<"${shipped}" || true)" != 1 ]]; then
    fail "${LEVER} invokes a macro that is not cfg!, or the one compile-time 'const _: () = assert!(matches!(' of the struct's layout with its offset_of! (found: ${hits:-none}). A macro that formats, panics or asserts at run time has no place in code liblog calls, and one from another crate writes what this guard does not read."
  fi
  hits="$(grep -oE '"[^"]*"' <<<"${shipped}" | LC_ALL=C sort -u | tr '\n' ' ' || true)"
  want="$(printf '"%s"\n' C android "${LEVER_STRINGS[@]}" | LC_ALL=C sort -u | tr '\n' ' ')"
  if [[ "${hits}" != "${want}" ]]; then
    fail "${LEVER} holds a string that is not the library's name, one of the five functions', the ABI of a pointer type or the target of its one cfg! — or lacks one of them (found: ${hits:-none}). It looks up five names in one library and writes no text: any other string is a tag, a message or a symbol nobody reviewed."
  fi
  hits="$(grep -oE "${B}libc::[A-Za-z0-9_]+" <<<"${view}" | sed -E 's/^[^l]*//' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
  if [[ "${hits}" != 'libc::RTLD_NOW libc::dlopen libc::dlsym ' \
    || "$(grep -oE "${B}libc${E}" <<<"${view}" | wc -l | tr -d ' ' || true)" != "$(grep -oE "${B}libc::[A-Za-z0-9_]+" <<<"${view}" | wc -l | tr -d ' ' || true)" ]]; then
    fail "${LEVER} names of libc something other than dlopen, dlsym and RTLD_NOW, each by its path (found: ${hits:-none}). The lookup is all the lever asks of libc; under an import, or with another function, what it calls is not what was reviewed."
  fi
  hits="$(tr -d '[:space:]' <<<"${shipped}" | grep -oE 'usecrate::api::\{[^}]*\};' | sed -E 's/^usecrate::api::\{//; s/\};$//' | tr ',' '\n' | grep -vE '^(lever_[a-z0-9_]+|LEVER_[A-Z0-9_]+)?$' | tr '\n' ' ' || true)"
  if [[ -n "${hits}" || "$(grep -oE "${B}(crate|super)[[:space:]]*::" <<<"${shipped}" | wc -l | tr -d ' ' || true)" != 1 \
    || "$(grep -cE '^use crate::api::\{' <<<"${shipped}" || true)" != 1 ]]; then
    fail "${LEVER} reaches something of the bridge that is not one of the lever's decisions — it names the crate once, in one 'use crate::api::{…};' of lever_* and LEVER_* names (other names: ${hits:-none}). Its logger runs inside the platform's log call: an engine's lock, a session or a log line reached from there is a deadlock or a line of Haven's own."
  fi
  while IFS= read -r file; do
    rel="${file#"${REPO_ROOT}/"}"
    view="$(code_view "${file}")"
    hits="$(grep -nE "android_log_sys$([[ "${rel}" == "${LEVER}" ]] || printf '|__android_log_(%s)' "$(printf '%s\n' "${LEVER_STRINGS[@]:1}" | sed 's/^__android_log_//' | paste -sd '|' -)")" <<<"${view}" | cut -d: -f1 | head -n 5 | tr '\n' ' ' || true)"
    if [[ -n "${hits}" ]]; then
      fail "${rel} names android_log_sys, or — outside ${LEVER} — one of liblog's five API-30 functions (line(s) ${hits}; a string counts). Declared or imported, such a function is a symbol the linker of Android 6 to 10 cannot bind, and the library — all of Haven — would not load there: the lever finds them with dlsym, in its own file."
    fi
  done < <(find "${REPO_ROOT}/${SRC}" -type f -name '*.rs' | LC_ALL=C sort)

  if (( FAILED )); then
    exit 1
  fi
  log "OK: unsafe is written in the generated bridge, the exports' file and the log lever alone, under the crate's deny; the exports' file is uses and the $(grep -c . <<<"${pinned}") pinned exports, each one call into ${CALLS##*/}; each of those is one guarded call of its radio entry, and calls nothing of Java's; the lever is its ${LEVER_UNSAFE_BLOCKS} unsafe blocks and one logger, looks up five functions by name and names nothing it could log, lock or panic with. The radio's Kotlin logs nothing and holds no UUID written out, names its modes and builds its UUIDs at one site, takes the engine's signal floor, and has its ${#JVM_TEST_NAMES[@]} JVM tests; no manifest outside the mesh's own names Bluetooth."
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
#[cfg(any(target_os = "android", test))]
mod mesh_radio;
// A lookup and a C callback are unsafe.
#[cfg(any(target_os = "android", test))]
#[allow(unsafe_code)]
mod log_lever;

#[cfg(debug_assertions)]
mod test_keyring;

#[allow(unsafe_code)]
mod frb_generated;
pub use frb_generated::*;
RS
    cat >"${t}/${SRC}/api.rs" <<'RS'
// Never unsafe here, no #[no_mangle], no #[export_name] and no extern "C",
// and __android_log_set_logger is looked up in log_lever.rs, not declared.
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
    matches!(word, "pub" | "unsafe" | "extern") || word == "wss://relay.example unsafe"
}
fn header(name: &str) -> String {
    format!("pub extern \"system\" fn Java_{name}(")
}
fn openers(word: &str, path: &str) -> bool {
    let mut path = if word == "//" { "/*" } else { path }; // unsafe
    path = path.trim();
    word.contains('"') || word == r#"an "unsafe" // word"# || path == "a
        // no_mangle \" extern */" /* nested /* unsafe */ extern */
}
fn quotes<'a>(word: &'a str, byte: u8) -> &'a str {
    let odd = byte == b'"' || byte == b'\'' || word.contains('\\') || word.contains('\u{2f}') || word.contains('é');
    'scan: loop {
        if odd || stringify!('x'"'") == include_str!("api.rs") { break 'scan word; } // " /* unsafe
    }
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
//! The exports. No unsafe block, no static, no mod, no macro!() here.

use jni::objects::{JByteArray, JLongArray, JObject};
use jni::sys::{jbyteArray, jlong};
use jni::JNIEnv;

use crate::mesh_radio;

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    mesh_radio::left_ms()
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_receive(
    env: JNIEnv,
    _this: JObject,
    link: jlong,
    frame: JByteArray,
) {
    mesh_radio::receive(&env, link, &frame);
}

#[no_mangle]
pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_poll(env: JNIEnv, _this: JObject, ready: JLongArray) -> jbyteArray {
    mesh_radio::poll(
        &env,
        &ready,
    )
}
RS
    cat >"${t}/${CALLS}" <<'RS'
//! What the exports forward to. No static, no JavaVM: env.new_global_ref( is
//! never called.
use jni::objects::{JByteArray, JLongArray};
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

pub(crate) fn left_ms() -> jlong {
    millis_out(radio_guarded(0, radio_left_ms))
}

pub(crate) fn receive(env: &JNIEnv, link: jlong, frame: &JByteArray) {
    let read = env
        .get_array_length(frame)
        .and_then(|_| env.convert_byte_array(frame));
    let Some(frame) = settled(env, read) else {
        return;
    };
    let link = link.cast_unsigned();
    radio_guarded((), || radio_receive(link, &frame));
}

pub(crate) fn poll(env: &JNIEnv, ready: &JLongArray) -> jbyteArray {
    let mut links = [0; 1];
    if settled(env, env.get_long_array_region(ready, 0, &mut links)).is_none() {
        return std::ptr::null_mut();
    }
    let links = links.map(jlong::cast_unsigned);
    let output = radio_guarded(None, || radio_poll(&links));
    output
        .and_then(|output| settled(env, env.byte_array_from_slice(&output)))
        .map_or(std::ptr::null_mut(), JByteArray::into_raw)
}

#[cfg(test)]
mod tests {
    static CALLS: u8 = 0;
    fn reads() {
        let _ = super::radio_left_ms();
    }
}
RS
    cat >"${t}/${LEVER}" <<'RS'
//! The lever. No unsafe fn, no println!("a line"), no Vec and no static mut
//! here: none of it is code.

use std::ffi::{c_char, c_void, CStr};
use std::mem::{offset_of, transmute};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::OnceLock;

use crate::api::{lever_held, lever_line, lever_writes_own, LEVER_FLOOR, LEVER_TAG_READ};

const WRITES_OWN: bool = lever_writes_own(cfg!(debug_assertions));

#[repr(C)]
struct Message {
    struct_size: usize,
    priority: i32,
    tag: *const c_char,
    message: *const c_char,
}

const _: () = assert!(matches!(
    (size_of::<usize>(), offset_of!(Message, tag)),
    (8, 16) | (4, 8)
));

type Logger = unsafe extern "C" fn(*const Message);
type SetLogger = unsafe extern "C" fn(Logger);
type Write = unsafe extern "C" fn(*mut Message);
type SetFloor = unsafe extern "C" fn(i32) -> i32;
type Floor = unsafe extern "C" fn() -> i32;

struct Liblog {
    set_logger: SetLogger,
    logd_logger: Logger,
    write_log_message: Write,
    set_minimum_priority: SetFloor,
    get_minimum_priority: Floor,
}

static LIBLOG: OnceLock<Option<Liblog>> = OnceLock::new();
static LINES: AtomicU32 = AtomicU32::new(0);

fn lookup(library: &CStr) -> Option<Liblog> {
    // SAFETY: an unsafe { block } in a comment is not counted.
    let handle = unsafe { libc::dlopen(library.as_ptr(), libc::RTLD_NOW) };
    if handle.is_null() {
        return None;
    }
    let find = |name: &CStr| {
        // SAFETY: the handle is never closed.
        let found = unsafe { libc::dlsym(handle, name.as_ptr()) };
        (!found.is_null()).then_some(found)
    };
    let set_logger = find(c"__android_log_set_logger")?;
    let logd_logger = find(c"__android_log_logd_logger")?;
    let write_log_message = find(c"__android_log_write_log_message")?;
    let set_minimum_priority = find(c"__android_log_set_minimum_priority")?;
    let get_minimum_priority = find(c"__android_log_get_minimum_priority")?;
    // SAFETY: none is null.
    Some(unsafe {
        Liblog {
            set_logger: transmute::<*mut c_void, SetLogger>(set_logger),
            logd_logger: transmute::<*mut c_void, Logger>(logd_logger),
            write_log_message: transmute::<*mut c_void, Write>(write_log_message),
            set_minimum_priority: transmute::<*mut c_void, SetFloor>(set_minimum_priority),
            get_minimum_priority: transmute::<*mut c_void, Floor>(get_minimum_priority),
        }
    })
}

fn tag_start(message: *const Message) -> Option<[u8; LEVER_TAG_READ]> {
    // SAFETY: the size is the first field.
    let size = unsafe { (*message).struct_size };
    if size < size_of::<Message>() {
        return None;
    }
    // SAFETY: the field is inside the message.
    let mut next = unsafe { (*message).tag }.cast::<u8>();
    if next.is_null() {
        return None;
    }
    let mut start = [0; LEVER_TAG_READ];
    for byte in &mut start {
        // SAFETY: never past the NUL.
        *byte = unsafe { next.read() };
        if *byte == 0 {
            break;
        }
        next = next.wrapping_add(1);
    }
    Some(start)
}

extern "C" fn logger(message: *const Message) {
    if !lever_line(WRITES_OWN, &LINES, || tag_start(message)) {
        return;
    }
    if let Some(liblog) = LIBLOG.get().and_then(Option::as_ref) {
        // SAFETY: handed on as it came.
        unsafe { (liblog.logd_logger)(message) };
    }
}

pub(crate) fn install() -> bool {
    let found = LIBLOG.get_or_init(|| {
        if cfg!(target_os = "android") {
            lookup(c"liblog.so")
        } else {
            None
        }
    });
    let Some(liblog) = found else {
        return false;
    };
    // SAFETY: the logger cannot unwind.
    unsafe { (liblog.set_logger)(logger) };
    if !WRITES_OWN {
        // SAFETY: a plain integer.
        unsafe { (liblog.set_minimum_priority)(LEVER_FLOOR) };
    }
    true
}

pub(crate) fn holds() -> bool {
    let Some(liblog) = LIBLOG.get().and_then(Option::as_ref) else {
        return false;
    };
    let empty: [c_char; 1] = [0];
    let mut sentinel = Message {
        struct_size: size_of::<Message>(),
        priority: 6,
        tag: empty.as_ptr(),
        message: empty.as_ptr(),
    };
    let before = LINES.load(Ordering::Relaxed);
    // SAFETY: a whole message.
    unsafe { (liblog.write_log_message)(&raw mut sentinel) };
    // SAFETY: a plain integer.
    let floor = unsafe { (liblog.get_minimum_priority)() };
    lever_held(WRITES_OWN, before, LINES.load(Ordering::Relaxed), floor)
}

#[cfg(test)]
mod tests {
    use super::{lookup, tag_start, Message};

    #[test]
    fn a_library_that_is_absent_is_no_lever() {
        let tags: Vec<String> = vec![format!("{}", "flutter")];
        assert!(lookup(c"libhaven-no-such-library.so").is_none() && tags.len() == 1);
    }
}
RS
    cat >"${t}/${EXPORTS}" <<'TXT'
# <name> <JNI descriptor> <Rust parameter types> <Rust return type>

leftMs ()J - jlong
receive (J[B)V jlong,JByteArray -
poll ([J)[B JLongArray jbyteArray
TXT
    local name
    mkdir -p "${t}/${CORE}" "${t}/${JVM_TESTS}/kotlin" "${t}/${APP_SRC}/debug" "${t}/${APP_SRC}/mesh" "${t}/scripts/ci"
    cat >"${t}/${CONSTANTS}" <<'KT'
package com.oblivioustech.haven.mesh.core

object MeshRadioConstants {
    /** `ScanSettings.SCAN_MODE_LOW_POWER`. */
    const val SCAN_MODE = 0

    /** `AdvertiseSettings.ADVERTISE_MODE_LOW_POWER`. */
    const val ADVERTISE_MODE = 0

    /** `AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM`. */
    const val ADVERTISE_TX_POWER = 2

    /** `BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER`. */
    const val CONNECTION_PRIORITY = 2

    // Not const val RSSI_FLOOR = -1
    const val RSSI_FLOOR = -85
}
KT
    cat >"${t}/${CORE%/core}/ScannerAdapter.kt" <<'KT'
package com.oblivioustech.haven.mesh

import com.oblivioustech.haven.mesh.core.MeshRadioConstants

// Never Log.d(TAG, …), println(…) or printStackTrace() here, and the mode is
// not SCAN_MODE_LOW_LATENCY.
class ScannerAdapter {
    fun mode(): Int = MeshRadioConstants.SCAN_MODE /* not System.err */

    fun blueprint(catalog: Int): Int = catalog + MeshRadioConstants.ADVERTISE_TX_POWER

    // Never UUID.fromString(…) here: the filter is the one the constants built.
    fun filter(found: java.util.UUID): Boolean = ParcelUuid(MeshRadioConstants.SERVICE_UUID).uuid == found
}
KT
    {
      printf 'class RadioTest {\n'
      for name in "${JVM_TEST_NAMES[@]}"; do
        printf '    @Test\n    fun %s() {\n        // Never @Ignore.\n    }\n\n' "${name}"
      done
      printf '    private fun helper() {}\n}\n'
    } >"${t}/${JVM_TESTS}/kotlin/RadioTest.kt"
    printf '<manifest>\n    <uses-permission android:name="android.permission.INTERNET"/>\n</manifest>\n' \
      | tee "${t}/${APP_SRC}/main/AndroidManifest.xml" >"${t}/${APP_SRC}/debug/AndroidManifest.xml"
    cat >"${t}/${APP_SRC}/mesh/AndroidManifest.xml" <<'XML'
<manifest>
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
    <application>
        <service android:name=".mesh.MeshService" android:foregroundServiceType="connectedDevice" android:exported="false"/>
    </application>
</manifest>
XML
    mkdir -p "${t}/${ENGINE%/*}"
    cat >"${t}/${ENGINE}" <<'RS'
pub struct Config {
    pub rssi_floor: i8,
}

// rssi_floor: -1,
impl Default for Config {
    fn default() -> Self {
        Self {
            max_incoming: 4,
            rssi_floor: -85,
        }
    }
}

#[cfg(test)]
mod tests {
    fn near() -> super::Config {
        super::Config { max_incoming: 4, rssi_floor: -40, }
    }
}
RS
    cat >"${t}/${LOG_ALLOWLIST}" <<'TXT'
# <repo-relative path>|<first line of the call, trimmed>|<why it is safe>|<owner>
# haven/android/app/src/main/kotlin/com/oblivioustech/haven/mesh/MeshService.kt|a row in a comment is no row|-|-
haven/android/app/src/main/kotlin/com/oblivioustech/haven/HavenApplication.kt|Log.i(TAG, "started")|a fixed word|owner
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
  # Puts <text> — `\n` a line break — before the tests module of <file>.
  _before_tests() { # <file> <text>
    awk -v text="$2" '$0 == "#[cfg(test)]" { print text; print "" } { print }' "$1" >"$1.new"
    mv "$1.new" "$1"
  }

  echo "check_mesh_radio.sh --self-test"
  local t="${tmp}/ok"; _tree "${t}"
  _case "the tree shape passes: three exports each one forward, comments and strings that only mention what is banned, a static in the calls' tests, a Vec and a format! in the lever's; an adapter and a mesh manifest beside the pure package" 0 '' "${t}"

  # Check 1: where unsafe, extern and an exported symbol are written.
  t="${tmp}/unsafe-block"; _tree "${t}"
  printf 'fn read(ptr: *const u8) -> u8 { unsafe { *ptr } }\n' >>"${t}/${SRC}/api.rs"
  _case "an unsafe block in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/unsafe-fn"; _tree "${t}"
  printf 'pub unsafe fn install() {}\n' >"${t}/${SRC}/test_keyring.rs"
  _case "an unsafe fn in the test keyring fails" 1 "${SRC}/test_keyring.rs writes unsafe" "${t}"

  t="${tmp}/unsafe-impl"; _tree "${t}"
  printf 'struct Raw(*mut u8);\nunsafe impl Send for Raw {}\n' >"${t}/${SRC}/raw.rs"
  _case "an unsafe impl in a new file fails" 1 "${SRC}/raw.rs writes unsafe" "${t}"

  t="${tmp}/unsafe-in-calls"; _tree "${t}"
  _line "${t}/${CALLS}" 'jlong::try_from(ms).unwrap_or(jlong::MAX)' '    unsafe { i64::try_from(ms).unwrap_unchecked() }'
  _case "an unsafe block in what the exports forward to fails" 1 "${CALLS} writes unsafe" "${t}"

  t="${tmp}/unsafe-behind-tests"; _tree "${t}"
  printf '\npub fn hidden() -> u8 {\n    unsafe { core::ptr::read(&1u8) }\n}\n' >>"${t}/${CALLS}"
  _case "an unsafe block behind the calls' tests fails check 1, which reads the whole file" 1 "${CALLS} writes unsafe" "${t}"

  t="${tmp}/no-mangle"; _tree "${t}"
  printf '#[no_mangle]\npub fn haven_probe() {}\n' >>"${t}/${SRC}/api.rs"
  _case "a no_mangle in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/unsafe-attribute"; _tree "${t}"
  printf '#[unsafe(no_mangle)]\npub fn haven_probe() {}\n' >"${t}/${SRC}/probe.rs"
  _case "the 2024 spelling of no_mangle in a new file fails" 1 "${SRC}/probe.rs writes unsafe" "${t}"

  t="${tmp}/export-name"; _tree "${t}"
  printf '#[export_name = "Java_com_oblivioustech_haven_mesh_MeshNative_extra"]\npub fn extra() {}\n' >>"${t}/${SRC}/api.rs"
  _case "an export_name in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/link-section"; _tree "${t}"
  printf '#[link_section = ".init_array"]\npub fn early() {}\n' >"${t}/${SRC}/early.rs"
  _case "a link_section in a new file fails" 1 "${SRC}/early.rs writes unsafe" "${t}"

  t="${tmp}/extern-fn"; _tree "${t}"
  printf 'pub extern "C" fn haven_probe() {}\n' >>"${t}/${SRC}/api.rs"
  _case "an extern fn in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/bare-extern"; _tree "${t}"
  printf 'pub extern fn haven_probe() {}\n' >>"${t}/${SRC}/api.rs"
  _case "an extern fn with no ABI string in api.rs fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/extern-block"; _tree "${t}"
  printf 'extern "C" {\n    fn getpid() -> i32;\n}\n' >"${t}/${SRC}/sys.rs"
  _case "an extern block in a new file fails" 1 "${SRC}/sys.rs writes unsafe" "${t}"

  t="${tmp}/export-elsewhere"; _tree "${t}"
  _before_tests "${t}/${CALLS}" '#[no_mangle]\npub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_reset(_env: JNIEnv, _this: jni::objects::JObject) {}'
  _case "an export of MeshNative in another file of the crate fails" 1 "${CALLS} writes unsafe" "${t}"

  # Checks 1 and 2 read past a string: a comment opener in one hides nothing
  # after it.
  t="${tmp}/string-slashes"; _tree "${t}"
  printf 'const _Z: &str = "//"; #[allow(unsafe_code)] #[no_mangle] pub extern "C" fn haven_probe() -> u8 { unsafe { *core::ptr::null::<u8>() } }\n' >>"${t}/${SRC}/api.rs"
  _case "the re-review's plant: an exported unsafe fn behind a \"//\" on its line fails check 1" 1 "${SRC}/api.rs writes unsafe" "${t}"
  _case "the same plant fails check 2: its allowance is read" 1 "${SRC}/api.rs names the unsafe_code lint" "${t}"

  t="${tmp}/string-block"; _tree "${t}"
  printf 'const _A: &str = "/*";\n#[no_mangle]\npub extern "C" fn haven_probe() {}\nconst _B: &str = "*/";\n' >>"${t}/${SRC}/api.rs"
  _case "an exported fn between a \"/*\" and a \"*/\" fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/string-two-lines"; _tree "${t}"
  printf 'const _A: &str = "\n//"; #[allow(unsafe_code)] #[no_mangle] pub fn haven_probe() {}\n' >>"${t}/${SRC}/api.rs"
  _case "an allowance behind the // that ends a string begun on the line above fails" 1 "${SRC}/api.rs names the unsafe_code lint" "${t}"

  t="${tmp}/string-raw"; _tree "${t}"
  printf 'const _A: &str = r#"" // "#; #[allow(unsafe_code)] #[no_mangle] pub fn haven_probe() {}\n' >>"${t}/${SRC}/api.rs"
  _case "an allowance behind a // inside a raw string that holds a quote fails" 1 "${SRC}/api.rs names the unsafe_code lint" "${t}"

  cat >"${tmp}/plant.rs" <<'RS'
const _: &str = stringify!('x'"'");
const _: &str = " /* ";
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn hidden_export(p: *const u8) -> u8 {
    unsafe { *p }
}
// */
RS
  t="${tmp}/char-then-string"; _tree "${t}"
  cat "${tmp}/plant.rs" >>"${t}/${SRC}/api.rs"
  _case "the second review's plant: an exported unsafe fn after a character literal that is followed by a string holding a quote fails" 1 "${SRC}/api.rs writes unsafe" "${t}"

  t="${tmp}/char-then-string-lib"; _tree "${t}"
  cat "${tmp}/plant.rs" >>"${t}/${LIB}"
  _case "the same plant in lib.rs fails: its allowance is counted" 1 'names unsafe_code otherwise' "${t}"

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
  sed -i '/^mod mesh_jni;$/d; s/^mod mesh_radio;$/mod mesh_radio;\nmod mesh_jni;/' "${t}/${LIB}"
  sed -i '0,/^#\[cfg(any(target_os = "android", test))\]$/{/^#\[cfg(any(target_os = "android", test))\]$/d}' "${t}/${LIB}"
  _case "the allowance left on what the exports forward to fails" 1 'names unsafe_code otherwise' "${t}"

  t="${tmp}/inner-allow"; _tree "${t}"
  sed -i '1s/^/#![allow(unsafe_code)]\n/' "${t}/${SRC}/api.rs"
  _case "an inner allowance in api.rs fails" 1 "${SRC}/api.rs names the unsafe_code lint" "${t}"

  t="${tmp}/item-allow"; _tree "${t}"
  _before_tests "${t}/${CALLS}" '#[allow(unsafe_code)]\nfn raw() {}'
  _case "an allowance on one item of what the exports forward to fails" 1 "${CALLS} names the unsafe_code lint" "${t}"

  # Check 3: the exports' file is uses and exports, each export one call.
  t="${tmp}/plant-export-name"; _tree "${t}"
  printf '\n#[export_name = "Java_com_oblivioustech_haven_mesh_MeshNative_extra"]\npub extern fn extra(env: JNIEnv, _this: JObject) {\n    let e = &env;\n    let _ = JNIEnv::exception_check(e);\n}\n' >>"${t}/${SHIM}"
  _case "the review's plant: a symbol exported by export_name from a bare extern fn that calls JNI by path fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/plant-hidden"; _tree "${t}"
  printf '\n#[cfg(test)]\nconst HIDE: u8 = 0;\n\npub fn hidden() -> u8 {\n    unsafe { core::ptr::read(&1u8) }\n}\n' >>"${t}/${SHIM}"
  _case "the review's plant: an early cfg(test) and unsafe code behind it fail" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/shim-tests"; _tree "${t}"
  printf '\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn nothing() {}\n}\n' >>"${t}/${SHIM}"
  _case "a tests module in the exports' file fails: every line of it is read" 1 'names unsafe, export_name, link_section, used, mod, impl, static, cfg' "${t}"

  t="${tmp}/unsafe-spelling"; _tree "${t}"
  sed -i '0,/^#\[no_mangle\]$/s//#[unsafe(no_mangle)]/' "${t}/${SHIM}"
  _case "an export under the 2024 spelling of no_mangle fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/c-abi"; _tree "${t}"
  sed -i 's/^pub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(/pub extern "C" fn Java_com_oblivioustech_haven_mesh_MeshNative_leftMs(/' "${t}/${SHIM}"
  _case "an export declared with another ABI fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/mangled"; _tree "${t}"
  sed -i '0,/^#\[no_mangle\]$/{/^#\[no_mangle\]$/d}' "${t}/${SHIM}"
  _case "an export without no_mangle fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/on-load"; _tree "${t}"
  printf '\n#[no_mangle]\npub extern "system" fn JNI_OnLoad(vm: *mut u8, _reserved: *mut u8) -> i32 {\n    0x0001_0006\n}\n' >>"${t}/${SHIM}"
  _case "a symbol exported from the shim that is no method of MeshNative fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/bare-extern-in-shim"; _tree "${t}"
  printf '\npub extern fn Java_com_oblivioustech_haven_mesh_MeshNative_extra(_env: JNIEnv, _this: JObject) {}\n' >>"${t}/${SHIM}"
  _case "an extern fn with no ABI string in the exports' file is counted" 1 'another number of extern keywords or of no_mangle' "${t}"

  t="${tmp}/helper"; _tree "${t}"
  printf '\nfn twice(ms: jlong) -> jlong {\n    ms.saturating_mul(2)\n}\n' >>"${t}/${SHIM}"
  _case "a function in the exports' file that is no export fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/shim-mod"; _tree "${t}"
  printf '\nmod raw {\n    pub fn read() {}\n}\n' >>"${t}/${SHIM}"
  _case "a module in the exports' file fails" 1 'names unsafe, export_name, link_section, used, mod, impl, static, cfg' "${t}"

  t="${tmp}/shim-impl"; _tree "${t}"
  printf '\nstruct Raw;\nimpl Drop for Raw {\n    fn drop(&mut self) {}\n}\n' >>"${t}/${SHIM}"
  _case "an impl in the exports' file fails" 1 'names unsafe, export_name, link_section, used, mod, impl, static, cfg' "${t}"

  t="${tmp}/shim-static"; _tree "${t}"
  printf '\n#[used]\nstatic KEEP: u8 = 0;\n' >>"${t}/${SHIM}"
  _case "a used static in the exports' file fails" 1 'names unsafe, export_name, link_section, used, mod, impl, static, cfg' "${t}"

  t="${tmp}/shim-link-section"; _tree "${t}"
  sed -i '0,/^#\[no_mangle\]$/s//#[link_section = ".text.hot"]\n#[no_mangle]/' "${t}/${SHIM}"
  _case "a link_section on an export fails" 1 'names unsafe, export_name, link_section, used, mod, impl, static, cfg' "${t}"

  t="${tmp}/shim-cfg"; _tree "${t}"
  sed -i '0,/^#\[no_mangle\]$/s//#[cfg(target_os = "android")]\n#[no_mangle]/' "${t}/${SHIM}"
  _case "a cfg on an export fails" 1 'names unsafe, export_name, link_section, used, mod, impl, static, cfg' "${t}"

  t="${tmp}/body-unsafe"; _tree "${t}"
  _line "${t}/${SHIM}" '    mesh_radio::left_ms()' '    unsafe { mesh_radio::left_ms() }'
  _case "an unsafe block round a forward fails" 1 'names unsafe, export_name, link_section, used, mod, impl, static, cfg' "${t}"

  t="${tmp}/body-macro"; _tree "${t}"
  _line "${t}/${SHIM}" '    mesh_radio::left_ms()' '    debug_assert!(true);\n    mesh_radio::left_ms()'
  _case "a macro invoked in an export fails" 1 'or invokes a macro' "${t}"

  t="${tmp}/body-jni-path"; _tree "${t}"
  _line "${t}/${SHIM}" '    mesh_radio::receive(&env, link, &frame);' '    let _ = JNIEnv::exception_check(&env);\n    mesh_radio::receive(&env, link, &frame);'
  _case "a JNI call made by path in an export fails" 1 'the export receive is not the one call mesh_radio::receive(&env,link,&frame)' "${t}"

  t="${tmp}/body-converts"; _tree "${t}"
  _line "${t}/${SHIM}" '    mesh_radio::receive(&env, link, &frame);' '    mesh_radio::receive(&env, link.wrapping_add(1), &frame);'
  _case "an export that changes an argument on the way fails" 1 'the export receive is not the one call' "${t}"

  t="${tmp}/body-swapped"; _tree "${t}"
  sed -i 's/^    frame: JByteArray,$/    peer: jlong,/' "${t}/${SHIM}"
  _line "${t}/${SHIM}" '    mesh_radio::receive(&env, link, &frame);' '    mesh_radio::receive(&env, peer, link);'
  _case "an export that hands two parameters on in each other's place fails" 1 'the export receive is not the one call mesh_radio::receive(&env,link,peer)' "${t}"

  t="${tmp}/body-other-call"; _tree "${t}"
  _line "${t}/${SHIM}" '    mesh_radio::left_ms()' '    mesh_radio::poll_now()'
  _case "an export that forwards to a function of another name fails" 1 'the export leftMs is not the one call mesh_radio::left_ms()' "${t}"

  t="${tmp}/body-bridge"; _tree "${t}"
  _line "${t}/${SHIM}" '    mesh_radio::left_ms()' '    jlong::try_from(crate::api::radio_left_ms()).unwrap_or(0)'
  _case "an export that calls a radio entry itself fails" 1 'the export leftMs is not the one call' "${t}"

  t="${tmp}/body-two"; _tree "${t}"
  _line "${t}/${SHIM}" '    mesh_radio::left_ms()' '    mesh_radio::receive_none();\n    mesh_radio::left_ms()'
  _case "an export of two calls fails" 1 'the export leftMs is not the one call' "${t}"

  t="${tmp}/env-unnamed"; _tree "${t}"
  sed -i 's/^    env: JNIEnv,$/    jni: JNIEnv,/' "${t}/${SHIM}"
  _line "${t}/${SHIM}" '    mesh_radio::receive(&env, link, &frame);' '    mesh_radio::receive(&jni, link, &frame);'
  _case "an export that names its environment otherwise fails" 1 '> ? receive' "${t}"

  t="${tmp}/use-then-items"; _tree "${t}"
  _line "${t}/${SHIM}" 'use jni::sys::{jbyteArray, jlong};' 'use jni::sys::{\n    jbyteArray, jlong,\n}; const _A: &str = "//"; #[no_mangle] pub extern "C" fn JNI_OnLoad(_vm: *mut u8, _r: *mut u8) -> i32 { unsafe { core::ptr::read_volatile(0x10 as *const i32) } }\nconst _B: () = {\n};'
  _case "the re-review's plant: an exported unsafe fn on the line that closes a use fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/use-then-block"; _tree "${t}"
  _line "${t}/${SHIM}" 'use jni::sys::{jbyteArray, jlong};' 'use jni::sys::{\n    jbyteArray, jlong,\n}; const _A: &str = "/*";\n#[no_mangle]\npub extern "C" fn JNI_OnLoad(_vm: *mut u8, _r: *mut u8) -> i32 {\n    unsafe { core::ptr::read_volatile(_vm.cast::<i32>()) }\n}\nconst _B: &str = "*/";\nconst _C: () = {\n};'
  _case "the re-review's plant: an exported fn between two strings that read as a comment fails, and its quotes are named" 1 'has a quote that is not the "system" of an export' "${t}"

  t="${tmp}/use-lines"; _tree "${t}"
  _line "${t}/${SHIM}" 'use jni::sys::{jbyteArray, jlong};' 'use jni::sys::{\n    jbyteArray, jlong,\n};'
  _case "a use over several lines fails: nothing in the file needs one, and its lines would be lines nobody reads" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/use-renames-calls"; _tree "${t}"
  _line "${t}/${SHIM}" 'use crate::mesh_radio;' 'use crate::api as mesh_radio;'
  _case "the re-review's plant: another module imported under the name of the calls' fails" 1 'does not import what its exports forward to' "${t}"

  t="${tmp}/use-other-calls"; _tree "${t}"
  _line "${t}/${SHIM}" 'use crate::mesh_radio;' 'use crate::test_keyring::mesh_radio;'
  _case "a module of the calls' name imported from elsewhere fails" 1 'does not import what its exports forward to' "${t}"

  t="${tmp}/use-renames"; _tree "${t}"
  _line "${t}/${SHIM}" 'use jni::JNIEnv;' 'use jni::JNIEnv;\nuse jni::sys::jint as JObject;'
  _case "a use that renames what it imports fails" 1 'holds something that is neither a use nor an export' "${t}"

  t="${tmp}/use-glob"; _tree "${t}"
  _line "${t}/${SHIM}" 'use jni::JNIEnv;' 'use jni::JNIEnv;\nuse crate::api::*;'
  _case "a glob import fails" 1 'holds something that is neither a use nor an export' "${t}"

  # Check 4: the exports are the pinned ones.
  t="${tmp}/tenth"; _tree "${t}"
  printf '\n#[no_mangle]\npub extern "system" fn Java_com_oblivioustech_haven_mesh_MeshNative_reset(\n    _env: JNIEnv,\n    _this: JObject,\n) -> jlong {\n    mesh_radio::reset()\n}\n' >>"${t}/${SHIM}"
  _before_tests "${t}/${CALLS}" 'pub(crate) fn reset() -> jlong {\n    0\n}'
  _case "an export the fixture does not list fails" 1 '> reset ()J - jlong' "${t}"

  t="${tmp}/missing"; _tree "${t}"
  printf 'wakeInMs ()J - jlong\n' >>"${t}/${EXPORTS}"
  _case "a pinned method the shim does not export fails" 1 '< wakeInMs ()J - jlong' "${t}"

  t="${tmp}/renamed"; _tree "${t}"
  sed -i 's/MeshNative_leftMs(/MeshNative_left(/' "${t}/${SHIM}"
  _line "${t}/${SHIM}" '    mesh_radio::left_ms()' '    mesh_radio::left()'
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
  _case "two parameters declared in the other order fail" 1 '> receive ([BJ)V JByteArray,jlong -' "${t}"

  t="${tmp}/no-receiver"; _tree "${t}"
  sed -i '0,/^    _this: JObject,$/{/^    _this: JObject,$/d}' "${t}/${SHIM}"
  _case "an export that takes no receiver fails" 1 '> ? leftMs' "${t}"

  t="${tmp}/unknown-type"; _tree "${t}"
  sed -i 's/^    link: jlong,$/    link: jshort,/' "${t}/${SHIM}"
  _case "a parameter of a type the descriptors have no letter for fails" 1 '> ? receive' "${t}"

  t="${tmp}/pinned-order"; _tree "${t}"
  printf 'poll ([J)[B JLongArray jbyteArray\nleftMs ()J - jlong\nreceive (J[B)V jlong,JByteArray -\n' >"${t}/${EXPORTS}"
  _case "the fixture's lines in another order are the same exports" 0 '' "${t}"

  # Check 5: what the exports forward to.
  t="${tmp}/bare"; _tree "${t}"
  _line "${t}/${CALLS}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_left_ms())'
  _case "a call that makes its entry bare fails" 1 'the call left_ms of' "${t}"

  t="${tmp}/before-guard"; _tree "${t}"
  _line "${t}/${CALLS}" 'radio_guarded((), || radio_receive(' '    let _ = radio_left_ms();\n    radio_guarded((), || radio_receive(link, &frame));'
  _case "an entry called before the guard fails" 1 'the call receive of' "${t}"

  t="${tmp}/two-under"; _tree "${t}"
  _line "${t}/${CALLS}" 'radio_guarded((), || radio_receive(' '    radio_guarded((), || { let _ = radio_left_ms(); radio_receive(link, &frame) });'
  _case "two entries under one guard fail" 1 'the call receive of' "${t}"

  t="${tmp}/two-guards"; _tree "${t}"
  _line "${t}/${CALLS}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_guarded(0, radio_left_ms) + radio_guarded(0, radio_left_ms))'
  _case "two guarded calls in one call fail" 1 'the call left_ms of' "${t}"

  t="${tmp}/beside"; _tree "${t}"
  _line "${t}/${CALLS}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_guarded(0, || { crate::api::mesh_stop(); radio_left_ms() }))'
  _case "something else called under the guard, beside the entry, fails" 1 'the call left_ms of' "${t}"

  t="${tmp}/converted-under"; _tree "${t}"
  _line "${t}/${CALLS}" 'radio_guarded((), || radio_receive(' '    radio_guarded((), || radio_receive(link.rotate_left(1), &frame));'
  _case "a call made under the guard, among the entry's arguments, fails" 1 'the call receive of' "${t}"

  t="${tmp}/not-an-entry"; _tree "${t}"
  _line "${t}/${CALLS}" 'millis_out(radio_guarded(0, radio_left_ms))' '    millis_out(radio_guarded(0, crate::api::mesh_empty))'
  _case "a call that makes something that is no radio entry fails" 1 'the call left_ms of' "${t}"

  t="${tmp}/other-entry"; _tree "${t}"
  _line "${t}/${CALLS}" 'radio_guarded((), || radio_receive(' '    radio_guarded((), || radio_poll(&[link]));'
  _case "a call that makes another call's entry fails" 1 'the call receive of' "${t}"

  t="${tmp}/helper-calls"; _tree "${t}"
  _line "${t}/${CALLS}" 'jlong::try_from(ms).unwrap_or(jlong::MAX)' '    jlong::try_from(ms.max(radio_left_ms())).unwrap_or(jlong::MAX)'
  _case "an entry called from a helper, outside every call, fails" 1 "names a radio entry outside the pinned methods' functions" "${t}"

  t="${tmp}/no-call"; _tree "${t}"
  sed -i 's/^pub(crate) fn left_ms() -> jlong {$/pub(crate) fn time_left() -> jlong {/' "${t}/${CALLS}"
  _case "a pinned method with no function of its name fails" 1 "does not declare 'pub(crate) fn left_ms(' exactly once" "${t}"

  t="${tmp}/global-ref"; _tree "${t}"
  _line "${t}/${CALLS}" 'let mut links = [0; 1];' '    let mut links = [0; 1];\n    let _ = env.new_global_ref(ready);'
  _case "a global reference made in the shim fails" 1 'calls new_global_ref on a JNIEnv' "${t}"

  t="${tmp}/callback"; _tree "${t}"
  sed -i 's/^    let read = env$/    let read = env\n        .call_method(frame, "size", "()I", \&[])\n        .and_then(|_| env.get_array_length(frame))\n        .map(drop);\n    let read = env/' "${t}/${CALLS}"
  _case "a call into Java, split over two lines, fails" 1 'calls call_method on a JNIEnv' "${t}"

  t="${tmp}/jni-path"; _tree "${t}"
  _line "${t}/${CALLS}" 'let mut links = [0; 1];' '    let mut links = [0; 1];\n    let _ = JNIEnv::exception_check(env);'
  _case "a JNI method called by its path fails" 1 'uses a JNIEnv otherwise' "${t}"

  t="${tmp}/aliased"; _tree "${t}"
  _line "${t}/${CALLS}" 'let mut links = [0; 1];' '    let mut links = [0; 1];\n    let e = env;\n    let _ = e.exception_check();'
  _case "a JNIEnv bound under a second name fails" 1 'uses a JNIEnv otherwise' "${t}"

  t="${tmp}/other-name"; _tree "${t}"
  sed -i 's/^fn settled<T>(env: &JNIEnv, /fn settled<T>(jni: \&JNIEnv, /; s/let _ = env.exception_clear();/let _ = jni.exception_clear();/' "${t}/${CALLS}"
  _case "a JNIEnv parameter under another name fails" 1 'uses a JNIEnv otherwise' "${t}"

  t="${tmp}/by-value"; _tree "${t}"
  sed -i 's/^fn settled<T>(env: &JNIEnv, /fn settled<T>(env: JNIEnv, /' "${t}/${CALLS}"
  _case "a JNIEnv taken by value fails" 1 'uses a JNIEnv otherwise' "${t}"

  t="${tmp}/vm"; _tree "${t}"
  _line "${t}/${CALLS}" 'use jni::JNIEnv;' 'use jni::JNIEnv;\nuse jni::JavaVM;'
  _case "a JavaVM named in the shim fails" 1 'names a JavaVM' "${t}"

  t="${tmp}/state"; _tree "${t}"
  sed -i 's/^fn millis_out(ms: u64) -> jlong {$/static LAST: std::sync::Mutex<u64> = std::sync::Mutex::new(0);\n\nfn millis_out(ms: u64) -> jlong {/' "${t}/${CALLS}"
  _case "state kept in the shim between calls fails" 1 'names a JavaVM' "${t}"

  t="${tmp}/early-cfg-test"; _tree "${t}"
  sed -i 's/^fn millis_out(ms: u64) -> jlong {$/#[cfg(test)]\nconst HIDE: u8 = 0;\n\nfn millis_out(ms: u64) -> jlong {/' "${t}/${CALLS}"
  _case "a cfg(test) ahead of the calls' tests fails" 1 'has a cfg(test) that is not the one' "${t}"

  t="${tmp}/cfg-any-test"; _tree "${t}"
  sed -i 's/^fn millis_out(ms: u64) -> jlong {$/#[cfg(any(test, debug_assertions))]\nfn probe() {}\n\nfn millis_out(ms: u64) -> jlong {/' "${t}/${CALLS}"
  _case "a cfg that only names test among others fails" 1 'has a cfg(test) that is not the one' "${t}"

  t="${tmp}/behind-tests"; _tree "${t}"
  printf '\npub(crate) fn hidden() -> u64 {\n    crate::api::radio_left_ms()\n}\n' >>"${t}/${CALLS}"
  _case "code behind the calls' tests fails" 1 'or something after that module' "${t}"

  t="${tmp}/tests-renamed"; _tree "${t}"
  sed -i 's/^mod tests {$/mod checks {/' "${t}/${CALLS}"
  _case "a cfg(test) module under another name is read as code that ships" 1 'has a cfg(test) that is not the one' "${t}"

  # Check 6: a module of the radio built from another file than the one read.
  t="${tmp}/path-exports"; _tree "${t}"
  sed -i 's/^mod mesh_jni;$/#[path = "..\/other_jni.rs"]\nmod mesh_jni;/' "${t}/${LIB}"
  _case "the re-review's plant: the allowed module built from another file fails" 1 "${LIB} gives something a path" "${t}"

  t="${tmp}/path-calls"; _tree "${t}"
  sed -i 's/^mod mesh_radio;$/#[path = "other_radio.rs"]\nmod mesh_radio;/' "${t}/${LIB}"
  _case "the calls' module built from another file fails" 1 "${LIB} gives something a path" "${t}"

  t="${tmp}/path-cfg-attr"; _tree "${t}"
  sed -i 's/^mod mesh_radio;$/#[cfg_attr(\n    all(),\n    path = r"other_radio.rs"\n)]\nmod mesh_radio;/' "${t}/${LIB}"
  _case "a path given under cfg_attr, over several lines, as a raw string, fails" 1 "${LIB} gives something a path" "${t}"

  t="${tmp}/path-inside"; _tree "${t}"
  printf '#[path = "elsewhere.rs"]\nmod more;\n' >>"${t}/${SRC}/api.rs"
  _case "a path attribute in another file of the crate fails" 1 "${SRC}/api.rs gives something a path" "${t}"

  t="${tmp}/calls-inline"; _tree "${t}"
  sed -i 's/^mod mesh_radio;$/mod mesh_radio {\n    pub(crate) fn left_ms() -> i64 {\n        0\n    }\n}/' "${t}/${LIB}"
  _case "the calls' module declared with a body, beside the file read here, fails" 1 "does not declare the radio's three modules as pinned" "${t}"

  t="${tmp}/calls-two-ways"; _tree "${t}"
  awk -v cfg='#[cfg(any(target_os = "android", test))]' '
    { held[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (held[i + 1] == "mod mesh_radio;" && held[i] == cfg) { print "#[cfg(test)]"; continue }
        print held[i]
        if (held[i] == "mod mesh_radio;") { print "#[cfg(all(target_os = \"android\", not(test)))]"; print "use api::radio_shim as mesh_radio;" }
      }
    }' "${t}/${LIB}" >"${t}/${LIB}.new" && mv "${t}/${LIB}.new" "${t}/${LIB}"
  _case "the second review's plant: the calls' file compiled for tests only, and another module under its name for Android, fails" 1 "does not declare the radio's three modules as pinned" "${t}"

  t="${tmp}/calls-by-macro"; _tree "${t}"
  awk -v cfg='#[cfg(any(target_os = "android", test))]' '
    { held[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (held[i + 1] == "mod mesh_radio;" && held[i] == cfg) { print "#[cfg(test)]"; continue }
        print held[i]
        if (held[i] == "mod mesh_radio;") {
          print "macro_rules! module { ($file:literal, $name:ident) => { #[path = $file] mod $name; } }"
          print "#[cfg(all(target_os = \"android\", not(test)))]"
          print "module!(\"radio_shipped.rs\", mesh_radio);"
        }
      }
    }' "${t}/${LIB}" >"${t}/${LIB}.new" && mv "${t}/${LIB}.new" "${t}/${LIB}"
  _case "the second review's plant: a path a macro writes, with no string after it, fails" 1 "${LIB} gives something a path" "${t}"

  t="${tmp}/calls-third-attribute"; _tree "${t}"
  sed -i 's/^pub mod api;$/pub mod api;\n#[cfg(not(feature = "radio"))]/' "${t}/${LIB}"
  _case "one more attribute above the pinned ones of a radio module fails" 1 "does not declare the radio's three modules as pinned" "${t}"

  t="${tmp}/included"; _tree "${t}"
  printf '#[allow(unsafe_code)]\n#[no_mangle]\npub extern "C" fn included_export(p: *const u8) -> u8 {\n    unsafe { *p }\n}\n' >"${t}/${SRC}/extra.in"
  printf '\ninclude!("extra.in");\n' >>"${t}/${LIB}"
  _case "the second review's plant: source included from a file that is no .rs fails" 1 "${LIB} includes a file as source" "${t}"

  # Check 7: the radio's Kotlin writes no log line and holds no UUID.
  local adapter="${CORE%/core}/ScannerAdapter.kt"
  t="${tmp}/kotlin-log"; _tree "${t}"
  _line "${t}/${adapter}" 'fun mode()' '    fun mode(): Int = MeshRadioConstants.SCAN_MODE.also { Log.d("Mesh", "scan from $device") }'
  _case "a Log call in an adapter of the radio fails" 1 "${adapter} writes a log line" "${t}"

  t="${tmp}/kotlin-println"; _tree "${t}"
  printf 'fun trace(address: String) = println(address)\n' >>"${t}/${CONSTANTS}"
  _case "a println in the pure package fails" 1 "${CONSTANTS} writes a log line" "${t}"

  t="${tmp}/kotlin-stack-trace"; _tree "${t}"
  _line "${t}/${adapter}" 'fun mode()' '    fun mode(): Int = try { MeshRadioConstants.SCAN_MODE } catch (e: Exception) { e.printStackTrace(); 0 }'
  _case "a caught throwable rendered by printStackTrace fails" 1 "${adapter} writes a log line" "${t}"

  t="${tmp}/kotlin-stderr"; _tree "${t}"
  mkdir -p "${t}/${APP_SRC}/debug/kotlin/com/oblivioustech/haven/mesh"
  printf 'package com.oblivioustech.haven.mesh\n\nfun note(link: Long) = System.err.write(link.toInt())\n' >"${t}/${APP_SRC}/debug/kotlin/com/oblivioustech/haven/mesh/LoopbackRadio.kt"
  _case "a standard stream written from a mesh file of another source set fails" 1 "LoopbackRadio.kt writes a log line" "${t}"

  # In two halves: whole, it would be a canonical UUID in this tracked file.
  local uuid='4f3c2a10-9b7e-4d1a''-8c55-0e6f7a8b9c0d'
  t="${tmp}/kotlin-log-alias"; _tree "${t}"
  sed -i 's/^import com.oblivioustech.haven.mesh.core.MeshRadioConstants$/import android.util.Log as L\nimport com.oblivioustech.haven.mesh.core.MeshRadioConstants/' "${t}/${adapter}"
  _line "${t}/${adapter}" 'fun mode()' '    fun mode(): Int = MeshRadioConstants.SCAN_MODE.also { L.w("mesh", "from $device") }'
  _case "the second review's plant: a logger imported under another name fails" 1 "${adapter} writes a log line" "${t}"

  t="${tmp}/kotlin-log-reference"; _tree "${t}"
  _line "${t}/${adapter}" 'fun mode()' '    fun mode(): Int = MeshRadioConstants.SCAN_MODE.also { listOf("a").forEach(Timber::w) }'
  _case "a log call taken as a function reference fails" 1 "${adapter} writes a log line" "${t}"

  t="${tmp}/kotlin-uuid"; _tree "${t}"
  printf '// The service is %s.\n' "${uuid}" >>"${t}/${adapter}"
  _case "a canonical UUID in the radio's Kotlin fails, in a comment too" 1 "${adapter} holds a UUID" "${t}"

  t="${tmp}/kotlin-test-uuid"; _tree "${t}"
  printf 'val service = java.util.UUID.fromString("%s")\n' "${uuid^^}" >>"${t}/${JVM_TESTS}/kotlin/RadioTest.kt"
  _case "a canonical UUID in a JVM test fails" 1 "RadioTest.kt holds a UUID" "${t}"

  # Check 8: the platform's radio modes are named at one site.
  t="${tmp}/mode-elsewhere"; _tree "${t}"
  _line "${t}/${adapter}" 'fun mode()' '    fun mode(): Int = ScanSettings.SCAN_MODE_LOW_LATENCY'
  _case "a scan mode named in an adapter fails" 1 "${adapter} names a scan, advertise or connection-priority constant" "${t}"

  t="${tmp}/priority-elsewhere"; _tree "${t}"
  _line "${t}/${adapter}" 'fun blueprint(' '    fun blueprint(catalog: Int): Int = catalog + BluetoothGatt.CONNECTION_PRIORITY_HIGH'
  _case "a connection priority named in an adapter fails" 1 "${adapter} names a scan, advertise or connection-priority constant" "${t}"

  t="${tmp}/uuid-parsed"; _tree "${t}"
  _line "${t}/${adapter}" 'fun filter(' '    fun filter(found: java.util.UUID): Boolean = java.util.UUID.fromString(NAME) == found'
  _case "a UUID parsed in an adapter fails" 1 "${adapter} builds a UUID" "${t}"

  t="${tmp}/uuid-built"; _tree "${t}"
  _line "${t}/${adapter}" 'fun filter(' '    fun filter(found: java.util.UUID): Boolean = java.util.UUID (1L, 2L) == found'
  _case "a UUID built from numbers of an adapter's own fails" 1 "${adapter} builds a UUID" "${t}"

  t="${tmp}/uuid-parcel"; _tree "${t}"
  _line "${t}/${adapter}" 'fun filter(' '    fun filter(found: java.util.UUID): Boolean = ParcelUuid.fromString(NAME).uuid == found'
  _case "a UUID parsed by the platform's own wrapper fails" 1 "${adapter} builds a UUID" "${t}"

  t="${tmp}/uuid-alias"; _tree "${t}"
  sed -i 's/^import com.oblivioustech.haven.mesh.core.MeshRadioConstants$/import com.oblivioustech.haven.mesh.core.MeshRadioConstants\nimport java.util.UUID as Id/' "${t}/${adapter}"
  _line "${t}/${adapter}" 'fun filter(' '    fun filter(found: Id): Boolean = Id(1L, 2L) == found'
  _case "the class imported under another name fails" 1 "${adapter} builds a UUID" "${t}"

  t="${tmp}/mode-unnamed"; _tree "${t}"
  sed -i '/ADVERTISE_TX_POWER_MEDIUM/d' "${t}/${CONSTANTS}"
  _case "a mode held as a bare integer, its Android constant unnamed, fails" 1 "${CONSTANTS} does not name the scan mode" "${t}"

  # Check 9: no log call of the radio's is allowlisted.
  t="${tmp}/allowlisted"; _tree "${t}"
  printf 'haven/android/app/src/main/kotlin/com/oblivioustech/haven/mesh/MeshService.kt|Log.w(TAG, "stopped")|a fixed word|owner\n' >>"${t}/${LOG_ALLOWLIST}"
  _case "an allowlist row for a file of the mesh fails" 1 "${LOG_ALLOWLIST} has a row for a file of the mesh" "${t}"

  # Check 10: a build with the flag off declares nothing of the mesh.
  t="${tmp}/main-permission"; _tree "${t}"
  sed -i 's|^</manifest>$|    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>\n</manifest>|' "${t}/${APP_SRC}/main/AndroidManifest.xml"
  _case "a Bluetooth permission in the main manifest fails" 1 "${APP_SRC}/main/AndroidManifest.xml names Bluetooth" "${t}"

  t="${tmp}/main-service"; _tree "${t}"
  sed -i 's|^</manifest>$|    <application><service android:name=".radio.Relay" android:foregroundServiceType="connectedDevice"/></application>\n</manifest>|' "${t}/${APP_SRC}/main/AndroidManifest.xml"
  _case "a connectedDevice service in the main manifest fails" 1 "${APP_SRC}/main/AndroidManifest.xml names Bluetooth" "${t}"

  t="${tmp}/debug-component"; _tree "${t}"
  sed -i 's|^</manifest>$|    <application><receiver android:name=".mesh.MeshReceiver"/></application>\n</manifest>|' "${t}/${APP_SRC}/debug/AndroidManifest.xml"
  _case "a mesh component in the debug manifest fails" 1 "${APP_SRC}/debug/AndroidManifest.xml names Bluetooth" "${t}"

  # Check 11: the JVM tests are the pinned ones, and none is switched off.
  t="${tmp}/test-gone"; _tree "${t}"
  sed -i '/fun anAddressNeverReachesTheEngine()/,/^$/d' "${t}/${JVM_TESTS}/kotlin/RadioTest.kt"
  _case "a pinned test that is gone fails" 1 '< anAddressNeverReachesTheEngine' "${t}"

  t="${tmp}/test-renamed"; _tree "${t}"
  sed -i 's/fun everyInputChecksTheDeadlineBeforeAnythingElse()/fun someInputsCheckTheDeadline()/' "${t}/${JVM_TESTS}/kotlin/RadioTest.kt"
  _case "a pinned test under another name fails" 1 '> someInputsCheckTheDeadline' "${t}"

  t="${tmp}/test-unmarked"; _tree "${t}"
  sed -i -z 's/    @Test\n    fun outputsDecodeAsTheFixtureSays()/    fun outputsDecodeAsTheFixtureSays()/' "${t}/${JVM_TESTS}/kotlin/RadioTest.kt"
  _case "a pinned test that lost its @Test fails: it no longer runs" 1 '< outputsDecodeAsTheFixtureSays' "${t}"

  t="${tmp}/test-ignored"; _tree "${t}"
  sed -i 's/^    fun aPolledFrameIsSentOrItsLinkIsClosed()/    @Ignore\n    fun aPolledFrameIsSentOrItsLinkIsClosed()/' "${t}/${JVM_TESTS}/kotlin/RadioTest.kt"
  sed -i -z 's/    @Test\n    @Ignore\n/    @Ignore\n    @Test\n/' "${t}/${JVM_TESTS}/kotlin/RadioTest.kt"
  _case "an ignored test fails" 1 'is ignored, or assumes its way out' "${t}"

  # Check 12: the floor of the peer table is the engine's.
  t="${tmp}/floor-here"; _tree "${t}"
  sed -i 's/^    const val RSSI_FLOOR = -85$/    const val RSSI_FLOOR = -90/' "${t}/${CONSTANTS}"
  _case "a floor that is not the engine's default fails" 1 "holds RSSI_FLOOR '-90' and the default of ${ENGINE} is rssi_floor '-85'" "${t}"

  t="${tmp}/floor-there"; _tree "${t}"
  sed -i 's/^            rssi_floor: -85,$/            rssi_floor: -80,/' "${t}/${ENGINE}"
  _case "the engine's default moved alone fails" 1 "holds RSSI_FLOOR '-85' and the default of ${ENGINE} is rssi_floor '-80'" "${t}"

  t="${tmp}/floor-gone"; _tree "${t}"
  sed -i '/^    const val RSSI_FLOOR = -85$/d' "${t}/${CONSTANTS}"
  _case "no floor in the constants fails: the one in a comment is not it" 1 "holds RSSI_FLOOR ''" "${t}"

  t="${tmp}/floor-unread"; _tree "${t}"
  sed -i 's/^impl Default for Config {$/impl Config {/' "${t}/${ENGINE}"
  _case "an engine whose default the pin cannot find fails, and is not read from a test's config" 1 "is rssi_floor ''" "${t}"

  # Checks 2 and 6, for the third module.
  t="${tmp}/lever-denied"; _tree "${t}"
  sed -i -z 's/#\[allow(unsafe_code)\]\nmod log_lever;/mod log_lever;/' "${t}/${LIB}"
  _case "the lever's allowance gone fails: lib.rs is not what was reviewed" 1 'names unsafe_code otherwise' "${t}"

  t="${tmp}/lever-other-condition"; _tree "${t}"
  sed -i -z 's/#\[cfg(any(target_os = "android", test))\]\n#\[allow(unsafe_code)\]\nmod log_lever;/#[cfg(target_os = "android")]\n#[allow(unsafe_code)]\nmod log_lever;/' "${t}/${LIB}"
  _case "the lever compiled under another condition fails" 1 "does not declare the radio's three modules as pinned" "${t}"

  t="${tmp}/lever-two-ways"; _tree "${t}"
  printf '#[cfg(all(target_os = "android", not(test)))]\nuse api::shipped_lever as log_lever;\n' >>"${t}/${LIB}"
  _case "another module under the lever's name fails" 1 "does not declare the radio's three modules as pinned" "${t}"

  t="${tmp}/lever-path"; _tree "${t}"
  sed -i 's/^mod log_lever;$/#[path = "other_lever.rs"]\nmod log_lever;/' "${t}/${LIB}"
  _case "the lever built from another file fails" 1 "${LIB} gives something a path" "${t}"

  # Check 13: the lever's own file.
  t="${tmp}/lever-twelfth"; _tree "${t}"
  _line "${t}/${LEVER}" 'let mut start = [0; LEVER_TAG_READ];' '    let mut start = [0; LEVER_TAG_READ];\n    let _ = unsafe { next.add(64).read() };'
  _case "a twelfth unsafe block in the lever fails: the count is pinned" 1 "${LEVER} writes unsafe or extern otherwise" "${t}"

  t="${tmp}/lever-fewer"; _tree "${t}"
  _line "${t}/${LEVER}" 'unsafe { (liblog.set_minimum_priority)(LEVER_FLOOR) };' '        (liblog.set_minimum_priority)(LEVER_FLOOR);'
  _case "an unsafe block gone from the lever fails too: the pin is the count" 1 '10 unsafe block(s)' "${t}"

  t="${tmp}/lever-unsafe-fn"; _tree "${t}"
  sed -i 's/^fn tag_start(message: \*const Message)/unsafe fn tag_start(message: *const Message)/' "${t}/${LEVER}"
  _case "an unsafe fn in the lever fails" 1 "${LEVER} writes unsafe or extern otherwise" "${t}"

  t="${tmp}/lever-second-callback"; _tree "${t}"
  _before_tests "${t}/${LEVER}" 'extern "C" fn second(message: *const Message) {\n    logger(message);\n}'
  _case "a second extern fn in the lever fails" 1 "${LEVER} writes unsafe or extern otherwise" "${t}"

  t="${tmp}/lever-extern-block"; _tree "${t}"
  _before_tests "${t}/${LEVER}" 'extern "C" {\n    fn getpid() -> i32;\n}'
  _case "an extern block in the lever fails: an import the linker must bind" 1 "${LEVER} writes unsafe or extern otherwise" "${t}"

  t="${tmp}/lever-unwind-abi"; _tree "${t}"
  sed -i 's/^extern "C" fn logger(/extern "C-unwind" fn logger(/' "${t}/${LEVER}"
  _case "the logger under an ABI that lets a panic unwind into liblog fails" 1 '0 logger(s)' "${t}"

  t="${tmp}/lever-unsafe-in-tests"; _tree "${t}"
  _line "${t}/${LEVER}" 'let tags: Vec<String>' '        let tags: Vec<String> = vec![format!("{}", unsafe { *c"flutter".as_ptr() })];'
  _case "an unsafe block in the lever's tests fails: the count is the file's" 1 '12 unsafe block(s)' "${t}"

  t="${tmp}/lever-early-cfg-test"; _tree "${t}"
  sed -i 's/^fn lookup(library: &CStr) -> Option<Liblog> {$/#[cfg(test)]\nconst HIDE: u8 = 0;\n\nfn lookup(library: \&CStr) -> Option<Liblog> {/' "${t}/${LEVER}"
  _case "a cfg(test) ahead of the lever's tests fails" 1 "${LEVER} has a cfg(test) that is not the one" "${t}"

  t="${tmp}/lever-behind-tests"; _tree "${t}"
  printf '\nfn hidden() -> String {\n    format!("{:?}", LINES)\n}\n' >>"${t}/${LEVER}"
  _case "code behind the lever's tests fails" 1 "${LEVER} has a cfg(test) that is not the one" "${t}"

  t="${tmp}/lever-exported"; _tree "${t}"
  sed -i 's/^extern "C" fn logger(/#[no_mangle]\nextern "C" fn logger(/' "${t}/${LEVER}"
  _case "a symbol exported from the lever fails" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-static-mut"; _tree "${t}"
  sed -i 's/^static LINES: AtomicU32 = AtomicU32::new(0);$/static mut LINES: u32 = 0;/' "${t}/${LEVER}"
  _case "a static mut in the lever fails" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-unwrap"; _tree "${t}"
  _line "${t}/${LEVER}" 'let Some(liblog) = found else {' '    let liblog = found.as_ref().unwrap();\n    let Some(liblog) = Some(liblog) else {'
  _case "an unwrap in the lever fails" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-expect"; _tree "${t}"
  _line "${t}/${LEVER}" 'let set_logger = find(c"__android_log_set_logger")?;' '    let set_logger = Some(find(c"__android_log_set_logger").expect ("a symbol"))?;'
  _case "an expect in the lever fails, a space before its parenthesis or none" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-allocates"; _tree "${t}"
  _line "${t}/${LEVER}" 'let mut start = [0; LEVER_TAG_READ];' '    let mut start = [0; LEVER_TAG_READ];\n    let _copy = Box::new(start);'
  _case "an allocation in the lever fails" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-copies"; _tree "${t}"
  _line "${t}/${LEVER}" 'let mut start = [0; LEVER_TAG_READ];' '    let mut start = [0; LEVER_TAG_READ];\n    let _copy = start.to_vec();'
  _case "an allocation under a method's name fails too" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-locks"; _tree "${t}"
  sed -i 's/^static LINES: AtomicU32 = AtomicU32::new(0);$/static LINES: AtomicU32 = AtomicU32::new(0);\nstatic HELD: std::sync::Mutex<u32> = std::sync::Mutex::new(0);/' "${t}/${LEVER}"
  _case "a lock in the lever fails" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-logs"; _tree "${t}"
  _line "${t}/${LEVER}" 'let Some(liblog) = found else {' '    let Some(liblog) = found else {\n        log::warn!("no lever");'
  _case "a log line in the lever fails" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-radio"; _tree "${t}"
  _line "${t}/${LEVER}" 'let before = LINES.load(Ordering::Relaxed);' '    let before = LINES.load(Ordering::Relaxed) ^ u32::from(crate::api::radio_left_ms() == 0);'
  _case "a radio entry called from the lever fails" 1 "${LEVER} names what the lever has no use for" "${t}"

  t="${tmp}/lever-formats"; _tree "${t}"
  _line "${t}/${LEVER}" 'let before = LINES.load(Ordering::Relaxed);' '    let before = LINES.load(Ordering::Relaxed);\n    let _ = format_args!("{before}");'
  _case "a macro that formats in the lever fails" 1 "${LEVER} invokes a macro that is not cfg!" "${t}"

  t="${tmp}/lever-asserts"; _tree "${t}"
  _line "${t}/${LEVER}" 'let before = LINES.load(Ordering::Relaxed);' '    let before = LINES.load(Ordering::Relaxed);\n    assert!(before < u32::MAX);'
  _case "an assertion at run time in the lever fails: a panic inside liblog's call" 1 "${LEVER} invokes a macro that is not cfg!" "${t}"

  t="${tmp}/lever-debug-asserts"; _tree "${t}"
  _line "${t}/${LEVER}" 'let before = LINES.load(Ordering::Relaxed);' '    let before = LINES.load(Ordering::Relaxed);\n    debug_assert!(before < u32::MAX);'
  _case "a debug assertion in the lever fails" 1 "${LEVER} invokes a macro that is not cfg!" "${t}"

  t="${tmp}/lever-layout-unchecked"; _tree "${t}"
  sed -i 's/^const _: () = assert!(matches!($/const _: bool = (matches!(/' "${t}/${LEVER}"
  _case "the layout's compile-time assertion gone fails" 1 "${LEVER} invokes a macro that is not cfg!" "${t}"

  t="${tmp}/lever-sixth-symbol"; _tree "${t}"
  _line "${t}/${LEVER}" 'let set_logger = find(c"__android_log_set_logger")?;' '    let set_logger = find(c"__android_log_set_logger")?;\n    let _aborter = find(c"__android_log_set_aborter")?;'
  _case "a sixth function looked up fails" 1 "${LEVER} holds a string that is not the library's name" "${t}"

  t="${tmp}/lever-other-library"; _tree "${t}"
  sed -i 's/lookup(c"liblog.so")/lookup(c"libbase.so")/' "${t}/${LEVER}"
  _case "another library looked in fails" 1 "${LEVER} holds a string that is not the library's name" "${t}"

  t="${tmp}/lever-tag-literal"; _tree "${t}"
  _line "${t}/${LEVER}" 'let empty: [c_char; 1] = [0];' '    let empty = c"HavenLever";'
  _case "a tag of its own in the lever fails: the sentinel has none" 1 "${LEVER} holds a string that is not the library's name" "${t}"

  t="${tmp}/lever-libc-more"; _tree "${t}"
  _line "${t}/${LEVER}" 'if handle.is_null() {' '    let _ = unsafe { libc::strlen(library.as_ptr()) };\n    if handle.is_null() {'
  _case "another function of libc in the lever fails" 1 "${LEVER} names of libc something other than dlopen" "${t}"

  t="${tmp}/lever-libc-imported"; _tree "${t}"
  sed -i 's/^use std::sync::OnceLock;$/use std::sync::OnceLock;\n\nuse libc::{dlopen, dlsym};/; s/libc::dlopen(/dlopen(/; s/libc::dlsym(/dlsym(/' "${t}/${LEVER}"
  _case "libc's functions imported, and called by a bare name, fail" 1 "${LEVER} names of libc something other than dlopen" "${t}"

  t="${tmp}/lever-reaches-engine"; _tree "${t}"
  sed -i 's/^use crate::api::{lever_held, /use crate::api::{mesh_stop, lever_held, /' "${t}/${LEVER}"
  _case "something of the bridge that is no decision of the lever's, imported, fails" 1 "${LEVER} reaches something of the bridge" "${t}"

  t="${tmp}/lever-reaches-by-path"; _tree "${t}"
  _line "${t}/${LEVER}" 'let before = LINES.load(Ordering::Relaxed);' '    let before = LINES.load(Ordering::Relaxed) ^ u32::from(crate::api::mesh_empty() == 0);'
  _case "the bridge reached by a path from the lever fails" 1 "${LEVER} reaches something of the bridge" "${t}"

  t="${tmp}/log-sys"; _tree "${t}"
  printf 'pub fn loggable() -> bool {\n    android_log_sys::LogPriority::DEBUG as i32 > 0\n}\n' >>"${t}/${SRC}/api.rs"
  _case "android_log_sys named in api.rs fails" 1 "${SRC}/api.rs names android_log_sys" "${t}"

  t="${tmp}/log-sys-in-lever"; _tree "${t}"
  _line "${t}/${LEVER}" 'let before = LINES.load(Ordering::Relaxed);' '    let before = LINES.load(Ordering::Relaxed) ^ android_log_sys::LogPriority::DEBUG as u32;'
  _case "android_log_sys named in the lever itself fails" 1 "${LEVER} names android_log_sys" "${t}"

  t="${tmp}/symbol-elsewhere"; _tree "${t}"
  printf 'const FLOOR: &str = "__android_log_set_minimum_priority";\n' >>"${t}/${CALLS}"
  _case "one of the five functions named outside the lever fails, in a string too" 1 "${CALLS} names android_log_sys" "${t}"

  # Misconfiguration.
  t="${tmp}/no-lever"; _tree "${t}"
  rm "${t}/${LEVER}"
  _case "a missing lever is a misconfiguration" 2 '' "${t}"

  t="${tmp}/no-engine"; _tree "${t}"
  rm "${t}/${ENGINE}"
  _case "a tree with no engine to read the floor from is a misconfiguration" 2 '' "${t}"

  t="${tmp}/no-constants"; _tree "${t}"
  rm "${t}/${CONSTANTS}"
  _case "a radio with no file of constants is a misconfiguration" 2 '' "${t}"

  t="${tmp}/no-jvm-tests"; _tree "${t}"
  rm -r "${t}/${JVM_TESTS}"
  _case "a radio with no JVM tests is a misconfiguration" 2 '' "${t}"

  t="${tmp}/no-shim"; _tree "${t}"
  rm "${t}/${SHIM}"
  _case "a missing exports' file is a misconfiguration" 2 '' "${t}"

  t="${tmp}/no-calls"; _tree "${t}"
  rm "${t}/${CALLS}"
  _case "a missing file of calls is a misconfiguration" 2 '' "${t}"

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
