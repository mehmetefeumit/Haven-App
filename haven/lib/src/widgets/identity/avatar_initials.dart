/// Grapheme-safe initials derivation for avatars and identity chrome.
library;

import 'package:flutter/widgets.dart';

/// Derives 1-2 grapheme-safe initials from [displayName].
///
/// Handles multi-byte Unicode, emoji, ZWJ sequences, and flag glyphs
/// correctly by iterating grapheme clusters via `String.characters`.
/// Returns `'?'` when [displayName] is null, empty, or whitespace-only.
///
/// Never slices an npub: callers must pass the display name, not the public
/// key (the npub `'1'` separator at index 4 would otherwise read as a
/// meaningless glyph).
String avatarInitials(String? displayName) {
  final name = displayName?.trim();
  if (name == null || name.isEmpty) return '?';
  final parts = name.split(RegExp(r'\s+'));
  if (parts.length >= 2) {
    final first = parts.first.characters.first;
    final last = parts.last.characters.first;
    return (first + last).toUpperCase();
  }
  return name.characters.first.toUpperCase();
}
