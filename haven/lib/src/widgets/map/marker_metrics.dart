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

/// One initials-disc palette entry: a barely-visible vertical gradient from
/// [top] to [bottom] (screen space).
class AvatarPaletteEntry {
  /// Creates a palette entry.
  const AvatarPaletteEntry({required this.top, required this.bottom});

  /// Colour at the disc's top edge.
  final Color top;

  /// Colour at the disc's bottom edge.
  final Color bottom;
}

/// The eight initials-disc colours: OKLCH hues 20° + 45°·k, lightness 0.52 at
/// the top and 0.45 at the bottom, chroma 0.10 unless an entry's comment says
/// it was reduced to fit sRGB. Every stop holds white text at >= 4.5:1.
const List<AvatarPaletteEntry> kAvatarPalette = [
  AvatarPaletteEntry(
    // h 20: top L0.52 C0.10, bottom L0.45 C0.10
    top: Color(0xFF9A4F51),
    bottom: Color(0xFF843B3E),
  ),
  AvatarPaletteEntry(
    // h 65: top L0.52 C0.10, bottom L0.45 C0.10
    top: Color(0xFF905B20),
    bottom: Color(0xFF7A4702),
  ),
  AvatarPaletteEntry(
    // h 110: top L0.52 C0.10, bottom L0.45 C0.098 (reduced to fit sRGB)
    top: Color(0xFF6D6E1D),
    bottom: Color(0xFF595901),
  ),
  AvatarPaletteEntry(
    // h 155: top L0.52 C0.10, bottom L0.45 C0.10
    top: Color(0xFF307A4F),
    bottom: Color(0xFF17653C),
  ),
  AvatarPaletteEntry(
    // h 200: top L0.52 C0.088, bottom L0.45 C0.0765 (reduced to fit sRGB)
    top: Color(0xFF02787D),
    bottom: Color(0xFF006266),
  ),
  AvatarPaletteEntry(
    // h 245: top L0.52 C0.10, bottom L0.45 C0.10
    top: Color(0xFF2F6E9E),
    bottom: Color(0xFF185A89),
  ),
  AvatarPaletteEntry(
    // h 290: top L0.52 C0.10, bottom L0.45 C0.10
    top: Color(0xFF685E9E),
    bottom: Color(0xFF554A88),
  ),
  AvatarPaletteEntry(
    // h 335: top L0.52 C0.10, bottom L0.45 C0.10
    top: Color(0xFF8C5180),
    bottom: Color(0xFF763E6B),
  ),
];

/// Colour of initials on every [kAvatarPalette] disc.
const Color kAvatarInitialsColor = Colors.white;

/// Palette slot for [publicKey]: its first byte mod 8.
///
/// The first byte of a pubkey is stable across launches, devices and SDK
/// versions (unlike `String.hashCode`) and reveals only 3 bits of an already
/// public key. A key without a hex first byte falls back to a code-unit sum
/// so the function is total.
int avatarPaletteIndex(String publicKey) {
  final byte = publicKey.length >= 2
      ? int.tryParse(publicKey.substring(0, 2), radix: 16)
      : null;
  if (byte != null) return byte % 8;
  return publicKey.codeUnits.fold(0, (a, b) => (a + b) % 8);
}

/// The palette entry for [publicKey]; every avatar and the map marker use it.
AvatarPaletteEntry avatarPaletteFor(String publicKey) =>
    kAvatarPalette[avatarPaletteIndex(publicKey)];

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
