#!/usr/bin/env bash
# CI guard: the iOS app-switcher privacy blur — the iOS half of
# `privacyWhatOthersSeeScreenshots`.
#
# That string ships in thirteen languages and tells the user that "On iPhone it
# cannot [block screenshots]: Haven blurs the app-switcher preview". Its
# `@description` forbids flattening the two platforms into one claim. What this
# guard checks of that sentence is split deliberately between all thirteen
# locales and English alone; link 8 below says which is which, and means it.
#
# Android's half is a WINDOW flag pinned by `check_flag_secure_app_wide.sh`; the
# iOS half is six lines of `AppDelegate.swift` — a `UIVisualEffectView` added on
# resign and removed on become-active — and until this guard existed it was
# backed by nothing at all. Delete those six lines and every gate in the repo
# stays green while thirteen translations keep promising the blur.
#
# There is no runtime proof available here: the repo-guards job has no Xcode, no
# Simulator, and the OS-captured snapshot is not observable from inside the
# process even when there is one. So this pins, statically, every link the
# promise rests on. It is a UNION — each link can be removed on its own, each
# such edit reads locally reasonable in a diff, and each leaves the others
# looking correct:
#
#   1. THE ANCHORS EXIST. `AppDelegate: FlutterAppDelegate` and the
#      `privacyBlurView` property. A guard that cannot find its subject must
#      fail, never pass for want of something to scan.
#
#   2. ADDED ON THE PRE-SNAPSHOT CALLBACK, AND ONLY THERE. The blur is
#      installed in `applicationWillResignActive`, which is correct and is NOT
#      interchangeable with `applicationDidEnterBackground`. While the app
#      switcher is open showing Haven's card, the app is *inactive but still
#      foreground* — `didEnterBackground` has not been called yet — and the same
#      is true of the Control Centre / Notification Centre pull-down and an
#      incoming call. Only `willResignActive` covers those, and it also strictly
#      precedes `didEnterBackground`, so it covers the snapshot too. Moving the
#      add "down" to `didEnterBackground` is the tidy-looking edit that silently
#      un-blurs the very screen the copy names.
#
#   3. IT COVERS THE WINDOW — TARGET, GEOMETRY AND STACKING. Added to the
#      `window` itself (not to the root view controller's view, which a
#      presented modal — the photo-crop screen, a bottom sheet — is not inside),
#      sized to `window.bounds`, with a flexible autoresizing mask, and left on
#      top. Haven ships three iPhone orientations — portrait and both landscapes
#      (`UISupportedInterfaceOrientations` in Info.plist; the `~ipad` array adds
#      upside-down for four) — so a rotation while inactive resizes the window
#      under a fixed-frame overlay and re-exposes the content it was covering.
#      EVERY frame assignment in the body must be `window.bounds`, not merely
#      one of them: a body that pins the frame on one line and overwrites it
#      with `.zero` on the next satisfies a presence grep and renders nothing —
#      and so does the same overwrite one accessor down (`blur.frame.size =
#      .zero`), which is why the scan is rooted at `.frame` rather than at the
#      whole-struct assignment.
#      And `addSubview` is the only view-hierarchy call the method may make,
#      because `window.sendSubviewToBack(blur)` or `insertSubview(blur, at: 0)`
#      leaves the overlay installed, sized and opaque BEHIND the content it
#      exists to cover — every other link still reads as satisfied and the
#      snapshot still shows the map. This link is about the TARGET, the geometry
#      and the z-order; whether the add is reachable is link 5's question, and
#      the two are checked apart so that neither fixture trips the other's
#      message.
#
#   4. IT IS A REAL BLUR. `UIBlurEffect(style: .systemMaterial)`, pinned as a
#      constant in BOTH directions, and no visibility lever in the body. The
#      mutation this kills is the one that keeps the code looking right:
#      `effect: nil`, `alpha = 0`, `.clear`, a vibrancy effect, a swap to a
#      thin/ultra-thin material — or the same thing one level down, where a
#      view-level blacklist never looks: `blur.layer.opacity = 0`, a
#      `layer.isHidden`, a scale-to-zero `transform`. All of them leave a "blur
#      view" installed, sized and layered exactly as before, through which
#      marker positions on a map are still legible. A different material may
#      well be defensible — but it must be argued for HERE, not slipped in as a
#      design tweak.
#
#   5. THE ADD IS UNCONDITIONAL. At most one `guard`, whose conjuncts may only
#      be the window binding and the re-entrancy nil check; NO `return` anywhere
#      else in the body AT ANY NESTING DEPTH; and the `addSubview`/assignment
#      statements at the method's own statement depth, never nested in an `if`.
#      One extra conjunct (`guard !Self.blurDisabled else { return }`) turns the
#      whole method into a no-op that still reads as protection — and so does
#      the same kill switch written across three lines, which is why the return
#      scan is depth-aware rather than bound to the statement list: an `if`
#      whose brace opens on its own line puts its `return` a level down, out of
#      sight of any scan that reads only the method's own statements. That
#      shape is what a formatter produces from the one-line form, so a scan that
#      missed it would be un-tested by its own fixture the day someone ran
#      swift-format.
#
#   6. REMOVED ONLY ON BECOME-ACTIVE, AND THE HANDLE IS RESTORED.
#      `applicationDidBecomeActive` is the only method allowed to touch the
#      view, unconditionally — no `return` at any depth, for the reason link 5
#      gives — and it must BOTH `removeFromSuperview()` and re-nil
#      `privacyBlurView`. Two distinct failures live here.
#      `applicationWillEnterForeground` does not fire on a resign that never
#      reached the background (Control Centre, a declined call), so a removal
#      moved there strands the blur over a live app. And dropping the `= nil`
#      leaves a stale non-nil property, so link 5's re-entrancy check is false
#      forever after: the app is protected on the FIRST backgrounding and on no
#      later one, with nothing on screen ever looking wrong.
#
#   7. THE APP STILL USES THE APPLICATION LIFECYCLE. No
#      `UIApplicationSceneManifest` in Info.plist. Adopt UIScene — a Flutter
#      template upgrade can do this without anyone reading the diff — and UIKit
#      stops delivering all four of the app-delegate callbacks above in favour
#      of `sceneWillResignActive`/`sceneDidBecomeActive`. Every other link stays
#      intact, compiles, and executes never. This is the exact analogue of the
#      Android guard's `android:name` link. Read with xmllint, so a key inside
#      an XML comment is not mistaken for a live one.
#
#   8. THE PROMISE IS STILL MADE. Two halves, on purpose, and they cover
#      different ground — read them as such, because a guard that claims the
#      wider one and performs the narrower is worse than no guard at all:
#
#      ACROSS ALL THIRTEEN LOCALE ARBs, the key must exist and be non-empty, and
#      there must still be thirteen of them. That is what makes "in thirteen
#      languages" a checked statement rather than a remembered one: a clause
#      dropped, emptied or whitespaced out in a translation nobody on the
#      English review reads is the stale-translation shape this project has been
#      bitten by before, and `arb_parity_check.dart` would not object either —
#      it compares keys, placeholders and plural categories, not whether the
#      sentence is still there in a locale whose file was deleted outright.
#
#      IN app_en.arb ALONE, the value must still name Android, iPhone/iOS and
#      the blur, so the two platforms cannot be flattened into one claim (which
#      the key's own @description forbids). English-only, deliberately: the
#      translations re-word all three ("unscharf", "difumina", "ぼかします"),
#      and a guard that demanded English tokens in Persian would be a guard
#      against translating.
#
#      Together with links 2-6 this closes the loop in both directions: the code
#      cannot be deleted while the sentence stands, and the sentence cannot be
#      deleted or flattened while the code stands.
#
# THE SLICING HAZARD, DELIBERATELY HANDLED. Checks 2-6 are bound to ONE method
# body each, not to the file, because "somewhere in AppDelegate.swift" is not
# where any of them has to be. The Android twin was written first and its first
# draft got exactly this wrong: it ran a brace-matched slice over Kotlin's
# expression-body form (`fun f(a: Activity) = Unit`, which never opens a brace),
# so the slice ran to EOF and silently widened a check bound to one method into
# a check on the whole file. Swift has no expression-bodied `func`, so that
# specific trap does not port — and the Kotlin fix (stop the slice at a `=`)
# MUST NOT be ported either, since `let blur = ...` is the first line of the
# very body being sliced and default parameter values put `=` in signatures.
# Swift's version of the hazard is braces inside string literals: one `print("{")`
# unbalances the counter and runs the slice to EOF. This is handled twice over —
# the code view blanks string contents as well as comments, and the slicer
# reports a body that never closes as a BROKEN GUARD (exit 2), never as a pass.
# A stray `}` inside a string truncates instead of widening, which fails closed
# through the presence checks.
#
# Pure bash + coreutils + xmllint + jq. No Xcode, no toolchain.
#
# Usage:
#   check_ios_privacy_blur.sh              # check the tree
#   check_ios_privacy_blur.sh --self-test  # hermetic fixtures, no repo read
#
# Exit codes:
#   0  all checks pass
#   1  an invariant is violated (including "the anchor is gone" — a moved or
#      renamed subject scans nothing, which is a failure, not a pass)
#   2  the guard itself is broken (a body that never closes, an unparsable
#      Info.plist or ARB, a missing input file, a failed self-test)

set -Eeuo pipefail

SCRIPT_NAME="check_ios_privacy_blur"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# How many locale ARBs Haven ships. A FLOOR, not an equality: adding a fourteenth
# language passes untouched, deleting one fails. It is pinned because this file
# says "thirteen languages" in its own prose and in two failure messages, and a
# number a guard asserts but does not check is the overclaim this workstream
# exists to remove. Dropping a locale is a decision; make it here and in the
# wording this pins, in the same commit.
LOCALE_ARB_FLOOR=13

# How many locale ARBs were actually read, set by check_promise_still_made. The
# success line reports THIS, not the floor: printing the floor would announce
# "all 13 locales" on the day a fourteenth language ships and is scanned.
LOCALE_ARB_COUNT=0

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
broken_msg() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { broken_msg "$*"; exit 2; }

# ---------------------------------------------------------------------------
# code_view <file>
#
# One output line per input line (line numbers survive) with comments removed
# AND string literal contents blanked, keeping the quotes. Blanking the contents
# is what stops a brace in a log message from moving a method boundary; see the
# slicing note in the header.
# ---------------------------------------------------------------------------
code_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else if (instr3) {
          e = index(substr(line, i), "\"\"\"")
          if (e == 0) { i = n + 1 } else { i += e + 2; instr3 = 0; out = out "\"\"\"" }
        } else if (instr) {
          ch = substr(line, i, 1)
          if (ch == "\\") { i += 2 }
          else if (ch == "\"") { instr = 0; out = out "\""; i += 1 }
          else { i += 1 }
        } else {
          three = substr(line, i, 3); two = substr(line, i, 2)
          if (three == "\"\"\"") { instr3 = 1; out = out "\"\"\""; i += 3 }
          else if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//") { i = n + 1 }
          else if (substr(line, i, 1) == "\"") { instr = 1; out = out "\""; i += 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      # A single-line Swift string cannot continue past its own line.
      instr = 0
      print out
    }' "$1"
}

# ---------------------------------------------------------------------------
# method_range <signature-substring> <code-view-file>
#
# Prints "<start> <end>" (1-based, inclusive) for the first method whose
# signature line contains the substring, or "" when there is none, or
# "<start> EOF" when the body never closes — the runaway case, which is a broken
# guard rather than a verdict.
#
# A signature wrapped across lines reaches its `{` on a later line and is
# handled: the slice only ends once a brace has actually been opened.
# ---------------------------------------------------------------------------
method_range() {
  awk -v sig="$1" '
    !started && index($0, sig) > 0 { started = 1; start = NR }
    started {
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (o > 0) seen = 1
      if (seen && depth <= 0) { print start " " NR; found = 1; exit }
    }
    END { if (started && !found) print start " EOF" }
  ' "$2"
}

# ---------------------------------------------------------------------------
# top_level  (filter, stdin -> stdout)
#
# The lines of a method slice that sit at the method's OWN statement depth.
# Depth is counted BEFORE the line's own braces, so the signature line is 0,
# statements are 1, and anything nested inside an `if`, a closure or a type is
# 2 or more. The method's own closing brace is the only depth-1 `}` and is
# dropped, so what remains is exactly the statement list.
# ---------------------------------------------------------------------------
top_level() {
  awk '
    {
      d = depth
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (d == 1) {
        t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t != "}") print $0
      }
    }'
}

# ---------------------------------------------------------------------------
# check_blur_lifecycle <AppDelegate.swift>     — links 1-6
# ---------------------------------------------------------------------------
check_blur_lifecycle() {
  local swift="$1" fail=0
  local code
  code="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${code}'" RETURN
  code_view "${swift}" >"${code}"

  # --- link 1: the anchors -------------------------------------------------
  if ! grep -qE 'class +AppDelegate *: *FlutterAppDelegate\b' "${code}"; then
    fail_msg "no \`class AppDelegate: FlutterAppDelegate\` in ${swift##*/}. \
The app-switcher blur is pinned to that class; if it was renamed or moved, move \
this guard with it — a guard with no subject certifies nothing."
    return 1
  fi
  local decl_line
  decl_line="$(grep -nE '(private +)?var +privacyBlurView *: *UIVisualEffectView\?' \
    "${code}" | head -1 | cut -d: -f1)"
  if [[ -z "${decl_line}" ]]; then
    fail_msg "${swift##*/} has no \`privacyBlurView: UIVisualEffectView?\` property. \
privacyWhatOthersSeeScreenshots promises, in thirteen languages, that Haven blurs \
the iPhone app-switcher preview; nothing else in this app does that. Remove the \
promise first, in every locale, if the blur is really going."
    return 1
  fi

  # --- the two bodies, structure-bound -------------------------------------
  local add_range rem_range
  add_range="$(method_range 'func applicationWillResignActive(' "${code}")"
  rem_range="$(method_range 'func applicationDidBecomeActive(' "${code}")"

  if [[ -z "${add_range}" ]]; then
    fail_msg "${swift##*/} has no applicationWillResignActive. That is the only \
callback that runs before iOS renders Haven in the app switcher AND before the \
Control-Centre/incoming-call peek; applicationDidEnterBackground has not fired \
while the switcher card is on screen."
    fail=1
  fi
  if [[ -z "${rem_range}" ]]; then
    fail_msg "${swift##*/} has no applicationDidBecomeActive, so nothing takes \
the blur back off: the app returns to the foreground behind an opaque overlay."
    fail=1
  fi
  (( fail == 0 )) || return 1
  if [[ "${add_range}" == *EOF || "${rem_range}" == *EOF ]]; then
    broken_msg "a method body in ${swift##*/} never closes (unbalanced braces in \
the code view: add=${add_range}, remove=${rem_range}). This guard slices ONE \
method at a time on purpose, so a runaway slice would silently widen every check \
below into a whole-file grep. Refusing to report a verdict."
    return 2
  fi

  local add_start add_end rem_start rem_end add_body rem_body add_top rem_top
  read -r add_start add_end <<<"${add_range}"
  read -r rem_start rem_end <<<"${rem_range}"
  add_body="$(sed -n "${add_start},${add_end}p" "${code}")"
  rem_body="$(sed -n "${rem_start},${rem_end}p" "${code}")"
  add_top="$(top_level <<<"${add_body}")"
  rem_top="$(top_level <<<"${rem_body}")"

  # The runaway that matters is not the one that reaches EOF — it is the one
  # that stays brace-BALANCED by swallowing the next method, which happens the
  # moment a body loses its own closing brace: the enclosing type's final `}`
  # closes the slice instead, and every check below quietly becomes a whole-file
  # grep that passes on a file where the method it names has no end. A method
  # signature inside a method's own statement list is the signature of that.
  local swallowed
  swallowed="$(grep -E '\bfunc\b' <<<"${add_top}"$'\n'"${rem_top}" || true)"
  if [[ -n "${swallowed}" ]]; then
    broken_msg "a sliced method body in ${swift##*/} contains another method \
signature: ${swallowed//$'\n'/ | }. The braces do not balance where they should, \
so the slice covers more than the method it is named after and this guard would \
be checking the wrong text. Refusing to report a verdict."
    return 2
  fi

  # --- link 4: a real blur, pinned as a constant in both directions --------
  local add_squashed
  add_squashed="$(tr -d ' \t\n' <<<"${add_body}")"
  if [[ "${add_squashed}" != *'UIVisualEffectView(effect:UIBlurEffect(style:.systemMaterial))'* ]]; then
    fail_msg "applicationWillResignActive does not build \
\`UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))\`. The overlay \
staying installed, sized and layered while its effect becomes nil, a vibrancy \
effect, or a thin/ultra-thin material is the mutation that keeps the code looking \
correct and leaves map marker positions legible in the snapshot. The material is \
pinned in both directions: change it here, deliberately, with the reason."
    fail=1
  fi
  # `\.layer\b` and `\btransform\b` are here because the view-level levers have
  # exact CALayer and geometry twins: `blur.layer.opacity = 0` and
  # `blur.transform = CGAffineTransform(scaleX: 0, y: 0)` are `alpha = 0` written
  # one level down, and a blacklist that names only the view properties reads as
  # if it covered them.
  local neutralizer
  neutralizer="$(grep -nE '\balpha\b|\bisHidden\b|effect *[:=] *nil|UIVibrancyEffect|\.clear\b|\.layer\b|\btransform\b' \
    <<<"${add_body}" || true)"
  if [[ -n "${neutralizer}" ]]; then
    fail_msg "applicationWillResignActive manipulates the overlay's visibility, \
transparency or layer: ${neutralizer//$'\n'/ | }. A blur view that is present but \
see-through — whether through \`alpha\`, its \`layer\`, or a scale-to-zero \
\`transform\` — passes every reading of this code and protects nothing."
    fail=1
  fi

  # --- link 3: it covers the window ----------------------------------------
  # Target and geometry only, over the whole body. Whether the add is REACHABLE
  # is link 5's question and is asked there: fusing the two into one
  # depth-bound presence check made a nested-add mutation report a wrong-target
  # failure, so the fixture for one link was passing on the other's message.
  if ! grep -qE 'window\??\.addSubview\(' <<<"${add_body}"; then
    fail_msg "applicationWillResignActive does not add the blur to the WINDOW. \
\`rootViewController.view\` is not the same thing: a presented modal (the \
photo-crop screen, a bottom sheet) is not inside it and would be photographed \
unblurred."
    fail=1
  fi
  # Every frame assignment, not merely the presence of the right one: the pinned
  # line stays exactly where it was while `blur.frame = .zero` on the next line
  # undoes it, which is a presence grep's blind spot and reads in a diff as a
  # tidy-up. Rooted at `.frame` rather than at `.frame =`, because the overwrite
  # also goes through a component — `blur.frame.size = .zero`,
  # `blur.frame.origin.y = 4000` — which is the identical mutation one accessor
  # down, invisible to a scan bound to the whole-struct assignment. The trailing
  # `[^=]` keeps a comparison (`blur.frame == window.bounds`) from reading as
  # one, and the leading `[^=]*` keeps a read (`let saved = blur.frame`) out.
  local frame_assigns bad_frame
  frame_assigns="$(grep -E '\.frame\b[^=]*=[^=]' <<<"${add_body}" || true)"
  if [[ -z "${frame_assigns}" ]]; then
    fail_msg "the blur's frame is never set to \`window.bounds\`. A zero or stale \
frame renders nothing at all while every other line of this method still reads as \
protection."
    fail=1
  else
    bad_frame="$(grep -vE '\.frame *= *window\??\.bounds[[:space:]]*$' <<<"${frame_assigns}" || true)"
    if [[ -n "${bad_frame}" ]]; then
      fail_msg "applicationWillResignActive assigns a frame that is not \
\`window.bounds\`: ${bad_frame//$'\n'/ | }. The LAST assignment is the one the \
snapshot sees, so a correct line followed by a zero or inset one — or by an \
overwrite of one of its components — covers nothing while the correct line is \
still there to be read."
      fail=1
    fi
  fi
  # Z-order. `addSubview` puts the blur on top and that is the entire point of
  # it; any re-ordering call leaves the overlay installed, sized, opaque — and
  # underneath the content it exists to cover, with nothing else in this method
  # looking wrong. The add is the only view-hierarchy operation permitted here,
  # so bringing an unrelated view forward is refused on the same terms as
  # sending the blur back: telling the two apart needs the argument parsed, and
  # neither belongs in this method unargued.
  local reorder
  reorder="$(grep -E 'sendSubviewToBack|insertSubview|exchangeSubview|bringSubviewToFront' \
    <<<"${add_body}" || true)"
  if [[ -n "${reorder}" ]]; then
    fail_msg "applicationWillResignActive re-orders the window's subviews: \
${reorder//$'\n'/ | }. \`window.addSubview(blur)\` is what puts the blur ABOVE the \
content; sending it back or inserting it below leaves it installed, sized to the \
window and fully opaque, with the map rendered on top of it and photographed by \
the switcher exactly as before."
    fail=1
  fi
  if ! grep -q 'autoresizingMask' <<<"${add_body}" \
    || ! grep -q 'flexibleWidth' <<<"${add_body}" \
    || ! grep -q 'flexibleHeight' <<<"${add_body}"; then
    fail_msg "the blur has no flexible autoresizing mask. Haven ships three \
iPhone orientations — portrait and both landscapes (UISupportedInterfaceOrientations \
in Info.plist) — so a rotation while the app is inactive resizes the window out \
from under a fixed-frame overlay and re-exposes what it was covering."
    fail=1
  fi
  if ! grep -qE 'privacyBlurView *= *[A-Za-z_]' <<<"${add_body}"; then
    fail_msg "applicationWillResignActive never stores the view in \
privacyBlurView, so applicationDidBecomeActive has no handle to remove: the blur \
is added once and stays over the live app forever."
    fail=1
  fi

  # --- link 5: the add is unconditional ------------------------------------
  local guard_lines guard_count
  guard_lines="$(grep -E '\bguard\b' <<<"${add_top}" || true)"
  guard_count=0
  [[ -n "${guard_lines}" ]] && guard_count="$(grep -c '' <<<"${guard_lines}")"
  if (( guard_count > 1 )); then
    fail_msg "applicationWillResignActive has ${guard_count} guard statements. \
One is the re-entrancy/window binding; any second one is an off switch for the \
blur that nothing else in the repo would notice."
    fail=1
  elif (( guard_count == 1 )); then
    local cond conjunct
    cond="$(sed -e 's/^.*\bguard\b//' -e 's/\belse\b.*$//' <<<"${guard_lines}")"
    while IFS= read -r conjunct; do
      conjunct="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${conjunct}")"
      [[ -z "${conjunct}" ]] && continue
      if [[ "${conjunct}" != 'let window = window' && "${conjunct}" != 'privacyBlurView == nil' ]]; then
        fail_msg "applicationWillResignActive's guard carries an unrecognised \
condition: \`${conjunct}\`. The only conditions allowed to skip the blur are the \
window binding and the re-entrancy check — a flag, a build config or a \
UserDefaults read here makes the whole method a no-op that still reads as \
protection."
        fail=1
      fi
    done < <(tr ',' '\n' <<<"${cond}")
  fi
  # Over the WHOLE body, depth-aware — not over the statement list. A kill
  # switch written on one line (`if x { return }`) sits at statement depth, but
  # the same switch with its brace on the next line puts the `return` a level
  # down, where a statement-list scan does not look; a formatter turns the first
  # into the second. The only `return` this method may contain is the one in the
  # single recognised guard's `else` clause, which is on the guard line itself
  # and at statement depth — a `guard` nested inside an `if` is not it.
  local stray_return
  stray_return="$(awk '
    function word(s, w) { return s ~ "(^|[^A-Za-z0-9_])" w "([^A-Za-z0-9_]|$)" }
    {
      d = depth
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (word($0, "return") && !(d == 1 && word($0, "guard"))) print
    }' <<<"${add_body}")"
  if [[ -n "${stray_return}" ]]; then
    fail_msg "applicationWillResignActive returns early outside its guard: \
${stray_return//$'\n'/ | }. Everything below such a return is dead in exactly the \
case that added it, and the diff reads like a harmless fast path."
    fail=1
  fi
  # The two statements that constitute the add must sit at the method's OWN
  # statement depth. Counted, not presence-tested at depth 1: a conditional
  # `window.addSubview(blur)` beside an unrelated top-level `addSubview` would
  # satisfy a check that only asked whether SOME add sits at depth, while the
  # real one stayed nested.
  local n_body n_top
  n_body="$(grep -cE '\.addSubview\(' <<<"${add_body}" || true)"
  n_top="$(grep -cE '\.addSubview\(' <<<"${add_top}" || true)"
  if (( n_body != n_top )); then
    fail_msg "applicationWillResignActive adds the blur below its own statement \
depth — nested in an \`if\`, a closure or a \`#if\` branch. A conditional add is \
an off switch with none of the shape of one: every line still reads as \
protection, and nothing is installed in whichever case the condition excludes."
    fail=1
  fi
  n_body="$(grep -cE 'privacyBlurView *= *[A-Za-z_]' <<<"${add_body}" || true)"
  n_top="$(grep -cE 'privacyBlurView *= *[A-Za-z_]' <<<"${add_top}" || true)"
  if (( n_body != n_top )); then
    fail_msg "applicationWillResignActive stores privacyBlurView below its own \
statement depth, so the handle is only set in whichever case the enclosing \
condition allows and applicationDidBecomeActive has nothing to remove in the \
other — leaving an opaque overlay over a live app."
    fail=1
  fi

  # --- link 6: removal only on become-active, handle restored --------------
  if ! grep -qE 'privacyBlurView\??\.removeFromSuperview\(\)' <<<"${rem_top}"; then
    fail_msg "applicationDidBecomeActive does not remove the blur at its own \
statement depth (a removal nested in an \`if\` is a removal that can be skipped)."
    fail=1
  fi
  if ! grep -qE 'privacyBlurView *= *nil' <<<"${rem_top}"; then
    fail_msg "applicationDidBecomeActive removes the blur but leaves \
privacyBlurView non-nil. The re-entrancy guard in applicationWillResignActive \
then sees a stale view forever: Haven is blurred on the FIRST backgrounding and \
on no later one, and nothing on screen ever looks wrong."
    fail=1
  fi
  # The whole body, not its statement list, and with no guard exception: this
  # method takes no conditions at all, so any `return` at any depth is one —
  # including the multi-line `if` that link 5 describes.
  if grep -qE '\breturn\b' <<<"${rem_body}"; then
    fail_msg "applicationDidBecomeActive returns early. The removal must be \
unconditional; a skipped removal leaves the user staring at an opaque overlay \
over a running app, and the obvious 'fix' for that bug is to delete the blur."
    fail=1
  fi

  # --- links 2 + 6: exclusivity --------------------------------------------
  # Absence scans, so each has a floor: the presence checks above already
  # required the real site to be inside the range being excepted, which is what
  # stops a scan that found nothing from certifying a clean file.
  local ln rest
  while IFS=: read -r ln rest; do
    (( ln == decl_line )) && continue
    (( ln >= add_start && ln <= add_end )) && continue
    (( ln >= rem_start && ln <= rem_end )) && continue
    fail_msg "${swift##*/}:${ln} touches privacyBlurView outside its declaration, \
applicationWillResignActive and applicationDidBecomeActive: \
\`$(sed -e 's/^[[:space:]]*//' <<<"${rest}")\`. Every other lifecycle callback is \
either too late to cover the switcher card (didEnterBackground: not yet called \
while the card is on screen) or does not fire at all on a resign that never \
reached the background (willEnterForeground: no Control-Centre pull, no declined \
call), so a second touch point silently trades one of those cases away."
    fail=1
  done < <(grep -n 'privacyBlurView' "${code}" || true)

  while IFS=: read -r ln rest; do
    (( ln >= add_start && ln <= add_end )) && continue
    fail_msg "${swift##*/}:${ln} constructs a UIVisualEffectView outside \
applicationWillResignActive. The blur has to exist before iOS renders the \
switcher card, and applicationWillResignActive is the last callback that is \
guaranteed to run first."
    fail=1
  done < <(grep -n 'UIVisualEffectView(' "${code}" || true)

  while IFS=: read -r ln rest; do
    (( ln >= rem_start && ln <= rem_end )) && continue
    fail_msg "${swift##*/}:${ln} calls removeFromSuperview outside \
applicationDidBecomeActive, which is the only callback that means the user is \
actually looking at the app again."
    fail=1
  done < <(grep -n 'removeFromSuperview(' "${code}" || true)

  (( fail == 0 ))
}

# ---------------------------------------------------------------------------
# check_no_scene_lifecycle <Info.plist>        — link 7
# ---------------------------------------------------------------------------
check_no_scene_lifecycle() {
  local plist="$1" count
  if ! xmllint --nonet --noout "${plist}" 2>/dev/null; then
    broken_msg "${plist##*/} is not well-formed XML; this guard cannot read it."
    return 2
  fi
  count="$(xmllint --nonet --xpath \
    "count(//key[text()='UIApplicationSceneManifest'])" "${plist}" 2>/dev/null || echo 0)"
  if [[ "${count}" != "0" ]]; then
    fail_msg "${plist##*/} declares UIApplicationSceneManifest. Under the scene \
lifecycle UIKit stops calling applicationWillResignActive and \
applicationDidBecomeActive on the app delegate entirely — they are replaced by \
sceneWillResignActive/sceneDidBecomeActive on a scene delegate — so the blur \
code compiles, reads correctly, and runs never. If Haven is adopting scenes \
(a Flutter template upgrade can do this on its own), move the blur to the scene \
delegate and re-point this guard at it."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# check_promise_still_made <l10n-dir>          — link 8
#
# Two halves that cover different ground; see link 8 in the header for why.
#
#   ALL THIRTEEN LOCALE ARBs: the key exists and is non-empty, and the set is
#   still thirteen strong. Presence, not wording — a translation SOFTENED is not
#   detectable here and is not claimed to be; a translation deleted, emptied or
#   whitespaced out is.
#
#   app_en.arb ALONE: the value still names Android, iPhone/iOS and the blur.
#   English-only, because every translation legitimately re-words all three.
# ---------------------------------------------------------------------------
check_promise_still_made() {
  local dir="$1" fail=0 broken=0
  local arbs=() f

  for f in "${dir}"/app_*.arb; do
    [[ -f "${f}" ]] && arbs+=("${f}")
  done
  LOCALE_ARB_COUNT="${#arbs[@]}"

  local en_seen=0 en_value='' locale value empty=()
  for f in "${arbs[@]}"; do
    if ! jq -e . "${f}" >/dev/null 2>&1; then
      broken_msg "${f##*/} is not valid JSON; this guard cannot read it."
      broken=1
      continue
    fi
    value="$(jq -r '.privacyWhatOthersSeeScreenshots // ""' "${f}")"
    locale="${f##*/app_}"
    if [[ "${f##*/}" == 'app_en.arb' ]]; then
      en_seen=1
      en_value="${value}"
    fi
    [[ -n "${value//[[:space:]]/}" ]] || empty+=("${locale%.arb}")
  done
  (( broken == 0 )) || return 2

  if (( ${#arbs[@]} < LOCALE_ARB_FLOOR )); then
    fail_msg "only ${#arbs[@]} locale ARBs under ${dir}, and this guard says — \
in its own header and in the failure messages above — that the app-switcher blur \
is promised in ${LOCALE_ARB_FLOOR} languages. A locale file deleted outright \
takes its copy of the promise with it and leaves every key-parity check happy. \
If a language is really being dropped, drop it in LOCALE_ARB_FLOOR and in the \
wording that constant pins, in the same commit."
    fail=1
  fi
  if (( ${#empty[@]} > 0 )); then
    fail_msg "privacyWhatOthersSeeScreenshots is missing or empty in: \
${empty[*]}. Haven tells users in every language it ships that the iPhone \
app-switcher preview is blurred; a locale where that sentence has quietly gone \
is a locale where the iOS half of this promise is no longer made at all, and no \
English review would ever see it."
    fail=1
  fi

  # The one anti-vacuity floor, covering both ways of arriving with nothing to
  # read: a directory with no ARBs at all reaches it too, since an empty set
  # contains no app_en.arb either. An earlier draft had a separate refusal for
  # the empty set; it returned the same verdict on the same input, so no
  # fixture could tell the two apart and the second one was deleted.
  if (( en_seen == 0 )); then
    broken_msg "no app_en.arb under ${dir} (${#arbs[@]} locale ARB(s) found), so \
the structural half of this check — Android + iPhone/iOS + blur — has nothing to \
read. A check with no subject certifies nothing: refusing to report a verdict."
    return 2
  fi
  # Skipped when English is empty: that is already reported above, and the token
  # list would otherwise repeat it as three separate missing words.
  if [[ -n "${en_value//[[:space:]]/}" ]]; then
    local missing=()
    grep -qi 'android' <<<"${en_value}" || missing+=('Android')
    grep -qiE 'iphone|ios' <<<"${en_value}" || missing+=('iPhone/iOS')
    grep -qi 'blur' <<<"${en_value}" || missing+=('the blur')
    if (( ${#missing[@]} > 0 )); then
      fail_msg "app_en.arb's privacyWhatOthersSeeScreenshots no longer mentions: \
${missing[*]}. The claim is asymmetric on purpose — Android blocks capture \
everywhere, iPhone only blurs the switcher preview — and its @description forbids \
flattening the two platforms into one sentence. Value now: \"${en_value}\""
      fail=1
    fi
  fi

  (( fail == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state, no toolchain.
#
# One mutation per CHECK — not per link, which is coarser than the checks are
# and leaves branches sharing a fixture that only ever fails for the other
# one's reason — each of them an edit that leaves the file compiling and
# reading correctly, plus both false-positive directions (prose that names every
# token is not code; code that happens to contain a brace in a string literal is
# still one method) and the anti-vacuity floors (a missing anchor, either
# runaway slice, and an ARB set with nothing in it are failures, never passes).
#
# Each fixture must trip the check it is NAMED after. That is not bookkeeping: a
# fixture that fails for the neighbouring link's reason reports coverage of a
# check nothing exercises, and the check it was supposed to pin can then be
# deleted with the suite still green.
#
# The number of them is pinned by EQUALITY below. A printed count is not an
# assertion: until it was compared with something, fixtures could go — to an
# edit, to a conflict resolved by keeping one side — and the suite still printed
# "OK: self-test passed" over whatever was left.
# ---------------------------------------------------------------------------
self_test() {
  # Bump this in the SAME commit that adds or removes a fixture. Equality, not a
  # floor: a floor lets deletions hide under the slack, which is exactly how the
  # previous version of this suite could lose cases silently.
  local -r SELF_TEST_FIXTURES=50
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # The same preconditions main() enforces. Without them the plist and ARB
  # fixtures report "want rc=0, got rc=2" and read as a broken guard, when what
  # is actually missing is a package.
  command -v xmllint >/dev/null 2>&1 || misconfig "xmllint (libxml2-utils) is required to run the self-test"
  command -v jq >/dev/null 2>&1 || misconfig "jq is required to run the self-test"

  _record() {
    local label="$1" want="$2" got="$3"
    checked=$(( checked + 1 ))
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _swift() { # _swift <label> <want-rc> <whole-file>
    local got=0
    printf '%s' "$3" >"${tmp}/AppDelegate.swift"
    ( check_blur_lifecycle "${tmp}/AppDelegate.swift" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  # Most mutations are a one-line edit to the ADD method, so they are supplied
  # as a replacement for that method alone and re-assembled here. The explicit
  # newline is load-bearing: `$(...)` strips the trailing one, which would run
  # the add method's closing brace into the next signature and make several
  # fixtures below fail for a reason other than the mutation they carry.
  _add_case() { # _add_case <label> <want-rc> <replacement-add-method>
    _swift "$1" "$2" "${head}$3
${rem}"
  }

  _plist() { # _plist <label> <want-rc> <inner-xml>
    local got=0
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>' \
      "$3" >"${tmp}/Info.plist"
    ( check_no_scene_lifecycle "${tmp}/Info.plist" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  # The thirteen locales Haven ships. The ARB fixtures write a full set every
  # time, so the floor is live in all of them rather than resting on one
  # fixture that could rot on its own.
  local locales=(ar de en es fa fr hi ja ne pt ru tr ur)
  # A stand-in translation carrying NONE of the three English tokens. That is
  # the point of it: the fixtures that pass with this in twelve files are what
  # prove the token half is English-only and not a tax on translators.
  local translated='{"privacyWhatOthersSeeScreenshots": "これは端末によって異なります。アンドロイドでは全面的に禁止し、アイフォーンでは切替画面の見本をぼかします。"}'
  local claim_en='{"privacyWhatOthersSeeScreenshots": "This depends on your phone. On Android, Haven blocks screenshots and screen recording everywhere in the app. On iPhone it cannot: Haven blurs the app-switcher preview, but a member can still capture what is on screen."}'

  _write_l10n() { # _write_l10n <en-json> <locale>... — writes a whole ARB set
    local en="$1" loc
    shift
    rm -rf "${tmp}/l10n"
    mkdir -p "${tmp}/l10n"
    for loc in "$@"; do
      if [[ "${loc}" == 'en' ]]; then
        printf '%s' "${en}" >"${tmp}/l10n/app_en.arb"
      else
        printf '%s' "${translated}" >"${tmp}/l10n/app_${loc}.arb"
      fi
    done
  }

  _arb() { # _arb <label> <want-rc> <en-json> [<locale> <that-locale's-json>]
    local got=0
    _write_l10n "$3" "${locales[@]}"
    (( $# < 5 )) || printf '%s' "$5" >"${tmp}/l10n/app_$4.arb"
    ( check_promise_still_made "${tmp}/l10n" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _arb_set() { # _arb_set <label> <want-rc> <locale>... — a set of another size
    local label="$1" want="$2" got=0
    shift 2
    _write_l10n "${claim_en}" "$@"
    ( check_promise_still_made "${tmp}/l10n" ) >/dev/null 2>&1 || got=$?
    _record "${label}" "${want}" "${got}"
  }

  # The committed shape, reused as the base for every mutation below.
  local head='@objc class AppDelegate: FlutterAppDelegate {
  private var privacyBlurView: UIVisualEffectView?
'
  local add='  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }
'
  local rem='  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}'

  log "self-test: iOS app-switcher blur"

  # (1) Positive first: a guard hard-coded to fail passes every negative
  #     fixture below and looks perfect.
  _swift 'the committed implementation passes' 0 "${head}${add}${rem}"

  # -- link 1: the anchors ---------------------------------------------------
  _swift 'a renamed AppDelegate class FAILS' 1 \
"@objc class RunnerDelegate: FlutterAppDelegate {
  private var privacyBlurView: UIVisualEffectView?
${add}${rem}"
  _swift 'a deleted privacyBlurView property FAILS' 1 \
"@objc class AppDelegate: FlutterAppDelegate {
  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
  }
}"

  # -- link 2: the callback that runs before the switcher renders ------------
  # The first two both land on the "no applicationWillResignActive" branch, and
  # they are not the same fixture: this one leaves a textbook-correct blur
  # installation in the file, in the wrong callback. It fails because the checks
  # are bound to ONE method rather than to the file — which is the property the
  # slicing note in the header is about, and which a whole-file grep would lose
  # while still passing the next fixture.
  _add_case 'a blur installed only in applicationDidEnterBackground FAILS' 1 \
'  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }'
  _swift 'no applicationWillResignActive at all FAILS' 1 "${head}${rem}"
  # "and ONLY there": a SECOND install site, added belt-and-braces, is the edit
  # that reads as extra safety and is not. It touches no privacyBlurView and
  # removes nothing, so the exclusivity scan for UIVisualEffectView is the only
  # thing between it and a pass.
  _swift 'a second install site in applicationDidEnterBackground FAILS' 1 \
"${head}${add}  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    let extra = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    window?.addSubview(extra)
  }
${rem}"

  # -- link 3: it covers the window -----------------------------------------
  # Four ways to lose the geometry, four branches, four fixtures: never set at
  # all, set to the wrong thing, set correctly and then overwritten, and set
  # correctly and then narrowed through a component.
  _add_case 'a frame that is never set FAILS' 1 \
    "$(grep -v 'blur.frame' <<<"${add}")"
  _add_case 'a zero frame FAILS' 1 \
    "$(sed 's/blur.frame = window.bounds/blur.frame = .zero/' <<<"${add}")"
  # The fixture above REPLACES the pinned line, so a presence grep catches it and
  # the every-assignment rule goes untested. These two leave `blur.frame =
  # window.bounds` exactly where it is and undo it on the following line — the
  # first wholesale, the second through a component, which is the same edit one
  # accessor further down.
  _add_case 'a frame overwritten on the next line FAILS' 1 \
    "$(sed 's/^    blur.autoresizingMask/    blur.frame = .zero\n    blur.autoresizingMask/' <<<"${add}")"
  _add_case 'a frame narrowed through one of its components FAILS' 1 \
    "$(sed 's/^    blur.autoresizingMask/    blur.frame.size = .zero\n    blur.autoresizingMask/' <<<"${add}")"
  _add_case 'a dropped autoresizing mask FAILS' 1 \
    "$(grep -v 'autoresizingMask' <<<"${add}")"
  _add_case 'adding to the root view controller instead of the window FAILS' 1 \
    "$(sed 's/window.addSubview(blur)/window.rootViewController?.view.addSubview(blur)/' <<<"${add}")"
  # Z-order, which is the link's third clause and the one with no visible
  # symptom: this mutation leaves the overlay installed, sized to the window,
  # `.systemMaterial`, unconditional and correctly removed — and underneath the
  # Flutter view, so the switcher card shows the map. Every other check here
  # still reads as satisfied.
  _add_case 'the blur sent to the back of the window FAILS' 1 \
    "$(sed 's/^    privacyBlurView = blur/    window.sendSubviewToBack(blur)\n    privacyBlurView = blur/' <<<"${add}")"
  _add_case 'an add that never stores the handle FAILS' 1 \
    "$(grep -v 'privacyBlurView = blur' <<<"${add}")"

  # -- link 4: a real blur ---------------------------------------------------
  _add_case 'effect: nil FAILS' 1 \
    "$(sed 's/UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))/UIVisualEffectView(effect: nil)/' <<<"${add}")"
  _add_case 'an alpha-0 overlay FAILS' 1 \
    "$(sed 's/    window.addSubview(blur)/    blur.alpha = 0\n    window.addSubview(blur)/' <<<"${add}")"
  # The same two levers one level down, where a blacklist of VIEW properties
  # never looks: `alpha` has an exact CALayer twin and a geometry twin, and a
  # scan that names only `alpha`/`isHidden` reads as though it covered both.
  _add_case 'a layer-level opacity FAILS' 1 \
    "$(sed 's/    window.addSubview(blur)/    blur.layer.opacity = 0\n    window.addSubview(blur)/' <<<"${add}")"
  _add_case 'a scale-to-zero transform FAILS' 1 \
    "$(sed 's/    window.addSubview(blur)/    blur.transform = CGAffineTransform(scaleX: 0, y: 0)\n    window.addSubview(blur)/' <<<"${add}")"
  _add_case 'a swap to an ultra-thin material FAILS' 1 \
    "$(sed 's/\.systemMaterial/.systemUltraThinMaterial/' <<<"${add}")"

  # -- link 5: the add is unconditional -------------------------------------
  _add_case 'an extra guard conjunct FAILS' 1 \
    "$(sed 's/privacyBlurView == nil else/privacyBlurView == nil, !Self.blurDisabled else/' <<<"${add}")"
  # A SECOND guard statement is a different edit from a second conjunct on the
  # first one, and it takes a different branch: the conjunct scan never runs
  # once there is more than one guard, so without this fixture the count branch
  # is pinned by nothing.
  _add_case 'a second guard statement FAILS' 1 \
    "$(sed 's/    let blur = /    guard !Self.blurDisabled else { return }\n    let blur = /' <<<"${add}")"
  _add_case 'an early return before the add FAILS' 1 \
    "$(sed 's/    let blur = /    if ProcessInfo.processInfo.arguments.contains("-uitest") { return }\n    let blur = /' <<<"${add}")"
  # The same kill switch one formatter run away. The one-line form above sits at
  # the method's own statement depth; expanding the brace onto its own line puts
  # the `return` a level down, where a scan bound to the statement list does not
  # look — and expanding it is exactly what swift-format does to the line above.
  # This is the fixture that keeps the return scan depth-aware: neuter the depth
  # and the one-line fixture stays green while this one goes red.
  _add_case 'a multi-line kill switch FAILS' 1 \
'  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = window, privacyBlurView == nil else { return }
    if Self.blurDisabled {
      return
    }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }'
  _add_case 'the add nested inside an if FAILS' 1 \
'  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if shouldBlur {
      window.addSubview(blur)
    }
    privacyBlurView = blur
  }'
  # The add and the store are two counted checks. Nesting both at once trips
  # both, which pins neither: delete either check and such a fixture stays red
  # on the other. So each is nested alone — above, the install is conditional
  # while the handle is always stored; below, the blur is installed in every
  # case and only the handle goes missing.
  _add_case 'a store nested inside an if FAILS' 1 \
'  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    if shouldRetain {
      privacyBlurView = blur
    }
  }'

  # -- link 6: removal only on become-active, handle restored ---------------
  # Five branches live here — the callback exists, it removes at its own
  # statement depth, it re-nils, it takes no conditions, and nothing else in the
  # file removes the view — and one fixture that trips four of them at once
  # proves none of them: three could be deleted and it would stay red for the
  # fourth. One fixture each, so each branch is the ONLY thing between its
  # fixture and a pass.
  #
  # The first pins an OUTCOME rather than a branch, and deliberately: a file with
  # no applicationDidBecomeActive is never certified, and it is refused twice
  # over — by the missing-method branch, and, if that branch were ever deleted,
  # by the removal checks reading an empty slice. Both roads end at rc=1, which
  # is the property the user's blur depends on.
  _swift 'no applicationDidBecomeActive at all FAILS' 1 "${head}${add}}"
  _swift 'a removal nested in an if FAILS' 1 \
"${head}${add}  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    if let blur = privacyBlurView {
      blur.removeFromSuperview()
    }
    privacyBlurView = nil
  }
}"
  _swift 'a removal that never re-nils the handle FAILS' 1 \
"${head}${add}$(grep -v 'privacyBlurView = nil' <<<"${rem}")"
  _swift 'a conditional removal FAILS' 1 \
"${head}${add}  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    guard !isLocked else { return }
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}"
  _swift 'a second privacyBlurView touch point FAILS' 1 \
"${head}${add}  override func applicationDidEnterBackground(_ application: UIApplication) {
    privacyBlurView = nil
  }
${rem}"
  # The removal moved to applicationWillEnterForeground, which does not fire on
  # a resign that never reached the background (Control Centre, a declined call)
  # and so strands the blur over a live app. Written positionally, without the
  # property: that is what makes it land on the removeFromSuperview exclusivity
  # scan ALONE, instead of on that scan plus the two statement-depth checks plus
  # the touch-point scan the way one fixture used to.
  _swift 'a removeFromSuperview outside applicationDidBecomeActive FAILS' 1 \
"${head}${add}  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    window?.subviews.last?.removeFromSuperview()
  }
${rem}"

  # -- false-positive directions --------------------------------------------
  # Explaining the mechanism must stay possible, or the explanation gets deleted
  # instead of the code. The prose below is written to be LOAD-BEARING in both
  # directions — neuter code_view's comment handling and this fixture goes red,
  # which an earlier draft of it did not: it named `removeFromSuperview` without
  # the parenthesis the scan keys on and `UIBlurEffect` instead of
  # `UIVisualEffectView(`, so it passed whether comments were stripped or not.
  # Now the line comments name privacyBlurView, UIVisualEffectView( and
  # removeFromSuperview() outside every permitted range, the block comment does
  # the same on the other comment syntax, and the comment INSIDE the sliced body
  # names alpha and .clear, which are scanned over the body rather than the file.
  _swift 'comments naming every banned token still pass' 0 \
"/// The blur is NOT installed in applicationDidEnterBackground: that fires too
/// late for the switcher card. privacyBlurView holds a real
/// UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)), and
/// privacyBlurView?.removeFromSuperview() runs only on become-active.
/* An earlier draft called privacyBlurView?.removeFromSuperview() from
   applicationWillEnterForeground, which does not fire on a resign that never
   reached the background. */
${head}  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = window, privacyBlurView == nil else { return }
    // Never .clear, and never alpha 0: a see-through overlay protects nothing.
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }
${rem}"

  # Swift's version of the Kotlin expression-body trap: a brace inside a string
  # literal. If the code view did not blank string contents the slice would run
  # past this method and every check above would silently widen with it.
  _add_case 'a brace inside a string literal does not move the method boundary' 0 \
    "$(sed 's|    let blur = |    NSLog("resign {")\n    let blur = |' <<<"${add}")"

  # -- anti-vacuity: a runaway slice is BROKEN, not clean --------------------
  # Two distinct runaways, and the guard has two distinct refusals. A body that
  # loses its closing brace mid-file does NOT reach EOF: the enclosing type's
  # final `}` closes the slice instead, so the slice stays brace-balanced and
  # swallows the next method whole. That is the dangerous one — it is the shape
  # that would silently widen every method-bound check into a whole-file grep —
  # and it is caught by the swallowed-signature scan, not by the EOF branch.
  _swift 'a body that loses its brace swallows the next method: BROKEN' 2 \
"${head}  override func applicationWillResignActive(_ application: UIApplication) {
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
${rem}"
  # The EOF branch is the other one: nothing follows to balance the braces, so
  # the slice runs off the end of the file. Until this fixture existed that
  # branch was never taken by any test in this suite.
  _swift 'a slice that runs off the end of the file is BROKEN' 2 \
"${head}${add}  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil"

  # -- link 7 ----------------------------------------------------------------
  _plist 'an application-lifecycle Info.plist passes' 0 \
'<key>UIMainStoryboardFile</key><string>Main</string>'
  _plist 'UIApplicationSceneManifest FAILS' 1 \
'<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>'
  # xmllint, not grep: a key inside an XML comment is not a key.
  _plist 'a commented-out scene manifest does not count' 0 \
'<!-- <key>UIApplicationSceneManifest</key> --><key>UIMainStoryboardFile</key><string>Main</string>'
  _plist 'an unparsable Info.plist is broken, not a violation' 2 \
'<key>UIMainStoryboardFile</key><string>Main'

  # -- link 8, the English half ---------------------------------------------
  # The first fixture carries a full set of twelve translations that contain
  # none of "Android", "iPhone" or "blur" in ASCII, so it also pins the half
  # that is deliberately NOT checked across locales: a translated wording must
  # never be a failure.
  _arb 'the shipped asymmetric claim, with translations that share no English token, passes' 0 \
"${claim_en}"
  _arb 'the iOS clause deleted from English FAILS' 1 \
'{"privacyWhatOthersSeeScreenshots": "On Android, Haven blocks screenshots and screen recording everywhere in the app."}'
  _arb 'the two platforms flattened into one claim FAILS' 1 \
'{"privacyWhatOthersSeeScreenshots": "Haven blurs the preview of the app whenever you switch away from it."}'
  _arb 'an unparsable English ARB is broken, not a violation' 2 \
'{"privacyWhatOthersSeeScreenshots": '

  # -- link 8, the thirteen-locale half -------------------------------------
  # This is the half the header claims and the half that was, until now, read
  # off app_en.arb alone. Each of these is a stale-translation shape: the
  # English sentence is intact and correct in the three that follow.
  #
  # The first one is English's own, and it belongs HERE rather than above:
  # app_en.arb is one of the thirteen, so a key deleted from it is caught by the
  # presence branch and never reaches the Android/iPhone/blur token branch at
  # all. Filed under the English half, it reported coverage of a check it does
  # not exercise.
  _arb 'the claim deleted from English FAILS on the presence half' 1 \
'{"privacyTitle": "Privacy"}'
  _arb 'the claim deleted from ONE translation FAILS' 1 \
"${claim_en}" fa '{"privacyTitle": "حریم خصوصی"}'
  _arb 'a translation blanked to whitespace FAILS' 1 \
"${claim_en}" tr '{"privacyWhatOthersSeeScreenshots": "   "}'
  _arb 'an unparsable TRANSLATION is broken, not a violation' 2 \
"${claim_en}" ru '{"privacyWhatOthersSeeScreenshots": '
  # A locale file deleted outright takes its copy of the promise with it, and
  # leaves nothing behind for a per-key check to notice.
  _arb_set 'a dropped locale FAILS' 1 ar de en es fa fr hi ja ne pt ru tr
  # Anti-vacuity. Both of these land on the SAME refusal — an empty directory
  # has no app_en.arb either — and they are both kept because they are two
  # different mistakes a caller makes: pointing this guard at the wrong
  # directory, and deleting the template. Neither may report a clean tree. The
  # second set is thirteen strong on purpose, so it clears the floor and fails
  # only on the missing template.
  _arb_set 'an l10n directory with no ARBs at all is BROKEN' 2
  _arb_set 'a set with no app_en.arb is BROKEN, not a pass' 2 \
    ar de es fa fr hi ja ne pt ru tr ur zh

  if (( checked != SELF_TEST_FIXTURES )); then
    fail_msg "the self-test ran ${checked} fixtures; SELF_TEST_FIXTURES pins \
${SELF_TEST_FIXTURES}. Every check in this guard is backed by exactly one \
fixture, so a lost fixture is a check that has stopped being tested while the \
suite still reports a pass. If a fixture was added or removed deliberately, say \
so in SELF_TEST_FIXTURES in the same commit."
    fails=1
  fi
  if (( fails )); then
    fail_msg "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (${checked} fixtures, pinned)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  command -v xmllint >/dev/null 2>&1 || misconfig "xmllint (libxml2-utils) is required"
  command -v jq >/dev/null 2>&1 || misconfig "jq is required"

  local swift="${REPO_ROOT}/haven/ios/Runner/AppDelegate.swift"
  local plist="${REPO_ROOT}/haven/ios/Runner/Info.plist"
  local l10n="${REPO_ROOT}/haven/lib/l10n"
  local path
  for path in "${swift}" "${plist}" "${l10n}/app_en.arb"; do
    [[ -f "${path}" ]] || misconfig "${path} not found"
  done

  local status=0 broken=0 rc
  # Every check runs even after one fails, so a red run names every broken link
  # rather than the first — the same reason repo-guards.yml runs its steps under
  # `if: !cancelled()`.
  run_check() {
    rc=0
    "$@" || rc=$?
    if (( rc == 2 )); then broken=1; elif (( rc != 0 )); then status=1; fi
  }
  run_check check_blur_lifecycle "${swift}"
  run_check check_no_scene_lifecycle "${plist}"
  run_check check_promise_still_made "${l10n}"

  if (( broken )); then
    exit 2
  fi
  if (( status != 0 )); then
    fail_msg "the iOS app-switcher blur no longer backs \
privacyWhatOthersSeeScreenshots (see above)."
    exit 1
  fi
  log "OK: the app-switcher blur is installed on applicationWillResignActive, \
covers the window with a real blur, is removed and re-armed only on \
applicationDidBecomeActive, the app still uses the application lifecycle, the \
promise is still made in all ${LOCALE_ARB_COUNT} locales scanned, and the \
English wording still names both platforms and the blur."
  exit 0
}

main "$@"
