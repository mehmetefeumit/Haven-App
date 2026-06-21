/// Shared geometry constants and presentation helpers for circle-member
/// markers.
///
/// Both the on-map [MemberMarker] and the off-screen edge "droplet"
/// (`EdgeMemberIndicator`) read these so their size, hue, and initials can
/// never drift apart. The seamless hand-off between the two — a droplet
/// growing into a full marker exactly as a member pans into view — depends on
/// the droplet reaching the marker's dimensions and colour at the viewport
/// edge, so these values are the single source of truth for both.
library;

import 'package:flutter/material.dart';

/// Diameter of a member marker's avatar disc, in logical pixels.
const double kAvatarSize = 44;

/// Diameter of the halo ring that wraps the avatar disc (avatar + 8dp).
const double kRingDiameter = kAvatarSize + 8;

/// Maximum scale the marker's one-shot "new data" pulse reaches.
const double kPulseMaxScale = 1.4;

/// Visible height of the marker's downward tail below the bubble.
const double kTailVisibleHeight = 16;

/// Width of the marker's tail where it meets the bubble.
const double kTailBaseWidth = 14;

/// Vertical distance, in logical pixels, from the geographic point a marker
/// anchors to (its tail tip) up to the centre of its avatar disc.
///
/// A [MemberMarker] is laid out with `Alignment.topCenter` so its tail tip
/// sits on the coordinate; the avatar centre is half the pulse extent above
/// that tip (`kRingDiameter * kPulseMaxScale / 2`). The edge droplet anchors
/// its head to this same avatar-centre point so that, at the instant a member
/// crosses into view, the droplet and the real marker's avatar coincide
/// exactly — there is no positional "pop" at the hand-off.
const double kAvatarCenterLift = kRingDiameter * kPulseMaxScale / 2; // 36.4

/// Returns a desaturated avatar colour derived from [publicKey].
///
/// The same hue is used for the marker's avatar disc, its tail, and the
/// off-screen droplet, so a member reads as "the same colour" everywhere
/// within a session. The hue is a quiet identifier, not a stable per-member
/// brand: it derives from `String.hashCode`, which Dart randomises per
/// isolate run, so the same pubkey may map to a different hue across app
/// launches. (Pre-existing behaviour shared with the on-map marker.) Falls
/// back to a neutral surface tone when no key is available.
Color avatarHue(String? publicKey, ColorScheme scheme) {
  if (publicKey == null || publicKey.isEmpty) {
    return scheme.surfaceContainerHigh;
  }
  final hue = (publicKey.hashCode % 360).abs().toDouble();
  // Desaturated tint — a quiet identifier, not louder than the chrome.
  return HSLColor.fromAHSL(1, hue, 0.35, 0.55).toColor();
}

/// Returns a foreground colour that meets contrast against [background] for
/// either a light or a dark avatar fill.
Color onAvatarColor(Color background) => background.computeLuminance() > 0.5
    ? const Color(0xFF0A0A0A)
    : Colors.white;

/// Derives 1–2 display initials from a [displayName] or, failing that, a
/// [pubkey].
///
/// Mirrors the rule the map has always used: two words yield their leading
/// letters ("Jane Doe" → "JD"), a single word yields its first letter, and a
/// nameless member falls back to the first two hex characters of the pubkey.
String markerInitials(String? displayName, String pubkey) {
  if (displayName != null && displayName.isNotEmpty) {
    final parts = displayName.trim().split(' ');
    if (parts.length >= 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
      return '${parts.first[0]}${parts.last[0]}';
    }
    return displayName[0];
  }
  return pubkey.length >= 2 ? pubkey.substring(0, 2) : pubkey;
}
