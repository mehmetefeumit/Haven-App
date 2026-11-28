#!/usr/bin/env bash
# CI guard: the iOS app-switcher privacy blur.
#
# iPhone cannot block screenshots, so what Haven does there is blur the
# app-switcher preview: a few lines of `SceneDelegate.swift` — a
# `UIVisualEffectView` added at connect and on resign, and removed on
# become-active. Android's
# half is a WINDOW flag pinned by `check_flag_secure_app_wide.sh`. Until this
# guard existed the iOS half was backed by nothing at all: delete those lines
# and every other gate in the repo stays green.
#
# There is no runtime proof available here: the repo-guards job has no Xcode, no
# Simulator, and the OS-captured snapshot is not observable from inside the
# process even when there is one. So this pins, statically, every link the
# blur rests on. It is a UNION — each link can be removed on its own, each
# such edit reads locally reasonable in a diff, and each leaves the others
# looking correct:
#
#   1. THE ANCHORS EXIST. `SceneDelegate: FlutterSceneDelegate` and the
#      `privacyBlurView` property. A guard that cannot find its subject must
#      fail, never pass for want of something to scan. The blur itself is built
#      in ONE place, `coverWithPrivacyBlur()`, which links 3-5 read; links 2
#      and 9 pin its two callers.
#
#   2. ADDED ON THE PRE-SNAPSHOT CALLBACK. The blur is installed from
#      `sceneWillResignActive`, which is correct and is NOT
#      interchangeable with `sceneDidEnterBackground`. While the app switcher
#      is open showing Haven's card, the scene is *inactive but still
#      foreground* — `didEnterBackground` has not been called yet — and the same
#      is true of the Control Centre / Notification Centre pull-down and an
#      incoming call. Only `willResignActive` covers those, and it also strictly
#      precedes `didEnterBackground`, so it covers the snapshot too. Moving the
#      add "down" to `didEnterBackground` is the tidy-looking edit that silently
#      un-blurs the very screen the copy names. The call sits at the method's
#      own statement depth and the method has no `return` at any depth, for
#      link 5's reason. The method calls `super` at its own statement depth, as
#      its twin in link 6 does: FlutterSceneDelegate forwards each callback to
#      the engine and the plugins, so an override that drops it keeps the blur
#      and leaves Dart's lifecycle a state behind.
#
#   3. IT COVERS THE WINDOW — TARGET, GEOMETRY AND STACKING. Added to the
#      scene's `window` itself (not to the root view controller's view, which a
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
#      `sceneDidBecomeActive` is the only method allowed to touch the view,
#      unconditionally — no `return` at any depth, for the reason link 5 gives —
#      and it must BOTH `removeFromSuperview()` and re-nil `privacyBlurView`.
#      Two distinct failures live here. `sceneWillEnterForeground` does not fire
#      on a resign that never reached the background (Control Centre, a declined
#      call), so a removal moved there strands the blur over a live app. And
#      dropping the `= nil` leaves a stale non-nil property, so link 5's
#      re-entrancy check is false forever after: the app is protected on the
#      FIRST backgrounding and on no later one, with nothing on screen ever
#      looking wrong.
#
#   7. UIKIT CALLS THESE CALLBACKS. Info.plist's top-level
#      `UIApplicationSceneManifest` routes the application role's one scene
#      configuration to `$(PRODUCT_MODULE_NAME).SceneDelegate`. Without the
#      manifest an Xcode 27 build does not launch; with `FlutterSceneDelegate`
#      or any other class named, or with an
#      `application(_:configurationForConnecting:options:)` or a `delegateClass`
#      that picks the delegate in code, UIKit calls another object's callbacks
#      and links 1-6 compile and execute never. This is the exact analogue of
#      the Android guard's `android:name` link. Read with xmllint, so a key
#      inside an XML comment is not mistaken for a live one.
#
#   8. NO BLUR LEFT ON THE APP DELEGATE. Under the scene lifecycle UIKit never
#      calls the app delegate's `applicationWillResignActive`,
#      `applicationDidBecomeActive`, `applicationWillEnterForeground` or
#      `applicationDidEnterBackground`, so a blur — or any of those overrides —
#      left in AppDelegate.swift reads as protection and runs never.
#
#   9. COVERED FROM CONNECT. `scene(_:willConnectTo:options:)` calls
#      `coverWithPrivacyBlur()` at its own statement depth, after
#      `self.window = window` (the cover binds it) and after
#      `window.makeKeyAndVisible()` (which installs the root controller's
#      view), with no `return` but its UIWindowScene guard. AppDelegate keeps
#      one controller for the process, so a scene iOS reconnects in the
#      background shows that controller's last frame, never resigns active, and
#      can be snapshotted before it is ever active; sceneDidBecomeActive takes
#      the cover off. Not under an `activationState` test: UIKit reports the
#      same state at connect for a background launch and a user's.
#
# THE SLICING HAZARD, DELIBERATELY HANDLED. Checks 2-6 and 9 are bound to ONE method
# body each, not to the file, because "somewhere in SceneDelegate.swift" is not
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
# Pure bash + coreutils + xmllint. No Xcode, no toolchain.
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
#      Info.plist, a missing input file, a failed self-test)

set -Eeuo pipefail
LITERAL_FREE="$(cat "$(dirname "${BASH_SOURCE[0]}")/lib/literal_free.awk")"
readonly LITERAL_FREE

SCRIPT_NAME="check_ios_privacy_blur"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
  awk -v sig="$1" "${LITERAL_FREE}"'
    !started && index($0, sig) > 0 { started = 1; start = NR }
    started {
      lfree = literal_free($0); o = gsub(/[{]/, "&", lfree); c = gsub(/[}]/, "&", lfree)
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
  awk "${LITERAL_FREE}"'
    {
      d = depth
      lfree = literal_free($0); o = gsub(/[{]/, "&", lfree); c = gsub(/[}]/, "&", lfree)
      depth += o - c
      if (d == 1) {
        t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t != "}") print $0
      }
    }'
}

# ---------------------------------------------------------------------------
# check_blur_lifecycle <SceneDelegate.swift>   — links 1-6
# ---------------------------------------------------------------------------
check_blur_lifecycle() {
  local swift="$1" fail=0
  local code
  code="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${code}'" RETURN
  code_view "${swift}" >"${code}"

  # --- link 1: the anchors -------------------------------------------------
  if ! grep -qE 'class +SceneDelegate *: *FlutterSceneDelegate\b' "${code}"; then
    fail_msg "no \`class SceneDelegate: FlutterSceneDelegate\` in ${swift##*/}. \
The app-switcher blur is pinned to that class; if it was renamed or moved, move \
this guard with it — a guard with no subject certifies nothing."
    return 1
  fi
  local decl_line
  decl_line="$(grep -nE '(private +)?var +privacyBlurView *: *UIVisualEffectView\?' \
    "${code}" | head -1 | cut -d: -f1)"
  if [[ -z "${decl_line}" ]]; then
    fail_msg "${swift##*/} has no \`privacyBlurView: UIVisualEffectView?\` property. \
Nothing else in this app blurs the iPhone app-switcher preview; if the blur is \
really going, retire this guard in the same commit."
    return 1
  fi

  # --- the four bodies, structure-bound ------------------------------------
  # The connect slice starts mid-signature, at its `willConnectTo` label: the
  # `func scene(` line names no callback, and the super call spells the label
  # with a colon, so this substring is the signature's alone.
  local add_range rem_range resign_range conn_range
  add_range="$(method_range 'func coverWithPrivacyBlur(' "${code}")"
  resign_range="$(method_range 'func sceneWillResignActive(' "${code}")"
  conn_range="$(method_range 'willConnectTo session' "${code}")"
  rem_range="$(method_range 'func sceneDidBecomeActive(' "${code}")"

  if [[ -z "${resign_range}" ]]; then
    fail_msg "${swift##*/} has no sceneWillResignActive. That is the only \
callback that runs before iOS renders Haven in the app switcher AND before the \
Control-Centre/incoming-call peek; sceneDidEnterBackground has not fired \
while the switcher card is on screen."
    fail=1
  fi
  if [[ -z "${add_range}" ]]; then
    fail_msg "${swift##*/} has no coverWithPrivacyBlur(), the one method that \
installs the blur for both of its callers."
    fail=1
  fi
  if [[ -z "${conn_range}" ]]; then
    fail_msg "${swift##*/} has no scene(_:willConnectTo:options:), so nothing \
covers a scene that connects in the background (link 9)."
    fail=1
  fi
  if [[ -z "${rem_range}" ]]; then
    fail_msg "${swift##*/} has no sceneDidBecomeActive, so nothing takes \
the blur back off: the app returns to the foreground behind an opaque overlay."
    fail=1
  fi
  (( fail == 0 )) || return 1
  if [[ "${add_range}" == *EOF || "${rem_range}" == *EOF || "${resign_range}" == *EOF \
    || "${conn_range}" == *EOF ]]; then
    broken_msg "a method body in ${swift##*/} never closes (unbalanced braces in \
the code view: add=${add_range}, remove=${rem_range}, resign=${resign_range}, \
connect=${conn_range}). This guard slices ONE \
method at a time on purpose, so a runaway slice would silently widen every check \
below into a whole-file grep. Refusing to report a verdict."
    return 2
  fi

  local add_start add_end rem_start rem_end add_body rem_body add_top rem_top
  local resign_start resign_end conn_start conn_end resign_body conn_body resign_top conn_top
  read -r add_start add_end <<<"${add_range}"
  read -r rem_start rem_end <<<"${rem_range}"
  read -r resign_start resign_end <<<"${resign_range}"
  read -r conn_start conn_end <<<"${conn_range}"
  add_body="$(sed -n "${add_start},${add_end}p" "${code}")"
  rem_body="$(sed -n "${rem_start},${rem_end}p" "${code}")"
  resign_body="$(sed -n "${resign_start},${resign_end}p" "${code}")"
  conn_body="$(sed -n "${conn_start},${conn_end}p" "${code}")"
  add_top="$(top_level <<<"${add_body}")"
  rem_top="$(top_level <<<"${rem_body}")"
  resign_top="$(top_level <<<"${resign_body}")"
  conn_top="$(top_level <<<"${conn_body}")"

  # The runaway that matters is not the one that reaches EOF — it is the one
  # that stays brace-BALANCED by swallowing the next method, which happens the
  # moment a body loses its own closing brace: the enclosing type's final `}`
  # closes the slice instead, and every check below quietly becomes a whole-file
  # grep that passes on a file where the method it names has no end. A method
  # signature inside a method's own statement list is the signature of that.
  local swallowed
  swallowed="$(grep -E '\bfunc\b' \
    <<<"${add_top}"$'\n'"${rem_top}"$'\n'"${resign_top}"$'\n'"${conn_top}" || true)"
  if [[ -n "${swallowed}" ]]; then
    broken_msg "a sliced method body in ${swift##*/} contains another method \
signature: ${swallowed//$'\n'/ | }. The braces do not balance where they should, \
so the slice covers more than the method it is named after and this guard would \
be checking the wrong text. Refusing to report a verdict."
    return 2
  fi

  # --- links 2 + 6: super, at the method's own statement depth -------------
  # FlutterSceneDelegate forwards each scene callback to the engine and the
  # plugins; an override without super, or with super inside an `if`, keeps the
  # blur and leaves Dart's lifecycle a state behind.
  if ! grep -qE '^[[:space:]]*super\.sceneWillResignActive\(' <<<"${resign_top}"; then
    fail_msg "sceneWillResignActive does not call super.sceneWillResignActive at \
its own statement depth. FlutterSceneDelegate forwards the callback to the engine \
and the plugins: without it Dart never hears the scene go inactive."
    fail=1
  fi
  if ! grep -qE '^[[:space:]]*super\.sceneDidBecomeActive\(' <<<"${rem_top}"; then
    fail_msg "sceneDidBecomeActive does not call super.sceneDidBecomeActive at its \
own statement depth. FlutterSceneDelegate forwards the callback to the engine and \
the plugins: without it Dart never hears the scene come back."
    fail=1
  fi

  # --- link 2: the resign covers, unconditionally ---------------------------
  # At the method's own statement depth, and no `return` at any depth, as on
  # become-active.
  local n_call_top
  n_call_top="$(grep -cE '^[[:space:]]*(self\.)?coverWithPrivacyBlur\(\)[[:space:]]*$' <<<"${resign_top}" || true)"
  if (( n_call_top == 0 )); then
    fail_msg "sceneWillResignActive does not call coverWithPrivacyBlur() at its \
own statement depth, so nothing blurs the switcher card or the Control-Centre \
peek — a call nested in an \`if\`, a closure or a \`#if\` branch is an off \
switch with none of the shape of one."
    fail=1
  fi
  if grep -qE '\breturn\b' <<<"${resign_body}"; then
    fail_msg "sceneWillResignActive returns early. It takes no conditions: \
whatever follows such a return is skipped in exactly the case that added it."
    fail=1
  fi

  # --- link 9: a scene is covered from the moment it connects ---------------
  n_call_top="$(grep -cE '^[[:space:]]*(self\.)?coverWithPrivacyBlur\(\)[[:space:]]*$' <<<"${conn_top}" || true)"
  if (( n_call_top == 0 )); then
    fail_msg "scene(_:willConnectTo:options:) does not call coverWithPrivacyBlur() \
at its own statement depth (link 9). A scene iOS reconnects in the background \
shows the kept controller's last frame, and it never resigns active, so nothing \
else covers it before iOS can snapshot it. A call under an activationState test \
is no cover: a background connect and a user's look alike here."
    fail=1
  fi
  local l_cover l_win l_shown
  l_cover="$(grep -nE '^[[:space:]]*(self\.)?coverWithPrivacyBlur\(\)' <<<"${conn_top}" | head -1 | cut -d: -f1)"
  l_win="$(grep -nE '^[[:space:]]*self\.window *= *window[[:space:]]*$' <<<"${conn_top}" | head -1 | cut -d: -f1)"
  l_shown="$(grep -nE '^[[:space:]]*window\.makeKeyAndVisible\(\)' <<<"${conn_top}" | head -1 | cut -d: -f1)"
  if [[ -n "${l_cover}" ]] && [[ -z "${l_win}" ]] || (( ${l_cover:-0} > 0 && ${l_cover:-0} < ${l_win:-0} )); then
    fail_msg "scene(_:willConnectTo:options:) covers the window before it assigns \
self.window = window (link 9). coverWithPrivacyBlur() binds self.window and \
does nothing while it is nil."
    fail=1
  fi
  if [[ -n "${l_cover}" ]] && [[ -z "${l_shown}" ]] || (( ${l_cover:-0} > 0 && ${l_cover:-0} < ${l_shown:-0} )); then
    fail_msg "scene(_:willConnectTo:options:) covers the window before \
window.makeKeyAndVisible() (link 9). The window installs its root controller's \
view when it is shown, and a blur added first can end up beneath the frame it \
exists to cover."
    fail=1
  fi
  local conn_return
  conn_return="$(awk "${LITERAL_FREE}"'
    function word(s, w) { return s ~ "(^|[^A-Za-z0-9_])" w "([^A-Za-z0-9_]|$)" }
    {
      d = depth
      lfree = literal_free($0); o = gsub(/[{]/, "&", lfree); c = gsub(/[}]/, "&", lfree)
      depth += o - c
      t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (word($0, "return") && !(d == 1 && t == "guard let windowScene = scene as? UIWindowScene else { return }")) print
    }' <<<"${conn_body}")"
  if [[ -n "${conn_return}" ]]; then
    fail_msg "scene(_:willConnectTo:options:) returns early beyond its \
UIWindowScene guard: ${conn_return//$'\n'/ | } (link 9). Every connect that \
takes it shows the kept controller uncovered."
    fail=1
  fi

  # --- link 4: a real blur, pinned as a constant in both directions --------
  local add_squashed
  add_squashed="$(tr -d ' \t\n' <<<"${add_body}")"
  if [[ "${add_squashed}" != *'UIVisualEffectView(effect:UIBlurEffect(style:.systemMaterial))'* ]]; then
    fail_msg "coverWithPrivacyBlur() does not build \
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
    fail_msg "coverWithPrivacyBlur() manipulates the overlay's visibility, \
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
    fail_msg "coverWithPrivacyBlur() does not add the blur to the WINDOW. \
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
      fail_msg "coverWithPrivacyBlur() assigns a frame that is not \
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
    fail_msg "coverWithPrivacyBlur() re-orders the window's subviews: \
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
    fail_msg "coverWithPrivacyBlur() never stores the view in \
privacyBlurView, so sceneDidBecomeActive has no handle to remove: the blur \
is added once and stays over the live app forever."
    fail=1
  fi

  # --- link 5: the add is unconditional ------------------------------------
  local guard_lines guard_count
  guard_lines="$(grep -E '\bguard\b' <<<"${add_top}" || true)"
  guard_count=0
  [[ -n "${guard_lines}" ]] && guard_count="$(grep -c '' <<<"${guard_lines}")"
  if (( guard_count > 1 )); then
    fail_msg "coverWithPrivacyBlur() has ${guard_count} guard statements. \
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
        fail_msg "coverWithPrivacyBlur()'s guard carries an unrecognised \
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
  stray_return="$(awk "${LITERAL_FREE}"'
    function word(s, w) { return s ~ "(^|[^A-Za-z0-9_])" w "([^A-Za-z0-9_]|$)" }
    {
      d = depth
      lfree = literal_free($0); o = gsub(/[{]/, "&", lfree); c = gsub(/[}]/, "&", lfree)
      depth += o - c
      if (word($0, "return") && !(d == 1 && word($0, "guard"))) print
    }' <<<"${add_body}")"
  if [[ -n "${stray_return}" ]]; then
    fail_msg "coverWithPrivacyBlur() returns early outside its guard: \
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
    fail_msg "coverWithPrivacyBlur() adds the blur below its own statement \
depth — nested in an \`if\`, a closure or a \`#if\` branch. A conditional add is \
an off switch with none of the shape of one: every line still reads as \
protection, and nothing is installed in whichever case the condition excludes."
    fail=1
  fi
  n_body="$(grep -cE 'privacyBlurView *= *[A-Za-z_]' <<<"${add_body}" || true)"
  n_top="$(grep -cE 'privacyBlurView *= *[A-Za-z_]' <<<"${add_top}" || true)"
  if (( n_body != n_top )); then
    fail_msg "coverWithPrivacyBlur() stores privacyBlurView below its own \
statement depth, so the handle is only set in whichever case the enclosing \
condition allows and sceneDidBecomeActive has nothing to remove in the \
other — leaving an opaque overlay over a live app."
    fail=1
  fi

  # --- link 6: removal only on become-active, handle restored --------------
  if ! grep -qE 'privacyBlurView\??\.removeFromSuperview\(\)' <<<"${rem_top}"; then
    fail_msg "sceneDidBecomeActive does not remove the blur at its own \
statement depth (a removal nested in an \`if\` is a removal that can be skipped)."
    fail=1
  fi
  if ! grep -qE 'privacyBlurView *= *nil' <<<"${rem_top}"; then
    fail_msg "sceneDidBecomeActive removes the blur but leaves \
privacyBlurView non-nil. The re-entrancy guard in coverWithPrivacyBlur() \
then sees a stale view forever: Haven is blurred on the FIRST backgrounding and \
on no later one, and nothing on screen ever looks wrong."
    fail=1
  fi
  # The whole body, not its statement list, and with no guard exception: this
  # method takes no conditions at all, so any `return` at any depth is one —
  # including the multi-line `if` that link 5 describes.
  if grep -qE '\breturn\b' <<<"${rem_body}"; then
    fail_msg "sceneDidBecomeActive returns early. The removal must be \
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
coverWithPrivacyBlur() and sceneDidBecomeActive: \
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
coverWithPrivacyBlur(). The blur is pinned there, for both of its callers; a \
second construction site is a blur none of links 3-5 reads."
    fail=1
  done < <(grep -n 'UIVisualEffectView(' "${code}" || true)

  while IFS=: read -r ln rest; do
    (( ln >= rem_start && ln <= rem_end )) && continue
    fail_msg "${swift##*/}:${ln} calls removeFromSuperview outside \
sceneDidBecomeActive, which is the only callback that means the user is \
actually looking at the app again."
    fail=1
  done < <(grep -n 'removeFromSuperview(' "${code}" || true)

  (( fail == 0 ))
}

# ---------------------------------------------------------------------------
# check_scene_manifest <Info.plist>            — link 7
# ---------------------------------------------------------------------------
check_scene_manifest() {
  local plist="$1" top role count cls
  if ! xmllint --nonet --noout "${plist}" 2>/dev/null; then
    broken_msg "${plist##*/} is not well-formed XML; this guard cannot read it."
    return 2
  fi
  # Top level only: a manifest inside another dictionary is not the app's.
  top="/plist/dict/key[.='UIApplicationSceneManifest']"
  count="$(xmllint --nonet --xpath "count(${top})" "${plist}" 2>/dev/null || echo 0)"
  if [[ "${count}" != "1" ]]; then
    fail_msg "${plist##*/} has no top-level UIApplicationSceneManifest (link 7). \
Without it an Xcode 27 build does not launch, and UIKit sends no scene callback \
to SceneDelegate, so the blur would run never."
    return 1
  fi
  role="${top}/following-sibling::*[1][self::dict]/key[.='UISceneConfigurations']\
/following-sibling::*[1][self::dict]/key[.='UIWindowSceneSessionRoleApplication']\
/following-sibling::*[1][self::array]"
  count="$(xmllint --nonet --xpath "count(${role}/*)" "${plist}" 2>/dev/null || echo 0)"
  if [[ "${count}" != "1" ]] || [[ "$(xmllint --nonet --xpath "count(${role}/dict)" \
    "${plist}" 2>/dev/null || echo 0)" != "1" ]]; then
    fail_msg "${plist##*/}'s UIApplicationSceneManifest does not carry exactly one \
UIWindowSceneSessionRoleApplication configuration (found ${count}) (link 7). \
With none UIKit has no delegate to name; with two, which one a scene gets is \
UIKit's choice, and the blur runs only in the scenes that drew SceneDelegate."
    return 1
  fi
  cls="$(xmllint --nonet --xpath \
    "string(${role}/dict/key[.='UISceneDelegateClassName']/following-sibling::*[1][self::string])" \
    "${plist}" 2>/dev/null || true)"
  # shellcheck disable=SC2016 # the build setting is literal plist text
  if [[ "${cls}" != '$(PRODUCT_MODULE_NAME).SceneDelegate' ]]; then
    fail_msg "${plist##*/}'s application scene delegate is '${cls:-absent}', not \
\$(PRODUCT_MODULE_NAME).SceneDelegate (link 7). UIKit calls the class this names: \
any other one — FlutterSceneDelegate included — gets the scene callbacks, and the \
blur in SceneDelegate.swift compiles and runs never."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# check_no_app_delegate_blur <AppDelegate.swift> <SceneDelegate.swift>
#                                              — link 8, and link 7's code bypass
# ---------------------------------------------------------------------------
check_no_app_delegate_blur() {
  local app="$1" scene="$2" fail=0 code token hits f
  code="$(code_view "${app}")"
  if ! grep -qE 'class +AppDelegate *: *FlutterAppDelegate\b' <<<"${code}"; then
    fail_msg "no \`class AppDelegate: FlutterAppDelegate\` in ${app##*/}. Link 8 is \
an absence scan over that class; with no class to scan it certifies nothing."
    return 1
  fi
  for token in 'privacyBlurView' 'UIVisualEffectView(' 'removeFromSuperview(' \
    'func applicationWillResignActive(' 'func applicationDidBecomeActive(' \
    'func applicationWillEnterForeground(' 'func applicationDidEnterBackground('; do
    hits="$(grep -nF -- "${token}" <<<"${code}" || true)"
    if [[ -n "${hits}" ]]; then
      fail_msg "${app##*/} has \`${token}\`: ${hits//$'\n'/ | } (link 8). Under the \
scene lifecycle UIKit never calls the app delegate's resign, become-active, \
foreground or background callbacks, so a blur or an override there reads as \
protection and runs never. The blur lives in SceneDelegate.swift."
      fail=1
    fi
  done
  # Link 7 in code: either of these picks the scene delegate at runtime, over
  # whatever Info.plist names.
  for f in "${app}" "${scene}"; do
    hits="$(code_view "${f}" | grep -nE 'configurationForConnecting|delegateClass' || true)"
    if [[ -n "${hits}" ]]; then
      fail_msg "${f##*/} chooses the scene configuration in code: \
${hits//$'\n'/ | } (link 7). UIKit then calls whichever delegate that code names, \
and the manifest this guard reads stops deciding where the blur runs."
      fail=1
    fi
  done
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
# still one method) and the anti-vacuity floors (a missing anchor and either
# runaway slice are failures, never passes).
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
  local -r SELF_TEST_FIXTURES=66
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # The same precondition main() enforces. Without it the plist fixtures
  # report "want rc=0, got rc=2" and read as a broken guard, when what is
  # actually missing is a package.
  command -v xmllint >/dev/null 2>&1 || misconfig "xmllint (libxml2-utils) is required to run the self-test"

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
    printf '%s' "$3" >"${tmp}/SceneDelegate.swift"
    ( check_blur_lifecycle "${tmp}/SceneDelegate.swift" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  # Most mutations are a one-line edit to the ADD method (the cover), so they
  # are supplied as a replacement for that method alone and re-assembled here. The explicit
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
    ( check_scene_manifest "${tmp}/Info.plist" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  # The committed shape, reused as the base for every mutation below.
  local hdr='class SceneDelegate: FlutterSceneDelegate {
  private var privacyBlurView: UIVisualEffectView?
'
  local conn='  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = appDelegate.flutterViewController
    self.window = window
    window.makeKeyAndVisible()
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    coverWithPrivacyBlur()
  }
'
  local resign='  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    coverWithPrivacyBlur()
  }
'
  local head="${hdr}${conn}${resign}"
  local add='  private func coverWithPrivacyBlur() {
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }
'
  local rem='  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}'

  log "self-test: iOS app-switcher blur"

  # (1) Positive first: a guard hard-coded to fail passes every negative
  #     fixture below and looks perfect.
  _swift 'the committed implementation passes' 0 "${head}${add}${rem}"

  # -- link 1: the anchors ---------------------------------------------------
  _swift 'a renamed SceneDelegate class FAILS' 1 \
"class RunnerSceneDelegate: FlutterSceneDelegate {
  private var privacyBlurView: UIVisualEffectView?
${conn}${resign}${add}${rem}"
  _swift 'a deleted privacyBlurView property FAILS' 1 \
"class SceneDelegate: FlutterSceneDelegate {
  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
  }
}"

  # -- link 2: the callback that runs before the switcher renders ------------
  # The first two both land on the "no sceneWillResignActive" branch, and
  # they are not the same fixture: this one leaves a textbook-correct cover
  # call in the file, in the wrong callback. It fails because the checks are
  # bound to ONE method rather than to the file — which is the property the
  # slicing note in the header is about, and which a whole-file grep would lose
  # while still passing the next fixture.
  _swift 'a blur installed only in sceneDidEnterBackground FAILS' 1 \
"${hdr}${conn}  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    coverWithPrivacyBlur()
  }
${add}${rem}"
  _swift 'no sceneWillResignActive at all FAILS' 1 "${hdr}${conn}${add}${rem}"
  # The resign's own call, which the cover's checks never see: dropped, nested
  # under a condition (a whole-body grep would still find it), or skipped by a
  # return in front of it.
  _swift 'a sceneWillResignActive that never covers the window FAILS' 1 \
"${hdr}${conn}  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
  }
${add}${rem}"
  _swift 'a resign cover nested inside an if FAILS' 1 \
"${hdr}${conn}  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    if shouldBlur {
      coverWithPrivacyBlur()
    }
  }
${add}${rem}"
  _swift 'an early return in sceneWillResignActive FAILS' 1 \
"${hdr}${conn}  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    if Self.blurDisabled { return }
    coverWithPrivacyBlur()
  }
${add}${rem}"
  # "and ONLY there": a SECOND install site, added belt-and-braces, is the edit
  # that reads as extra safety and is not. It touches no privacyBlurView and
  # removes nothing, so the exclusivity scan for UIVisualEffectView is the only
  # thing between it and a pass.
  _swift 'a second install site in sceneDidEnterBackground FAILS' 1 \
"${head}${add}  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
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
  # The super calls (links 2 and 6): each method drops its own, alone.
  _swift 'a sceneWillResignActive without super FAILS' 1 \
"${hdr}${conn}$(grep -v 'super.sceneWillResignActive' <<<"${resign}")
${add}${rem}"

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
'  private func coverWithPrivacyBlur() {
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
'  private func coverWithPrivacyBlur() {
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
'  private func coverWithPrivacyBlur() {
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
  # no sceneDidBecomeActive is never certified, and it is refused twice
  # over — by the missing-method branch, and, if that branch were ever deleted,
  # by the removal checks reading an empty slice. Both roads end at rc=1, which
  # is the property the user's blur depends on.
  _swift 'no sceneDidBecomeActive at all FAILS' 1 "${head}${add}}"
  _swift 'a removal nested in an if FAILS' 1 \
"${head}${add}  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    if let blur = privacyBlurView {
      blur.removeFromSuperview()
    }
    privacyBlurView = nil
  }
}"
  _swift 'a removal that never re-nils the handle FAILS' 1 \
"${head}${add}$(grep -v 'privacyBlurView = nil' <<<"${rem}")"
  _swift 'a sceneDidBecomeActive without super FAILS' 1 \
"${head}${add}$(grep -v 'super.sceneDidBecomeActive' <<<"${rem}")"
  _swift 'a conditional removal FAILS' 1 \
"${head}${add}  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    guard !isLocked else { return }
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}"
  _swift 'a second privacyBlurView touch point FAILS' 1 \
"${head}${add}  override func sceneDidEnterBackground(_ scene: UIScene) {
    privacyBlurView = nil
  }
${rem}"
  # The removal moved to sceneWillEnterForeground, which does not fire on
  # a resign that never reached the background (Control Centre, a declined call)
  # and so strands the blur over a live app. Written positionally, without the
  # property: that is what makes it land on the removeFromSuperview exclusivity
  # scan ALONE, instead of on that scan plus the two statement-depth checks plus
  # the touch-point scan the way one fixture used to.
  _swift 'a removeFromSuperview outside sceneDidBecomeActive FAILS' 1 \
"${head}${add}  override func sceneWillEnterForeground(_ scene: UIScene) {
    super.sceneWillEnterForeground(scene)
    window?.subviews.last?.removeFromSuperview()
  }
${rem}"

  # -- link 9: covered from connect -----------------------------------------
  # Each fixture is the committed connect with one edit, so each lands on its
  # own branch alone: the call gone, the call under the activationState test
  # that reads the same for every connect, the call ahead of the window it
  # binds, the call ahead of the show that installs the root view, a return in
  # front of it, and no connect method at all.
  _conn() { # _conn <label> <want-rc> <replacement-connect-method>
    _swift "$1" "$2" "${hdr}$3
${resign}${add}${rem}"
  }
  _conn 'a scene that connects uncovered FAILS' 1 \
    "$(grep -v 'coverWithPrivacyBlur' <<<"${conn}")"
  _conn 'a connect cover under an activationState test FAILS' 1 \
    "$(sed 's/^    coverWithPrivacyBlur()$/    if scene.activationState == .background {\n      coverWithPrivacyBlur()\n    }/' <<<"${conn}")"
  _conn 'a connect cover ahead of self.window FAILS' 1 \
'  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = appDelegate.flutterViewController
    window.makeKeyAndVisible()
    coverWithPrivacyBlur()
    self.window = window
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }'
  _conn 'a connect cover ahead of makeKeyAndVisible FAILS' 1 \
'  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = appDelegate.flutterViewController
    self.window = window
    coverWithPrivacyBlur()
    window.makeKeyAndVisible()
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }'
  _conn 'an early return in front of the connect cover FAILS' 1 \
    "$(sed 's/^    coverWithPrivacyBlur()$/    if connectionOptions.urlContexts.isEmpty { return }\n    coverWithPrivacyBlur()/' <<<"${conn}")"
  _swift 'no scene(_:willConnectTo:options:) at all FAILS' 1 "${hdr}${resign}${add}${rem}"

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
"/// The blur is NOT installed in sceneDidEnterBackground: that fires too
/// late for the switcher card. privacyBlurView holds a real
/// UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)), and
/// privacyBlurView?.removeFromSuperview() runs only on become-active.
/* An earlier draft called privacyBlurView?.removeFromSuperview() from
   sceneWillEnterForeground, which does not fire on a resign that never
   reached the background. */
${head}  private func coverWithPrivacyBlur() {
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
"${head}  private func coverWithPrivacyBlur() {
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
"${head}${add}  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil"

  # -- link 7 ----------------------------------------------------------------
  # The committed manifest, and each way to keep it while UIKit stops calling
  # SceneDelegate: no manifest at all, one xmllint reads as a comment, the
  # template's FlutterSceneDelegate or any other class named, a second
  # configuration for the role, and a manifest that is not the app's own.
  local cfg='<dict><key>UISceneClassName</key><string>UIWindowScene</string><key>UISceneConfigurationName</key><string>flutter</string><key>UISceneDelegateClassName</key><string>$(PRODUCT_MODULE_NAME).SceneDelegate</string></dict>'
  local manifest="<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array>${cfg}</array></dict></dict>"
  _plist 'the committed scene manifest passes' 0 \
"<key>UILaunchStoryboardName</key><string>LaunchScreen</string>${manifest}"
  _plist 'no scene manifest FAILS' 1 \
'<key>UILaunchStoryboardName</key><string>LaunchScreen</string>'
  # xmllint, not grep: a key inside an XML comment is not a key.
  _plist 'a commented-out scene manifest FAILS' 1 \
"<!-- ${manifest} --><key>UILaunchStoryboardName</key><string>LaunchScreen</string>"
  _plist 'FlutterSceneDelegate named as the scene delegate FAILS' 1 \
"${manifest//\$(PRODUCT_MODULE_NAME).SceneDelegate/FlutterSceneDelegate}"
  _plist 'another scene delegate class FAILS' 1 \
"${manifest//\$(PRODUCT_MODULE_NAME).SceneDelegate/\$(PRODUCT_MODULE_NAME).RunnerSceneDelegate}"
  _plist 'two application-role configurations FAIL' 1 \
"${manifest//<array>${cfg}/<array>${cfg}${cfg}}"
  _plist 'a scene manifest nested below the top level FAILS' 1 \
"<key>NSAppTransportSecurity</key><dict>${manifest}</dict>"
  _plist 'an unparsable Info.plist is broken, not a violation' 2 \
"${manifest%</dict>}"

  # -- link 8, and link 7's code bypass -------------------------------------
  local app_clean='@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
'
  _app() { # _app <label> <want-rc> <AppDelegate tail> [<SceneDelegate whole file>]
    local got=0
    printf '%s' "${app_clean}$3
}" >"${tmp}/AppDelegate.swift"
    printf '%s' "${4:-${head}${add}${rem}}" >"${tmp}/SceneDelegate.swift"
    ( check_no_app_delegate_blur "${tmp}/AppDelegate.swift" "${tmp}/SceneDelegate.swift" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }
  _app 'an app delegate with no blur and no UI-lifecycle override passes' 0 ''
  local app_fixture='  override func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar? {
    flutterEngine.registrar(forPlugin: pluginKey)
  }'
  local got=0
  printf '%s\n' "class Runner: NSObject {
${app_fixture}
}" >"${tmp}/AppDelegate.swift"
  printf '%s' "${head}${add}${rem}" >"${tmp}/SceneDelegate.swift"
  ( check_no_app_delegate_blur "${tmp}/AppDelegate.swift" "${tmp}/SceneDelegate.swift" ) \
    >/dev/null 2>&1 || got=$?
  _record 'an AppDelegate.swift with no AppDelegate class FAILS' 1 "${got}"
  # One fixture per banned token, each the only one in its file: a scan that
  # lost any single token would let exactly that fixture pass.
  _app 'a privacyBlurView left on the app delegate FAILS' 1 \
'  private var privacyBlurView: UIVisualEffectView?'
  _app 'a UIVisualEffectView built on the app delegate FAILS' 1 \
'  func cover(_ window: UIWindow) {
    window.addSubview(UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)))
  }'
  _app 'a removeFromSuperview on the app delegate FAILS' 1 \
'  func uncover(_ window: UIWindow) {
    window.subviews.last?.removeFromSuperview()
  }'
  local cb
  for cb in WillResignActive DidBecomeActive WillEnterForeground DidEnterBackground; do
    _app "a dead application${cb} override FAILS" 1 \
"  override func application${cb}(_ application: UIApplication) {
    super.application${cb}(application)
  }"
  done
  _app 'an app delegate that picks the scene configuration in code FAILS' 1 \
'  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
  }'
  _app 'a scene delegate class chosen in code FAILS' 1 '' \
"${head}${add}${rem}
extension UISceneConfiguration {
  func useHaven() { delegateClass = SceneDelegate.self }
}"
  _app 'comments naming every link-8 token still pass' 0 \
'  // No privacyBlurView, UIVisualEffectView( or removeFromSuperview() here, and
  /* no func applicationWillResignActive(, func applicationDidBecomeActive(,
     func applicationWillEnterForeground( or func applicationDidEnterBackground(:
     UIKit sends those to SceneDelegate. Nor configurationForConnecting or a
     delegateClass: Info.plist chooses the delegate. */'

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

  local scene="${REPO_ROOT}/haven/ios/Runner/SceneDelegate.swift"
  local app="${REPO_ROOT}/haven/ios/Runner/AppDelegate.swift"
  local plist="${REPO_ROOT}/haven/ios/Runner/Info.plist"
  local path
  for path in "${scene}" "${app}" "${plist}"; do
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
  run_check check_blur_lifecycle "${scene}"
  run_check check_scene_manifest "${plist}"
  run_check check_no_app_delegate_blur "${app}" "${scene}"

  if (( broken )); then
    exit 2
  fi
  if (( status != 0 )); then
    fail_msg "the iOS app-switcher blur is no longer intact (see above)."
    exit 1
  fi
  log "OK: the app-switcher blur is built in coverWithPrivacyBlur() alone, \
called unconditionally at connect and on sceneWillResignActive, covers the \
scene's window with a real blur, is removed only on sceneDidBecomeActive, both \
callbacks after super; Info.plist routes the scene to SceneDelegate, and the \
app delegate holds no dead copy."
  exit 0
}

main "$@"
