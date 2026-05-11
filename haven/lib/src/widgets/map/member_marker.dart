/// Member marker widget for Haven map.
///
/// Displays a circle member's location with avatar and an age pill showing
/// how long ago the data was recorded. Emits a soft one-shot pulse when a
/// fresher timestamp arrives — a silent "new data" cue that the user reads
/// subconsciously without announcing itself.
library;

import 'dart:math' show max;

import 'package:flutter/material.dart';

/// Formats a [Duration] into a compact age string for the visible pill.
///
/// Returns `null` for ages under one minute — fresh data reads as "no pill"
/// rather than "just now", which would otherwise be visual noise on every
/// marker for the common case.
///
/// Branches:
/// - `< 1 minute` → `null` (no pill rendered)
/// - `< 60 minutes` → `"Xm"`
/// - `< 24 hours` → `"Xh"`
/// - `≥ 24 hours` → `"Xd"`
String? _formatAge(Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 24) return '${age.inHours}h';
  return '${age.inDays}d';
}

/// Formats a [Duration] into an expanded age string for screen readers.
///
/// Returns `null` for ages under one minute so the semantics label omits the
/// "last seen" clause entirely — parity with the visible pill being hidden.
/// Screen readers pronounce "5m" as "five em" and "2h" as "two aitch"; the
/// expanded form reads naturally via VoiceOver/TalkBack. Singular units are
/// handled separately so speech is grammatical ("1 minute ago", not
/// "1 minutes ago").
String? _formatAgeForSemantics(Duration age) {
  if (age.inMinutes < 1) return null;
  if (age.inMinutes < 60) {
    return age.inMinutes == 1 ? '1 minute ago' : '${age.inMinutes} minutes ago';
  }
  if (age.inHours < 24) {
    return age.inHours == 1 ? '1 hour ago' : '${age.inHours} hours ago';
  }
  return age.inDays == 1 ? '1 day ago' : '${age.inDays} days ago';
}

/// A marker showing a circle member's location on the map.
///
/// Features:
/// - Avatar display with initials fallback
/// - Neutral outline ring (same color regardless of data age)
/// - Age pill in the bottom-right corner showing time since last update
/// - Minimum 48dp touch target for accessibility
/// - One-shot pulse when [lastSeen] advances to a newer timestamp
class MemberMarker extends StatefulWidget {
  /// Creates a member marker.
  const MemberMarker({
    required this.initials,
    super.key,
    this.imageUrl,
    this.publicKey,
    this.size = 44,
    this.lastSeen,
    this.onTap,
  });

  /// Initials to display (1-2 characters).
  final String initials;

  /// Optional profile image URL.
  final String? imageUrl;

  /// Public key for generating consistent avatar color.
  final String? publicKey;

  /// Size of the marker in logical pixels.
  final double size;

  /// Timestamp the location was originally recorded.
  ///
  /// Used to compute the age pill label ("5m", "2h", etc.) and to detect
  /// "newer data arrived" for the pulse. When null, no pill is rendered
  /// and the pulse never fires.
  final DateTime? lastSeen;

  /// Callback when the marker is tapped.
  final VoidCallback? onTap;

  /// Key on the pulse layer widget. Tests use this to assert pulse
  /// presence/absence without relying on private types.
  @visibleForTesting
  static const Key pulseLayerKey = Key('member_marker_pulse_layer');

  /// Total pulse duration. Short enough to stay in the user's peripheral
  /// vision without registering consciously.
  static const Duration _pulseDuration = Duration(milliseconds: 800);

  /// Maximum scale reached at the end of the pulse. The pulse starts at
  /// `1.0` (matching the outline ring) and expands outward to this factor.
  static const double _pulseMaxScale = 1.4;

  /// Alpha at the start of the pulse. Linearly fades to `0` at completion.
  static const double _pulseStartAlpha = 0.35;

  @override
  State<MemberMarker> createState() => _MemberMarkerState();
}

class _MemberMarkerState extends State<MemberMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// The `lastSeen` value for which we have already rendered (or chosen
  /// not to render) a pulse. Initialized to the widget's initial value so
  /// the first mount does not pulse — a pulse fires only on **strictly
  /// newer** timestamps that arrive while the widget is on screen.
  DateTime? _seenLastSeen;

  /// `MediaQuery.disableAnimations`, resolved in `didChangeDependencies`.
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: MemberMarker._pulseDuration,
      vsync: this,
    );
    _seenLastSeen = widget.lastSeen;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // If the user enables Reduce Motion mid-pulse, stop the in-flight
    // animation immediately (Apple HIG Motion: honour live toggles).
    if (_reduceMotion && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didUpdateWidget(MemberMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeFirePulse();
  }

  /// Plays the pulse when [MemberMarker.lastSeen] has advanced past the
  /// most recently seen value. Also absorbs regressions / same-timestamp
  /// rebuilds without firing, and respects reduced-motion.
  void _maybeFirePulse() {
    final lastSeen = widget.lastSeen;
    if (lastSeen == null) return;
    final prev = _seenLastSeen;
    if (prev != null && !lastSeen.isAfter(prev)) return;
    _seenLastSeen = lastSeen;
    if (_reduceMotion) return;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _generateAvatarColor(ColorScheme scheme) {
    final pk = widget.publicKey;
    if (pk == null || pk.isEmpty) {
      return scheme.surfaceContainerHigh;
    }
    final hue = (pk.hashCode % 360).abs().toDouble();
    // Desaturated tint — quiet identifier, not louder than the chrome.
    return HSLColor.fromAHSL(1, hue, 0.35, 0.55).toColor();
  }

  /// Picks a foreground that meets contrast against [bg] for either polarity.
  Color _onAvatarColor(Color bg) =>
      bg.computeLuminance() > 0.5 ? const Color(0xFF0A0A0A) : Colors.white;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final ringDiameter = widget.size + 8;

    // Ensure minimum 48dp touch target for accessibility.
    final touchTargetSize = max<double>(ringDiameter, 48);

    // Compute age once per build so the visible pill and the screen-reader
    // label cannot drift across a minute boundary.
    final age = widget.lastSeen != null
        ? DateTime.now().difference(widget.lastSeen!)
        : null;
    final agePillLabel = age != null ? _formatAge(age) : null;
    final semanticsAge = age != null ? _formatAgeForSemantics(age) : null;
    final semanticsLabel = semanticsAge != null
        ? '${widget.initials} member marker, last seen $semanticsAge'
        : '${widget.initials} member marker';

    // Cap text scaling so Dynamic Type cannot blow the pill label out of
    // the marker footprint. 1.3× still benefits low-vision users.
    final pillTextScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3);

    // Outer footprint must accommodate the pulse at its maximum scale so
    // the Stack does not clip it. `clipBehavior: Clip.none` on the Stack
    // is belt-and-braces in case an ancestor grows smaller than expected.
    final outerSize = ringDiameter * MemberMarker._pulseMaxScale;

    final markerBody = SizedBox(
      width: outerSize,
      height: outerSize,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Pulse layer — rendered behind the outline ring. Invisible when
          // the controller is dismissed/completed; only drawn during the
          // 800 ms forward phase.
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              if (_controller.status != AnimationStatus.forward) {
                return const SizedBox.shrink();
              }
              final t = Curves.easeOut.transform(_controller.value);
              final scale = 1.0 + t * (MemberMarker._pulseMaxScale - 1.0);
              final alpha = MemberMarker._pulseStartAlpha * (1 - t);
              final diameter = ringDiameter * scale;
              return IgnorePointer(
                child: Container(
                  key: MemberMarker.pulseLayerKey,
                  width: diameter,
                  height: diameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // Use a neutral outline tone so the pulse reads with
                    // symmetric salience across light and dark themes —
                    // primary inverts brightness between modes and would
                    // make the dark-mode pulse far more attention-grabbing
                    // on the same map tiles.
                    color: colorScheme.outline.withValues(alpha: alpha),
                  ),
                ),
              );
            },
          ),

          // Neutral outline ring — identical appearance regardless of data age.
          Container(
            width: ringDiameter,
            height: ringDiameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: colorScheme.outline, width: 3),
            ),
          ),

          // Avatar
          Builder(
            builder: (context) {
              final avatarBg = _generateAvatarColor(colorScheme);
              return Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: avatarBg,
                  border: Border.all(color: colorScheme.surface, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: _buildAvatarContent(context, avatarBg),
              );
            },
          ),

          // Age pill — anchored to the ring corner (not the outer pulse
          // footprint), so it reads as part of the avatar, not floating in
          // the outer padding.
          if (agePillLabel != null)
            Positioned(
              width: ringDiameter,
              height: ringDiameter,
              child: Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: colorScheme.outline),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    agePillLabel,
                    textScaler: pillTextScaler,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurfaceVariant,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // `excludeSemantics: true` prevents the visible initials Text and the
    // age pill Text from being appended to the authored label. Both are
    // already conveyed in `semanticsLabel`, so without this screen readers
    // would announce "<initials> member marker, last seen X. <initials>. X"
    // — redundant and confusing.
    return Semantics(
      label: semanticsLabel,
      button: widget.onTap != null,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: max<double>(touchTargetSize, outerSize),
          height: max<double>(touchTargetSize, outerSize),
          child: Center(child: markerBody),
        ),
      ),
    );
  }

  Widget _buildAvatarContent(BuildContext context, Color avatarBg) {
    final url = widget.imageUrl;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildInitials(avatarBg),
        ),
      );
    }
    return _buildInitials(avatarBg);
  }

  Widget _buildInitials(Color avatarBg) {
    final displayInitials = widget.initials.toUpperCase().substring(
      0,
      widget.initials.length > 2 ? 2 : widget.initials.length,
    );

    return Center(
      child: Text(
        displayInitials,
        style: TextStyle(
          color: _onAvatarColor(avatarBg),
          fontSize: widget.size * 0.35,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
