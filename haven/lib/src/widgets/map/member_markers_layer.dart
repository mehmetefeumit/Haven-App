/// The single map layer that renders every circle member as a unified marker.
///
/// A screen-space overlay placed inside `FlutterMap.children`: reading
/// `MapCamera.of(context)` makes it rebuild on every pan/zoom/fling frame, so
/// each marker's position, size, and tail track the camera exactly. There is
/// no on-screen/off-screen split — one continuous [MemberMarker] per member
/// flows from a centred circle to an edge droplet (see [projectMarker]).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart';
import 'package:haven/src/utils/marker_glide.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/reduce_motion.dart';
import 'package:haven/src/widgets/map/avatar_image_cache.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';
import 'package:haven/src/widgets/map/member_marker.dart';
import 'package:latlong2/latlong.dart';

/// Clips the overlay to the safe rect (see the layer's `build`).
class _SafeRectClipper extends CustomClipper<Rect> {
  const _SafeRectClipper(this.safeRect);

  final Rect safeRect;

  @override
  Rect getClip(Size size) => safeRect;

  @override
  bool shouldReclip(_SafeRectClipper oldClipper) =>
      oldClipper.safeRect != safeRect;
}

/// One member paired with its projected screen point and projection.
class _MarkerEntry {
  _MarkerEntry({
    required this.member,
    required this.point,
    required this.projection,
  });

  final MemberLocation member;
  final Offset point;
  final MarkerProjection projection;
}

/// Renders all [members] as unified teardrop markers.
///
/// When [publicProfilesEnabled], each marker resolves its avatar via
/// `memberProfileProvider(pubkey)` (plain-pubkey keyed, D6 — no MLS group ID
/// component, since the same pubkey resolves to the same public profile
/// across every circle) and paints it inside the head circle, falling back
/// to initials while loading or on error. Names are NOT resolved reactively
/// here — every [MemberLocation] already carries its effective display name
/// (resolved cache-only, no network, in `memberLocationsProvider`'s body —
/// plan §6.3 Flutter review F4), so the layer itself stays non-reactive
/// except for the avatar loader.
class MemberMarkersLayer extends StatefulWidget {
  /// Creates a [MemberMarkersLayer].
  const MemberMarkersLayer({
    required this.members,
    required this.bottomInset,
    required this.onFocusMember,
    this.onMarkerTap,
    super.key,
  });

  /// All circle members with a known location.
  final List<MemberLocation> members;

  /// Logical pixels at the bottom of the viewport occluded by the collapsed
  /// bottom sheet, reserved so markers and tails stay above it.
  final double bottomInset;

  /// Called when an off-screen marker is tapped — recenters the map on them.
  final void Function(MemberLocation member) onFocusMember;

  /// Optional tap handler for on-screen markers (iOS "Open in Apple Maps").
  final void Function(MemberLocation member)? onMarkerTap;

  @override
  State<MemberMarkersLayer> createState() => _MemberMarkersLayerState();
}

/// A member that has left the selected circle and is fading out in place.
///
/// Retains the member's last [location] so the marker keeps tracking the
/// camera through the fade.
class _ExitingMember {
  const _ExitingMember({required this.location, required this.position});

  final MemberLocation location;

  /// Where the marker was DRAWN when it left, which mid-glide is not the fix.
  final LatLng position;
}

/// A marker travelling from one fix to the next; [start] is on the ticker's
/// clock.
class _Glide {
  const _Glide({required this.from, required this.to, required this.start});

  final LatLng from;
  final LatLng to;
  final Duration start;
}

const _glideDuration = Duration(milliseconds: 400);

class _MemberMarkersLayerState extends State<MemberMarkersLayer>
    with SingleTickerProviderStateMixin {
  /// Runs only while [_glides] is non-empty, so a map at rest schedules no
  /// frames.
  late final Ticker _ticker;

  /// Active glides keyed by pubkey; an entry never outlives its member.
  final Map<String, _Glide> _glides = <String, _Glide>{};

  /// The ticker's clock as of the last frame. A glide started between frames
  /// takes it as its start, so it may begin up to one frame early.
  Duration _now = Duration.zero;

  /// Members that were live on the previous build but have since left the
  /// selected circle, kept mounted so they play the appear transition in
  /// reverse (the mirror of the fade/scale-in new members get) before being
  /// removed. Keyed by pubkey.
  ///
  /// Invariant: a pubkey is NEVER in both `_exiting` and [widget.members] in
  /// the same build — [didUpdateWidget] prunes reappeared pubkeys before
  /// [build] runs (Flutter guarantees didUpdateWidget precedes build on the
  /// frame the parent rebuilds). The shared `marker_pos_$pubkey` / member-marker
  /// keys would otherwise trip a duplicate-key assertion, so do NOT call
  /// setState in didUpdateWidget (which could interleave a build).
  final Map<String, _ExitingMember> _exiting = <String, _ExitingMember>{};

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _now = elapsed;
    _glides.removeWhere((_, g) => elapsed - g.start >= _glideDuration);
    if (_glides.isEmpty) _ticker.stop();
    setState(() {});
  }

  /// Where [member] is drawn now: part-way along its glide, else at its fix.
  LatLng _displayed(MemberLocation member) {
    final glide = _glides[member.pubkey];
    if (glide == null) return LatLng(member.latitude, member.longitude);
    final t =
        ((_now - glide.start).inMicroseconds / _glideDuration.inMicroseconds)
            .clamp(0.0, 1.0);
    return glideLerp(glide.from, glide.to, Curves.easeOutCubic.transform(t));
  }

  /// Starts a glide for each member whose fix moved, from where it is drawn.
  void _startGlides(MemberMarkersLayer oldWidget) {
    // A stopped ticker restarts its elapsed time at zero, so a stale `_now`
    // would stamp a start in its future.
    if (!_ticker.isActive) _now = Duration.zero;
    final previous = {for (final m in oldWidget.members) m.pubkey: m};
    final camera = MapCamera.of(context);
    final viewport = edgeViewport(
      viewport: camera.nonRotatedSize,
      topInset: MediaQuery.maybeOf(context)?.viewPadding.top ?? 0,
      bottomInset: widget.bottomInset,
    );
    final reduceMotion = reduceMotionOf(context);
    final longSide = math.max(
      camera.nonRotatedSize.width,
      camera.nonRotatedSize.height,
    );
    for (final member in widget.members) {
      final old = previous[member.pubkey];
      if (old == null) {
        _glides.remove(member.pubkey);
        continue;
      }
      if (old.latitude == member.latitude &&
          old.longitude == member.longitude) {
        continue;
      }
      final from = _displayed(old);
      final to = LatLng(member.latitude, member.longitude);
      final fromPoint = camera.latLngToScreenOffset(from);
      final toPoint = camera.latLngToScreenOffset(to);
      if (reduceMotion ||
          (toPoint - fromPoint).distance > longSide ||
          (!viewport.safeRect.contains(fromPoint) &&
              !viewport.safeRect.contains(toPoint))) {
        _glides.remove(member.pubkey);
        continue;
      }
      _glides[member.pubkey] = _Glide(from: from, to: to, start: _now);
    }
    if (_glides.isEmpty) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(MemberMarkersLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final live = <String>{for (final m in widget.members) m.pubkey};
    // A member present last build but gone now begins fading out, where it is
    // drawn, not at a fix it never reached.
    for (final m in oldWidget.members) {
      if (!live.contains(m.pubkey)) {
        _exiting[m.pubkey] = _ExitingMember(
          location: m,
          position: _displayed(m),
        );
        _glides.remove(m.pubkey);
      }
    }
    _startGlides(oldWidget);
    // A member that reappeared renders live again; drop any fade-out copy so it
    // is never drawn twice. Its keyed marker state is reused and fades back in
    // via MemberMarker.didUpdateWidget.
    for (final key in live) {
      _exiting.remove(key);
    }
  }

  /// Removes a fully faded-out marker once its exit transition completes.
  void _onExitComplete(String pubkey) {
    if (!mounted) return;
    // `remove` returns null if the entry was already cleared (e.g. the member
    // reappeared, or a duplicate post-frame completion under reduce-motion);
    // the null check makes the extra completion a harmless no-op.
    if (_exiting.remove(pubkey) != null) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final topInset = MediaQuery.maybeOf(context)?.viewPadding.top ?? 0;
    final viewport = edgeViewport(
      viewport: camera.nonRotatedSize,
      topInset: topInset,
      bottomInset: widget.bottomInset,
    );

    _MarkerEntry entryFor(MemberLocation member, LatLng position) {
      final point = camera.latLngToScreenOffset(position);
      return _MarkerEntry(
        member: member,
        point: point,
        projection: projectMarker(point: point, viewport: viewport),
      );
    }

    final entries = [
      for (final member in widget.members) entryFor(member, _displayed(member)),
    ];
    if (entries.isEmpty && _exiting.isEmpty) return const SizedBox.shrink();

    // Nudge overlapping OFF-SCREEN bubbles apart along their edge. On-screen
    // bubbles sit exactly on the member's point and are never moved.
    final spread = _spread(
      entries.where((e) => e.projection.offScreen).toList(),
      viewport.safeRect,
    );

    // Draw far (small) bubbles first so nearer/larger ones sit on top, and
    // among equals the southern pin over the northern one (it is nearer the
    // viewer), with the pubkey as the stable tie-break for co-located members.
    entries.sort((a, b) {
      final byDiameter = a.projection.diameter.compareTo(b.projection.diameter);
      if (byDiameter != 0) return byDiameter;
      final byY = a.point.dy.compareTo(b.point.dy);
      return byY != 0 ? byY : a.member.pubkey.compareTo(b.member.pubkey);
    });

    // Marker ink is constant, not themed: the basemap is chosen independently
    // of the theme. The clip is the SAFE rect so a tail is cut flat at the top
    // inset as at the sides, the flat contact patch of a pin on the glass.
    return ClipRect(
      clipper: _SafeRectClipper(viewport.safeRect),
      child: Stack(
        key: WidgetKeys.memberMarkersLayer,
        clipBehavior: Clip.none,
        children: [
          // Fading-out markers paint beneath the live ones; they are inert
          // (no taps, no spread) and just animate away in place.
          for (final exit in _exiting.values)
            _positioned(
              entryFor(exit.location, exit.position),
              null,
              viewport.safeRect,
              exiting: true,
            ),
          for (final entry in entries)
            _positioned(
              entry,
              spread[entry.member.pubkey],
              viewport.safeRect,
              exiting: false,
            ),
        ],
      ),
    );
  }

  Widget _positioned(
    _MarkerEntry entry,
    Offset? spreadCenter,
    Rect safeRect, {
    required bool exiting,
  }) {
    final member = entry.member;
    final proj = entry.projection;
    final center = spreadCenter ?? proj.bubbleCenter;

    // Re-aim the tail at the member's true point if spreading moved the bubble.
    var nubLength = proj.nubLength;
    var angle = proj.angle;
    final point = entry.point;
    if (point.dx.isFinite && point.dy.isFinite && center != proj.bubbleCenter) {
      final tail = aimTail(
        point: point,
        center: center,
        radius: proj.diameter / 2,
        cap: proj.tailCap,
      );
      nubLength = tail.nubLength;
      angle = tail.angle;
    }

    final footprint = MemberMarker.footprintFor(proj.diameter);
    // Fading-out markers are inert: no tap target, no inward bias.
    final tapOffset = (!exiting && proj.offScreen)
        ? tapTargetCenter(
                bubbleCenter: center,
                diameter: proj.diameter,
                safeRect: safeRect,
              ) -
              center
        : Offset.zero;
    // Off-screen markers recenter the map; on-screen ones use the per-marker
    // tap (iOS Apple Maps) or are non-interactive on Android. Exiting markers
    // take no taps — they are on their way out.
    final tap = widget.onMarkerTap;
    final VoidCallback? onTap;
    if (exiting) {
      onTap = null;
    } else if (proj.offScreen) {
      onTap = () => widget.onFocusMember(member);
    } else {
      onTap = tap != null ? () => tap(member) : null;
    }

    final markerProps = _MarkerProps(
      initials: markerInitials(member.displayName, member.pubkey),
      publicKey: member.pubkey,
      displayName: member.displayName,
      diameter: proj.diameter,
      nubLength: nubLength,
      angle: angle,
      bearing: proj.bearing,
      offScreen: proj.offScreen,
      lastSeen: member.timestamp,
      onTap: onTap,
      tapOffset: tapOffset,
      exiting: exiting,
      onExitComplete: exiting ? () => _onExitComplete(member.pubkey) : null,
    );

    final child = publicProfilesEnabled
        ? _AvatarLoader(
            key: ValueKey<String>('avatar_loader_${member.pubkey}'),
            pubkeyHex: member.pubkey,
            markerProps: markerProps,
          )
        : _markerWidget(markerProps, member.pubkey);

    return Positioned(
      key: ValueKey<String>('marker_pos_${member.pubkey}'),
      left: center.dx - footprint / 2,
      top: center.dy - footprint / 2,
      width: footprint,
      height: footprint,
      child: RepaintBoundary(child: child),
    );
  }

  /// Builds a plain [MemberMarker] without an avatar image.
  Widget _markerWidget(_MarkerProps p, String pubkey) {
    return MemberMarker(
      key: WidgetKeys.memberMarker(pubkey),
      initials: p.initials,
      publicKey: p.publicKey,
      displayName: p.displayName,
      diameter: p.diameter,
      nubLength: p.nubLength,
      angle: p.angle,
      bearing: p.bearing,
      offScreen: p.offScreen,
      lastSeen: p.lastSeen,
      onTap: p.onTap,
      tapOffset: p.tapOffset,
      exiting: p.exiting,
      onExitComplete: p.onExitComplete,
    );
  }

  /// Returns adjusted bubble centres keyed by pubkey, separating off-screen
  /// bubbles on the same edge so their 48dp tap targets don't overlap.
  Map<String, Offset> _spread(List<_MarkerEntry> entries, Rect safe) {
    final result = <String, Offset>{
      for (final e in entries) e.member.pubkey: e.projection.bubbleCenter,
    };

    // Bucket by the safe-rect edge each bubble is clamped to.
    // 0 = top, 1 = bottom, 2 = left, 3 = right.
    final byEdge = <int, List<_MarkerEntry>>{};
    for (final e in entries) {
      final h = e.projection.bubbleCenter;
      final distances = <double>[
        (h.dy - safe.top).abs(),
        (safe.bottom - h.dy).abs(),
        (h.dx - safe.left).abs(),
        (safe.right - h.dx).abs(),
      ];
      var edge = 0;
      var best = distances[0];
      for (var i = 1; i < distances.length; i++) {
        if (distances[i] < best) {
          best = distances[i];
          edge = i;
        }
      }
      byEdge.putIfAbsent(edge, () => <_MarkerEntry>[]).add(e);
    }

    for (final group in byEdge.entries) {
      final horizontal = group.key == 0 || group.key == 1;
      final list = group.value
        ..sort((a, b) {
          final pa = horizontal
              ? a.projection.bubbleCenter.dx
              : a.projection.bubbleCenter.dy;
          final pb = horizontal
              ? b.projection.bubbleCenter.dx
              : b.projection.bubbleCenter.dy;
          final cmp = pa.compareTo(pb);
          return cmp != 0 ? cmp : a.member.pubkey.compareTo(b.member.pubkey);
        });

      final lo = horizontal ? safe.left : safe.top;
      final hi = horizontal ? safe.right : safe.bottom;
      double? prevPos;
      double? prevTapHalf;
      for (final e in list) {
        final h = e.projection.bubbleCenter;
        final radius = e.projection.diameter / 2;
        // Separate by the 48dp tap-target size, not the visual radius, so
        // adjacent hit-boxes don't overlap and taps stay unambiguous.
        final tapHalf = math.max(e.projection.diameter, kMinTapTarget) / 2;
        var pos = horizontal ? h.dx : h.dy;
        if (prevPos != null && prevTapHalf != null) {
          final minGap = prevTapHalf + tapHalf;
          if (pos - prevPos < minGap) pos = prevPos + minGap;
        }
        if (hi - radius > lo + radius) {
          pos = pos.clamp(lo + radius, hi - radius);
        }
        prevPos = pos;
        prevTapHalf = tapHalf;
        result[e.member.pubkey] = horizontal
            ? Offset(pos, h.dy)
            : Offset(h.dx, pos);
      }
    }
    return result;
  }
}

/// Immutable struct that carries the non-avatar properties of one marker so
/// they can be forwarded from `_MemberMarkersLayerState._positioned` to both
/// the direct [MemberMarker] path and [_AvatarLoader] without repeating the
/// argument list twice.
class _MarkerProps {
  const _MarkerProps({
    required this.initials,
    required this.publicKey,
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.bearing,
    required this.offScreen,
    required this.tapOffset,
    required this.exiting,
    this.displayName,
    this.lastSeen,
    this.onTap,
    this.onExitComplete,
  });

  final String initials;
  final String publicKey;
  final String? displayName;
  final double diameter;
  final double nubLength;
  final double angle;
  final double bearing;
  final bool offScreen;
  final DateTime? lastSeen;
  final VoidCallback? onTap;
  final Offset tapOffset;

  /// Whether this marker is fading out after leaving the selected circle.
  final bool exiting;

  /// Invoked once the exit transition completes (only set while [exiting]).
  final VoidCallback? onExitComplete;
}

/// Watches `memberProfileProvider(pubkeyHex)`, decodes
/// `Profile.pictureBytes` into a [ui.Image] via [AvatarImageCache], and
/// re-renders [MemberMarker] with the decoded image (or initials fallback
/// while loading / on error / when no picture is known).
///
/// Decoding is done exactly once per unique `Profile.pictureHash` —
/// subsequent rebuilds (e.g. from camera pans) hit the cache immediately.
class _AvatarLoader extends ConsumerStatefulWidget {
  const _AvatarLoader({
    required this.pubkeyHex,
    required this.markerProps,
    super.key,
  });

  /// The member's pubkey hex — the plain-string key `memberProfileProvider`
  /// resolves by (D6: no MLS group ID component).
  final String pubkeyHex;

  final _MarkerProps markerProps;

  @override
  ConsumerState<_AvatarLoader> createState() => _AvatarLoaderState();
}

class _AvatarLoaderState extends ConsumerState<_AvatarLoader> {
  /// The [AvatarImageCache.keyFor] key currently being decoded, so a decode is
  /// scheduled at most once per key rather than on every rebuild (the layer
  /// rebuilds on every camera frame). `null` when no decode is in flight.
  String? _decodingHash;

  @override
  void initState() {
    super.initState();
    // Rebuild when the cache evicts/clears (LRU eviction or background clear)
    // so we drop any reference to a now-disposed image and re-read the cache.
    // Without this, a cleared image would keep painting until an unrelated
    // rebuild — the prior use-after-dispose crash.
    AvatarImageCache.instance.addListener(_onCacheChanged);
  }

  @override
  void dispose() {
    AvatarImageCache.instance.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  /// Decodes [bytes] with its short side at [targetPx] and stores the result
  /// under [key] in [AvatarImageCache].
  ///
  /// The decoded [ui.Image] is owned by [AvatarImageCache], which disposes it
  /// on LRU eviction and on background [AvatarImageCache.clear]. This state
  /// NEVER holds a long-lived reference to it — [build] reads the image back
  /// from the cache each frame — so a cache eviction can never leave us
  /// painting a disposed image (the prior use-after-dispose bug).
  Future<void> _decodeBytes(String key, int targetPx, List<int> bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        Uint8List.fromList(bytes),
      );
      // The engine disposes the buffer itself once it has read the intrinsic
      // size (a second dispose asserts), so only a failure before that point
      // leaves it ours to release.
      var sized = false;
      final ui.Codec codec;
      try {
        codec = await ui.instantiateImageCodecWithSize(
          buffer,
          // `min` is what prevents upscaling: the API itself would enlarge a
          // source smaller than the target. Setting one dimension keeps the
          // aspect ratio.
          getTargetSize: (intrinsicWidth, intrinsicHeight) {
            sized = true;
            final px = math.min(
              targetPx,
              math.min(intrinsicWidth, intrinsicHeight),
            );
            return intrinsicWidth <= intrinsicHeight
                ? ui.TargetImageSize(width: px)
                : ui.TargetImageSize(height: px);
          },
        );
      } on Object {
        if (!sized) buffer.dispose();
        rethrow;
      }
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      // Content-addressed: store under `key` even if the member's avatar has
      // since changed (a valid, reusable entry). `build` always reads the
      // CURRENT key from the cache, so a stale decode never displays.
      AvatarImageCache.instance.put(key, frame.image);
      setState(() {}); // rebuild to read the now-cached image
    } on Object catch (e) {
      // Decode failure → fall back to initials (no raw error in the UI).
      debugPrint('[AvatarLoader] decode failed: ${e.runtimeType}');
    } finally {
      if (_decodingHash == key) _decodingHash = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref
        .watch(memberProfileProvider(widget.pubkeyHex))
        .valueOrNull;
    final hash = profile?.pictureHash;
    final targetPx =
        (kDropletFullDiameter * MediaQuery.devicePixelRatioOf(context)).ceil();

    // The cache is the SINGLE source of truth for the decoded image: we never
    // hold our own `ui.Image` reference, because the cache disposes images on
    // LRU eviction and on background clear (defeats use-after-dispose). On a
    // miss, (re)decode exactly once per key — `_decodingHash` guards against a
    // per-frame decode storm while one is in flight. No known picture (`hash`
    // null) means no cache lookup and no decode — initials fallback.
    ui.Image? image;
    if (hash != null) {
      final key = AvatarImageCache.keyFor(hash, targetPx);
      image = AvatarImageCache.instance.get(key);
      final bytes = profile?.pictureBytes;
      if (image == null &&
          _decodingHash != key &&
          bytes != null &&
          bytes.isNotEmpty) {
        _decodingHash = key;
        // Decode outside the synchronous build frame.
        Future.microtask(() => _decodeBytes(key, targetPx, bytes));
      }
    }

    final p = widget.markerProps;
    // The fetch-time name is resolved once per location poll; a profile the
    // refresh resolved since then must not wait for the next one.
    final profileName = resolveEffectiveMemberName(
      npubFallback: '',
      profile: profile,
    );
    final name = p.displayName ?? (profileName.isEmpty ? null : profileName);
    return MemberMarker(
      key: WidgetKeys.memberMarker(p.publicKey),
      initials: markerInitials(name, p.publicKey),
      publicKey: p.publicKey,
      displayName: name,
      diameter: p.diameter,
      nubLength: p.nubLength,
      angle: p.angle,
      bearing: p.bearing,
      offScreen: p.offScreen,
      lastSeen: p.lastSeen,
      onTap: p.onTap,
      tapOffset: p.tapOffset,
      avatarImage: image,
      exiting: p.exiting,
      onExitComplete: p.onExitComplete,
    );
  }
}
