# Mesh aura — the on-map indicator for the Bluetooth mesh

Status: **drafted by a Flutter specialist agent and confirmed with changes
by an independent Opus 5.5 review, both 2026-11-11**; the review's changes
are folded in below and listed in §10. **Built in M3e, 2026-11-12, with the
mesh button** (`docs/BLUETOOTH_MESH_PLAN.md` §7.5, §16 "M3d and M3e"), in
Dart, behind `HAVEN_MESH` and only where there is a radio; §11 lists where
the build differs from the text below. Never seen on a device: the project
has none (§8, "Not provable without a device").

The owner's request: when the mesh is turned on, a soft blue wave ripples
out of the mesh button to the edges of the screen and leaves a blue hue
around them while the mesh is active; while it is active, a similar ripple
comes out of the user's own location whenever their own location is
broadcast to the mesh. Soft, smooth, easy on the eyes, and the same
experience on every device and form factor.

Verification: `docs.flutter.dev`, `api.flutter.dev` and `docs.fleaflet.dev`
were not reachable from the drafting session. Claims marked [n] were checked
against what those sites are generated from — Flutter 3.44.8 doc comments,
the flutter/website markdown, flutter_map v8.3.0 source. Anything not
checked is marked **unverified**.

## 1. Rendering

- **Wave and hue** — one widget, `MeshAuraOverlay`
  (`haven/lib/src/widgets/map/mesh_aura_overlay.dart`): `IgnorePointer` →
  `ExcludeSemantics` → `RepaintBoundary` → `CustomPaint` whose painter takes
  its two controllers as the `repaint:` listenable, so a frame repaints
  without build or layout [1] (the idiom `refresh_ring_button.dart` uses).
  The wave is one full-rect `drawRect` with a radial gradient centred on the
  button. The hue is the inner glow of a rounded rect: four linear-gradient
  edge strips and four radial-gradient corners.
- **Own-location ripple** — `OwnLocationRipple`
  (`haven/lib/src/widgets/map/own_location_ripple.dart`), the same wrapper
  chain, two `drawCircle` calls with radial gradients. Its marker exists
  only while it animates (§3).
- **Nothing at rest.** Off: the overlay builds `SizedBox.shrink()`. On and
  settled: both controllers are stopped — no ticker, no scheduled frame; the
  hue is a static picture in its own layer. The hue does not "breathe": a
  looping animation would keep the frame pipeline running for as long as the
  mesh is on.
- **Own boundary.** `FlutterMap` wraps all its layers in one
  `RepaintBoundary` [2]; without the ripple's own, each ripple frame would
  repaint tiles and markers [3].
- **Avoided for cost:** `saveLayer` and the widgets that can cause one
  (`Opacity`, `FadeTransition`, `ShaderMask`) [4][5]; `MaskFilter.blur` [6];
  `BackdropFilter` [7]; clipping inside an animation [5].
- **Rejected: a fragment shader.** It could reveal the hue exactly where the
  wave has passed, at the price of an asset pipeline and a second code path
  on the legacy renderer [8]; a cross-fade tied to the wave's progress is
  close enough.
- **Renderer.** Impeller is the only renderer on iOS and the default on
  Android API 29+, with the legacy OpenGL renderer on older or non-Vulkan
  devices [9]. Gradients and circles are basic primitives on both.

## 2. Geometry (`haven/lib/src/utils/mesh_aura_geometry.dart`, pure functions)

`meshButtonRect(Size shell, EdgeInsets viewPadding)`,
`waveReach(Size, Offset origin)`,
`waveDuration(double reach)`, `waveBand(double reach)`, `hueWidth(Size)`.

- **Origin:** the centre of `meshButtonRect`, the same function the button's
  `Positioned` uses — no `GlobalKey` lookup. A fixed left corner, the same in
  RTL (plan §7.5), held clear of a landscape sensor housing:
  `left = 16 + viewPadding.left` (landscape is supported on both platforms).
- **Reach:** the distance to the farthest corner of the app's window, read
  from the size the painter is handed each frame. Front radius =
  `easeOutSine(t) × (reach + band)`.
- **Duration** scales with reach, sub-linearly:
  `clamp(600 + 0.5·reach, 900, 1400)` ms. A constant speed would take over
  two seconds on a tablet; a constant duration would race across one.

  | Window (logical px) | Reach | Duration | Hue width |
  |---|---|---|---|
  | 375×667 | 641 | 921 ms | 22.5 |
  | 393×852 | 793 | 996 ms | 23.6 |
  | 440×956 | 896 | 1048 ms | 26.4 |
  | Fold cover 344×882 | 796 | 998 ms | 20.6 |
  | Fold open 768×884 | 1037 | 1118 ms | 32 |
  | Tablet 1032×1376 | 1535 | 1367 ms | 32 |

- **Wave band:** `clamp(0.28·reach, 160, 320)`. Alpha along the radius: a
  0.06 wash behind, 0.22 at its peak (`front − 0.35·band`), 0 at the front;
  the whole wave fades over the last 30 % of its run.
- **Hue:** width `clamp(0.06·shortestSide, 20, 32)`, corner radius 44. Alpha
  by distance inward: 0.50 at the edge, 0.28 at 15 %, 0.09 at 50 %, 0 at
  100 %. Fades in over the second half of the wave; fades out in 300 ms,
  after which the overlay builds `SizedBox.shrink()` again. The review
  found 0.50 strong for a hue that may stay twelve hours; 0.35 at the edge
  is the alternative to try first on a device.
- **Resize** (fold, unfold, rotation, split-screen): everything is derived
  from the current size and the progress `t`; nothing remembers the old
  size. The duration is fixed when the wave starts, so the front jumps once
  if the window changes mid-wave.
- **Foldables:** `MediaQuery.displayFeatures` is not consulted [10]; the hue
  frames the window and the wave crosses a crease unbroken.
- **Where "the edge" is.** The hue frames Haven's window. On iOS and on
  Android 15+ that is the whole screen. On Android 14 and below the app is
  not edge to edge today (no `SystemUiMode.edgeToEdge`, no short-edge
  cutout mode), so the hue stops above the navigation bar and, in
  landscape, beside the cutout's black bar. Making the app edge to edge
  everywhere changes every page's insets and is a separate task (§9).
- **Cutouts and rounded corners:** the hue ignores safe-area padding. That Flutter exposes no display corner radius is
  **unverified**; radius 44 follows typical bezels and still fills a square
  corner.
- All lengths are logical pixels, so the band and the hue have the same
  physical softness at any pixel density.

## 3. Where it sits

- `MapShell.buildLayers` gains the aura **after the circles sheet and before
  the status banners**: the whole perimeter of the window stays framed
  whatever the sheet's height, and a warning banner is never tinted.
- The ripple is a second `Marker` in the existing own-location `MarkerLayer`
  (`map_page.dart`), listed before the dot and present only while it
  animates. The layer projects it, so it follows pan, zoom and rotation and
  is culled off-screen [11]. Both markers carry keys: the layer keys each
  child by its marker's key, and its world-copy loop can otherwise shift
  indices and remount the ripple mid-animation. The layer is built by a
  static builder extracted from `map_page.dart`, as `MapShell.buildLayers`
  is, so a widget test can pump the real composition.
- The aura belongs to the map screen: a route pushed above it (Settings,
  the statistics sheet) covers it.
- Own location off-screen, unknown, or location access blocked: no ripple
  and no substitute.

## 4. States

- **The wave starts on the observed change to "running"** (signal S1), never
  on the tap: a permission dialog or a failed start shows nothing.
- Opened or resumed with the mesh already running: the static hue, no wave.
- Off, the 12 h auto-off, Bluetooth switched off, permission revoked: each
  is "not running" — the 300 ms fade. The hue never claims a mesh that is
  not running.
- Backgrounded mid-animation: no listener is needed — a ticker takes its
  elapsed time from frame timestamps and no frame runs in the background,
  so the first frame after resume lands on the settled state.
- Rapid taps: the controllers run from where they are; nothing queues.
- One ripple per publish pass, however many circles it sent for; one that
  arrives while another runs is dropped.

## 5. Accessibility

- **Reduce motion** (`reduceMotionOf`): no travelling wave, the hue fades
  in over 300 ms; the ripple is a fixed halo that only changes opacity.
- **Never colour alone:** the state is the button's icon, label and
  semantics (plan §7.5); the aura is decoration on top and is excluded from
  semantics. A change the user did not make — the auto-off, Bluetooth
  switched off — is announced with `SemanticsService.sendAnnouncement`, the
  app's existing pattern; the user's own tap is not announced twice, and no
  ripple is announced.
- **Photosensitivity:** one slow, low-contrast wave and an occasional
  ripple; no red, no loop, nothing near three flashes a second (WCAG 2.3.1,
  2.2.2) [15].

## 6. Colour

`HavenMeshColors.active = Color(0xFF2563EB)` in `theme/colors.dart`: the
blue of the same series as the existing status green, amber and red. One
value for both themes, because the basemap is chosen independently of the
theme (the reason `UserLocationMarker` uses constant ink). Contrast of the
edge at 0.50 alpha, computed against representative backgrounds
(**unverified** against the real tiles): 2.14 on white, 1.77 on light
water, 1.69 on dark land.

## 7. Signals the UI needs

- **S1 "running":** true only while the mesh engine's radio is actually
  advertising or scanning — a fact read from the engine, not inferred from
  its inputs (permission, Bluetooth on, deadline). Pushed on change, and at
  resume read live and synchronously, compared with the deadline at that
  moment, so the first frame after a resume never shows a stale hue.
- **S2 "own location handed to the mesh":** not a new signal. Dart already
  makes the call that publishes a location; the ripple fires when that call
  answers that the location was sent or sealed for the mesh, S1 is true and
  at least one phone is connected. Nothing crosses the bridge to say which
  radio emission was real.
- **Why the hand-off and not the emission.** The mesh sends in fixed slots
  with cover packets in between so that a neighbour cannot tell a real
  packet from a cover one (plan §5.1). A ripple at the real emission would
  need the engine to tell the UI which emission was real — a real-versus-
  cover bit outside the engine — and would mark that exact packet for
  anyone who sees the screen while capturing the radio. A ripple at the
  hand-off needs no such signal. It means "your location was handed to the
  mesh", and the packet goes out at the next slot, up to about two minutes
  later.
- **What remains.** Someone watching the unlocked screen learns when a
  location was handed over, and can guess that the next emission is real.
  The same screen already shows the location and its updates. Android
  blocks screenshots and recording of the app (`FLAG_SECURE`); iOS screen
  recording and mirroring are not blocked.

## 8. Tests (no hardware)

Pixel sampling, not golden files: the painter is painted into a
`PictureRecorder`, turned into an image and read with tolerances, as
`member_markers_layer_test.dart` already does; goldens differ across
platforms and Flutter versions [21].

- Geometry: reach covers every corner for 1,000 seeded random sizes;
  duration within 900–1400 ms and monotonic; the button rect is the same in
  LTR and RTL.
- Overlay: off paints nothing; on at mount shows the hue with no animation;
  the front is where the formula says at half time; at the end the edges
  are blue and the centre untouched; no frame is scheduled at rest; the
  map's repaint boundary does not repaint and a probe beside it does not
  rebuild; no `saveLayer`; taps and drags reach the map mid-wave; reduce
  motion on either platform flag gives no wave; a resize mid-wave lands the
  hue on the new edges; "not running" removes the hue within 300 ms; ten
  rapid toggles settle on the last; a pause snaps; no semantics node.
- Ripple: its centre is the dot's before and after a move, zoom and
  rotation; a second hand-off while one runs is ignored; idle has no marker
  and no layer and repaints no map; reduce motion keeps the radius constant;
  no ripple while S1 is false or no phone is connected.
- S1: Bluetooth off, permission revoked, and a deadline that passed while
  the app was suspended each give no hue on the first frame after resume.
- Log anonymity: a log-capture test that nothing is logged when a ripple
  fires (Security Rule 15).
- Shell: the order is sheet, aura, banners, and a banner's remedy is still
  tappable.

**Not provable without a device:** that it is smooth on a real iPhone or
Fold. Flutter's own guidance is that emulator frame timings are not
indicative [19], so there is no frame-time gate; a real-device look is
deferred with the power measurements.

## 9. Open decisions

1. **Ripple at the hand-off (drafted here) or at the real emission.** The
   emission is the literal "broadcast" moment but creates the real-versus-
   cover signal described in §7; choosing it is the owner's decision under
   Security Rule 10.
2. **Edge to edge on Android 14 and below** — leave the hue inside the
   system bars there, or make the whole app edge to edge as its own task.
3. Aura above the sheet (whole window framed; a faint tint, about 0.05, on
   the sheet's side edges) or below it (map only; hidden when the sheet is
   tall). Drafted: above.
4. Edge alpha 0.50 or 0.35 — a judgement to make on a real screen.

## 10. What the confirmation review changed

- The ripple fires at the hand-off, not at the emission (§7): no real-
  versus-cover signal leaves the engine.
- S1 is the radio's actual state, read live at resume (§7).
- The Android edge-to-edge difference is stated (§2).
- The button rect accounts for a landscape sensor housing (§2).
- The ripple marker exists only while animating, both markers are keyed,
  and the layer gets a testable static builder (§3).
- Dropped: the lifecycle listener and the 5 s gate (§4). Added: the
  overlay returns to nothing after the fade (§2), announcements only for
  changes the user did not make (§5), a log-capture test (§8).
- Not verified by either pass: behaviour on a real device, including iOS
  Control Centre ending the mesh (plan §0.4), and smoothness.

## 11. What the build found

Built as above except where stated here; each is in the code and under a
test (`haven/test/widgets/map/mesh_aura_overlay_test.dart`,
`own_location_ripple_test.dart`, `test/utils/mesh_aura_geometry_test.dart`,
`test/providers/mesh_phase_test.dart`, `test/pages/map_shell_mesh_test.dart`).

- **§2, the front.** `easeOutSine` is Flutter's `Curves.easeOutSine`, a cubic
  that reads 0.736 at half time where a sine reads 0.707; the test computes
  the front with the same curve.
- **§2, the hue** is 0.35 at the edge, not 0.50, and thins sooner: of the
  edge's alpha, all of it at the edge, half at 30 % of the width in, 0.15
  at 65 %, none at 100 %. A UX review of rendered frames (2026-11-12, no
  device) found 0.50 with the designed stops to read as a line drawn round
  the screen, and 0.35 with these as a glow. Every stop scales with one
  constant, `kMeshHueEdgeAlpha`; the owner had 0.50 against 0.35 open (§9,
  decision 4), and changing it back is that one number. The contrast
  figures of §6 were computed for 0.50 and are lower at 0.35; the hue was
  never what tells the state (§5).
- **§3, the ripple's layer** is a widget, `OwnLocationLayer`, not a static
  builder: it owns the ripple's controller, and a widget can be pumped. It
  is built only where there is a radio; elsewhere the map builds the dot's
  layer it always built, unkeyed. Only the dot's marker is keyed: the key
  keeps the dot's element, and the node a screen reader may be on, when the
  ripple's marker comes and goes ahead of it. The ripple's needs none — its
  controller is the layer's, so a remount of it changes nothing seen.
- **§3, the ripple itself** was not specified beyond "two `drawCircle`
  calls": two soft rings from the dot's edge to 72 px, the second a quarter
  of the run behind the first, 1.6 s. With motion reduced, one ring of a
  fixed size that fades in and out.
- **§6, the ripple's colour follows the basemap**, the one place the single
  blue did not hold: `HavenMeshColors.active` (`0xFF2563EB`) at a peak
  alpha of 0.34 on the light basemaps, and on the dark one
  (`kStyleIdAlidadeSmoothDark`) `HavenMeshColors.activeOnDark`
  (`0xFF60A5FA`) at 0.5 — the darker blue all but vanished there in the
  rendered frames. The map page tells the layer which basemap it draws; the
  two colours are in `theme/colors.dart` and nowhere else. The wave, the
  hue and the button keep the one blue.
- **§4, a hue coming back.** Turned on again while the hue is still leaving,
  the hue returns from where it is with no second wave: a wave over it
  would blank it first.
- **§4, mesh already running.** The shell's aura builds nothing until the
  radio and the engine have both answered once, so what it first shows is
  the settled state. A read of the radio that fails later changes nothing
  — the last report stands — so an unanswered question neither removes the
  hue nor replays the wave; an answer that lands behind a later read or
  report is dropped.
- **§5, a stop the user did not make** is told by a notice beside the button
  that stays until dismissed or until mesh is turned on from it, and
  announced once; it gives the one cause Dart can know — the clock passed
  the deadline — and otherwise none. A pause (Bluetooth off) is announced.
  The user's own stop is neither, whenever the radio's report of it
  arrives; a turn-off that failed is not their stop.
- **§5, the button** says its state once: the name "Bluetooth mesh", on or
  off as the toggle, and "paused" or "connected" as the value. While a
  turn-on is under way it shows a ring, which does not turn where motion is
  reduced, and the start is announced once.
- **§7, S1** is `meshPhaseProvider`: the radio's last report says running,
  **and** the engine was on when last read, **and** the deadline has not
  passed by the device's clock. The clock comparison is synchronous — a
  timer of the provider's own at the deadline, and an invalidation by the
  shell at every resume. The radio's own state at a resume is a channel
  call and is not synchronous: a radio that stopped while the app was away,
  whose report did not reach Dart, shows its hue until that call answers.
- **§7, S2** is `meshHandOffProvider`, told by the foreground publish tick
  and the one-shot publisher at the first send of a pass that got past the
  send-time check (a relay took it or did not; or it was for the mesh
  alone). It counts only while S1 holds and, read afresh, a phone is linked.
  Both tell it through one helper, `noteMeshHandOff`, which is not waited
  for and keeps whatever the telling throws, at once or later: no relay
  send waits on the ripple or fails with it. A background burst tells
  nothing, and a hand-off told while the app is not in front is dropped by
  the layer: no frame runs there, and it would play at the return for a
  hand-off long past. As M3 design §E.5 says, a ripple can show for a
  location the hand-off then dropped.
- **§8, tests not written.** "Permission revoked" has no state of its own in
  Dart: it is the radio reporting that it stopped, which is tested. The
  first-frame-after-resume tests are of the provider, with the clock moved
  and its timer not run, since the shell cannot be pumped; that the shell
  invalidates at a resume is pinned from its source.

## References

1. https://api.flutter.dev/flutter/rendering/CustomPainter-class.html
2. https://github.com/fleaflet/flutter_map/blob/v8.3.0/lib/src/map/widget.dart
3. https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html
4. https://api.flutter.dev/flutter/dart-ui/Canvas/saveLayer.html
5. https://docs.flutter.dev/perf/best-practices
6. https://api.flutter.dev/flutter/dart-ui/MaskFilter/MaskFilter.blur.html
7. https://api.flutter.dev/flutter/widgets/BackdropFilter-class.html
8. https://docs.flutter.dev/ui/design/graphics/fragment-shaders
9. https://docs.flutter.dev/perf/impeller
10. https://api.flutter.dev/flutter/widgets/MediaQueryData/displayFeatures.html
11. https://github.com/fleaflet/flutter_map/blob/v8.3.0/lib/src/layer/marker_layer/marker_layer.dart
15. https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html
19. https://docs.flutter.dev/perf/ui-performance
21. https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html
