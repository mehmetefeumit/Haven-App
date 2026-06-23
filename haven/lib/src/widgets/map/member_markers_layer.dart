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
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/member_avatar_provider.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart';
import 'package:haven/src/widgets/map/avatar_image_cache.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';
import 'package:haven/src/widgets/map/member_marker.dart';
import 'package:latlong2/latlong.dart';

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
/// When [mlsGroupId] is non-null the layer resolves each member's avatar
/// thumbnail via [memberAvatarThumbnailProvider] and paints it inside the
/// head circle, falling back to initials while loading or on error.
class MemberMarkersLayer extends StatelessWidget {
  /// Creates a [MemberMarkersLayer].
  const MemberMarkersLayer({
    required this.members,
    required this.bottomInset,
    required this.onFocusMember,
    this.onMarkerTap,
    this.mlsGroupId,
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

  /// MLS group ID of the currently selected circle.  When non-null the layer
  /// fetches each member's avatar thumbnail from
  /// [memberAvatarThumbnailProvider] and passes a decoded [ui.Image] to
  /// [MemberMarker].  When null (e.g. no circle selected, or in tests that
  /// do not provide the provider) avatars are skipped and initials are shown.
  final List<int>? mlsGroupId;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final scheme = Theme.of(context).colorScheme;
    final topInset = MediaQuery.maybeOf(context)?.viewPadding.top ?? 0;
    final viewport = edgeViewport(
      viewport: camera.nonRotatedSize,
      topInset: topInset,
      bottomInset: bottomInset,
    );

    final entries = <_MarkerEntry>[];
    for (final member in members) {
      final point = camera.latLngToScreenOffset(
        LatLng(member.latitude, member.longitude),
      );
      entries.add(
        _MarkerEntry(
          member: member,
          point: point,
          projection: projectMarker(point: point, viewport: viewport),
        ),
      );
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    // Nudge overlapping OFF-SCREEN bubbles apart along their edge. On-screen
    // bubbles sit exactly on the member's point and are never moved.
    final spread = _spread(
      entries.where((e) => e.projection.offScreen).toList(),
      viewport.safeRect,
    );

    // Draw far (small) bubbles first so nearer/larger ones sit on top.
    entries.sort(
      (a, b) => a.projection.diameter.compareTo(b.projection.diameter),
    );

    return ClipRect(
      child: Stack(
        key: WidgetKeys.memberMarkersLayer,
        clipBehavior: Clip.none,
        children: [
          for (final entry in entries)
            _positioned(
              entry,
              spread[entry.member.pubkey],
              scheme,
              viewport.safeRect,
            ),
        ],
      ),
    );
  }

  Widget _positioned(
    _MarkerEntry entry,
    Offset? spreadCenter,
    ColorScheme scheme,
    Rect safeRect,
  ) {
    final member = entry.member;
    final proj = entry.projection;
    final center = spreadCenter ?? proj.bubbleCenter;

    // Re-aim the tail at the member's true point if spreading moved the bubble.
    var nubLength = proj.nubLength;
    var angle = proj.angle;
    final point = entry.point;
    if (point.dx.isFinite && point.dy.isFinite && center != proj.bubbleCenter) {
      final tip = point - center;
      final dist = tip.distance;
      nubLength = math.min(dist, kDropletMaxNub);
      angle = dist < 1e-3 ? 0 : tip.direction;
    }

    final footprint = MemberMarker.footprintFor(proj.diameter);
    final tapOffset = proj.offScreen
        ? tapTargetCenter(
                bubbleCenter: center,
                diameter: proj.diameter,
                safeRect: safeRect,
              ) -
              center
        : Offset.zero;
    // Off-screen markers recenter the map; on-screen ones use the per-marker
    // tap (iOS Apple Maps) or are non-interactive on Android.
    final tap = onMarkerTap;
    final onTap = proj.offScreen
        ? () => onFocusMember(member)
        : (tap != null ? () => tap(member) : null);

    final markerProps = _MarkerProps(
      initials: markerInitials(member.displayName, member.pubkey),
      publicKey: member.pubkey,
      displayName: member.displayName,
      fillColor: avatarHue(member.pubkey, scheme),
      haloColor: scheme.surface,
      diameter: proj.diameter,
      nubLength: nubLength,
      angle: angle,
      offScreen: proj.offScreen,
      lastSeen: member.timestamp,
      onTap: onTap,
      tapOffset: tapOffset,
    );

    final groupId = mlsGroupId;
    final contentHash = member.avatarContentHash;

    final child = groupId != null && contentHash != null
        ? _AvatarLoader(
            key: ValueKey<String>('avatar_loader_${member.pubkey}'),
            avatarKey: MemberAvatarKey(
              mlsGroupId: groupId,
              pubkeyHex: member.pubkey,
            ),
            contentHash: contentHash,
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
      fillColor: p.fillColor,
      haloColor: p.haloColor,
      diameter: p.diameter,
      nubLength: p.nubLength,
      angle: p.angle,
      offScreen: p.offScreen,
      lastSeen: p.lastSeen,
      onTap: p.onTap,
      tapOffset: p.tapOffset,
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
/// they can be forwarded from [MemberMarkersLayer._positioned] to both the
/// direct [MemberMarker] path and [_AvatarLoader] without repeating the
/// argument list twice.
class _MarkerProps {
  const _MarkerProps({
    required this.initials,
    required this.publicKey,
    required this.fillColor,
    required this.haloColor,
    required this.diameter,
    required this.nubLength,
    required this.angle,
    required this.offScreen,
    required this.tapOffset,
    this.displayName,
    this.lastSeen,
    this.onTap,
  });

  final String initials;
  final String publicKey;
  final String? displayName;
  final Color fillColor;
  final Color haloColor;
  final double diameter;
  final double nubLength;
  final double angle;
  final bool offScreen;
  final DateTime? lastSeen;
  final VoidCallback? onTap;
  final Offset tapOffset;
}

/// Watches [memberAvatarThumbnailProvider], decodes the thumbnail into a
/// [ui.Image] via [AvatarImageCache], and re-renders [MemberMarker] with the
/// decoded image (or initials fallback while loading / on error).
///
/// Decoding is done exactly once per unique [contentHash] — subsequent
/// rebuilds (e.g. from camera pans) hit the cache immediately.
class _AvatarLoader extends ConsumerStatefulWidget {
  const _AvatarLoader({
    required this.avatarKey,
    required this.contentHash,
    required this.markerProps,
    super.key,
  });

  final MemberAvatarKey avatarKey;

  /// Change-token: when this changes the widget re-fetches and re-decodes.
  final String contentHash;

  final _MarkerProps markerProps;

  @override
  ConsumerState<_AvatarLoader> createState() => _AvatarLoaderState();
}

class _AvatarLoaderState extends ConsumerState<_AvatarLoader> {
  /// The content-hash currently being decoded, so a decode is scheduled at
  /// most once per hash rather than on every rebuild (the layer rebuilds on
  /// every camera frame). `null` when no decode is in flight.
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

  /// Decodes [bytes] for [hash] and stores the result in [AvatarImageCache].
  ///
  /// The decoded [ui.Image] is owned by [AvatarImageCache], which disposes it
  /// on LRU eviction and on background [AvatarImageCache.clear]. This state
  /// NEVER holds a long-lived reference to it — [build] reads the image back
  /// from the cache each frame — so a cache eviction can never leave us
  /// painting a disposed image (the prior use-after-dispose bug).
  Future<void> _decodeBytes(String hash, List<int> bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      // Content-addressed: store under `hash` even if the member's avatar has
      // since changed (a valid, reusable entry). `build` always reads the
      // CURRENT hash from the cache, so a stale decode never displays.
      AvatarImageCache.instance.put(hash, frame.image);
      setState(() {}); // rebuild to read the now-cached image
    } on Object catch (e) {
      // Decode failure → fall back to initials (no raw error in the UI).
      debugPrint('[AvatarLoader] decode failed: ${e.runtimeType}');
    } finally {
      if (_decodingHash == hash) _decodingHash = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncBytes = ref.watch(
      memberAvatarThumbnailProvider(widget.avatarKey),
    );

    // The cache is the SINGLE source of truth for the decoded image: we never
    // hold our own `ui.Image` reference, because the cache disposes images on
    // LRU eviction and on background clear (defeats use-after-dispose). On a
    // miss, (re)decode exactly once per hash — `_decodingHash` guards against a
    // per-frame decode storm while one is in flight.
    final hash = widget.contentHash;
    final image = AvatarImageCache.instance.get(hash);
    if (image == null && _decodingHash != hash) {
      if (asyncBytes case AsyncData(:final value)) {
        if (value != null && value.isNotEmpty) {
          _decodingHash = hash;
          // Decode outside the synchronous build frame.
          Future.microtask(() => _decodeBytes(hash, value));
        }
      }
    }

    final p = widget.markerProps;
    return MemberMarker(
      key: WidgetKeys.memberMarker(p.publicKey),
      initials: p.initials,
      publicKey: p.publicKey,
      displayName: p.displayName,
      fillColor: p.fillColor,
      haloColor: p.haloColor,
      diameter: p.diameter,
      nubLength: p.nubLength,
      angle: p.angle,
      offScreen: p.offScreen,
      lastSeen: p.lastSeen,
      onTap: p.onTap,
      tapOffset: p.tapOffset,
      avatarImage: image,
    );
  }
}
