/// Shared geometry constants and presentation helpers for the circle-member
/// map marker.
///
/// The unified [MemberMarker] (a clean circle in view that grows a teardrop
/// tail toward a member's true location as they near/leave the edge) and the
/// marker geometry both read these, so a member's size and hue are a single
/// source of truth and read the same everywhere on the map.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Diameter of a marker's avatar disc, in logical pixels.
const double kAvatarSize = 44;

/// Diameter of a marker bubble at full (on-screen) size — the avatar plus an
/// 8dp surround. Equals `kDropletFullDiameter` in `marker_geometry.dart`
/// (a test guards the match) so the on-screen and edge sizes are identical.
const double kRingDiameter = kAvatarSize + 8;

/// Returns a desaturated avatar colour derived from [publicKey].
///
/// The same hue identifies a member at every size — full circle in view or
/// tiny edge droplet. The hue is a quiet identifier, not a stable per-member
/// brand: it derives from `String.hashCode`, which Dart randomises per isolate
/// run, so the same pubkey may map to a different hue across app launches.
/// Falls back to a neutral surface tone when no key is available.
Color avatarHue(String? publicKey, ColorScheme scheme) {
  if (publicKey == null || publicKey.isEmpty) {
    return scheme.surfaceContainerHigh;
  }
  final hue = (publicKey.hashCode % 360).abs().toDouble();
  // Desaturated tint — a quiet identifier, not louder than the chrome.
  return HSLColor.fromAHSL(1, hue, 0.35, 0.55).toColor();
}

/// Returns the foreground colour (black or white) with the higher WCAG
/// contrast ratio against [background].
///
/// Picking by max contrast (rather than a luminance threshold), with pure
/// black as the dark option, guarantees at least ~4.58:1 against any
/// background — clearing WCAG AA (4.5:1) for the small initials at every
/// per-member hue.
Color onAvatarColor(Color background) {
  final bg = background.computeLuminance();
  return _contrast(bg, 1) >= _contrast(bg, 0) ? Colors.white : Colors.black;
}

/// WCAG contrast ratio between two relative luminances.
double _contrast(double a, double b) {
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

/// Derives 1–2 display initials from a [displayName] or, failing that, a
/// [pubkey].
///
/// Two words yield their leading grapheme clusters ("Jane Doe" → "JD", "🎉
/// Alice" → "🎉A"), a single word yields its first grapheme cluster, and a
/// nameless member falls back to the first two hex characters of the pubkey.
/// Case is preserved; uppercasing is left to [markerGlyph].
String markerInitials(String? displayName, String pubkey) {
  final name = displayName?.trim();
  if (name != null && name.isNotEmpty) {
    final parts = name.split(' ');
    if (parts.length >= 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
      return '${parts.first.characters.first}${parts.last.characters.first}';
    }
    return name.characters.first;
  }
  return pubkey.length >= 2 ? pubkey.substring(0, 2) : pubkey;
}

/// Trims [initials] to the glyph(s) shown at a bubble of [diameter], upper-
/// cased, never splitting a multi-code-unit grapheme (emoji, flags, combining
/// marks). One glyph while small; a second once the bubble has room.
String markerGlyph(String initials, double diameter) {
  if (initials.isEmpty) return '';
  final graphemes = initials.toUpperCase().characters;
  final count = diameter >= 40 ? math.min(2, graphemes.length) : 1;
  return graphemes.take(count).string;
}
