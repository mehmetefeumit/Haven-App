/// The circular avatar shown for one person, wherever Haven lists people.
///
/// Extracted from `circle_member_tile.dart` so the member list and the invite
/// picker cannot drift on the rule that matters here: **no shimmer while a
/// picture loads.** A shimmer where a face is about to appear tells a
/// bystander looking over the user's shoulder that a picture is incoming, and
/// on the picker it would do so once per row for a whole roster.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/widgets/identity/avatar.dart';

/// Diameter (logical px) shared by both member-avatar branches so the image
/// avatar and the initials [CircleAvatar] are always rendered at the same
/// size. Matches Material's default [CircleAvatar] radius of 20 (→ 40dp): the
/// initials fallback keeps its standard list dimensions while the image
/// variant grows to match it rather than rendering smaller.
const double memberAvatarDiameter = 40;

/// Avatar for one person, resolved from the local profile cache.
///
/// When [publicProfilesEnabled], watches the pubkey's public profile — self
/// via [ownProfileProvider], others via [memberProfileProvider] — and renders
/// `Profile.pictureBytes` via [HavenAvatar] when available. Falls back to an
/// initials [CircleAvatar] when no picture is known, the provider is loading,
/// or an error occurs. When [publicProfilesEnabled] is off, always renders
/// the initials fallback (no fetching).
///
/// When [isCurrentUser] is `true`, the thumbnail is sourced from
/// [ownProfileProvider] (the OWN-profile store) rather than
/// [memberProfileProvider] (the received-member store). The viewer's own
/// profile is resolved locally/by their own publishes, not by receiving a
/// broadcast from themselves, so self and other members read from two
/// distinct stores; reading the member store for self would always miss.
/// Sourcing from [ownProfileProvider] also means the row refreshes the
/// instant the user sets or clears their picture in settings (that
/// controller invalidates it).
class MemberAvatar extends ConsumerWidget {
  /// Creates a [MemberAvatar].
  const MemberAvatar({
    required this.pubkey,
    this.displayName,
    this.isCurrentUser = false,
    super.key,
  });

  /// Hex pubkey of the person this avatar stands for.
  final String pubkey;

  /// Resolved name, used only for the initials fallback. `null` when nothing
  /// resolved, in which case the glyph is derived from [pubkey].
  final String? displayName;

  /// Whether this avatar represents the current user (the viewer).
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    // Desaturated HSL hue derived from the pubkey gives each member a stable
    // tint without the brand-blue/red collisions of Colors.primaries.
    final hue = (pubkey.hashCode.abs() % 360).toDouble();
    final tint = HSLColor.fromAHSL(1, hue, 0.30, 0.55).toColor();

    final initial = initialFor(displayName, pubkey);

    // Build the initials fallback once; reused by both branches.
    final initialsAvatar = CircleAvatar(
      radius: memberAvatarDiameter / 2,
      backgroundColor: tint.withValues(alpha: 0.18),
      foregroundColor: colorScheme.onSurface,
      child: Text(
        initial,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
    );

    if (!publicProfilesEnabled) return initialsAvatar;

    // Resolve the picture bytes from the correct store:
    // - self: the own-profile store (ownProfileProvider), keyed by pubkey
    //   only. Invalidated by OwnProfileController on set/clear/save, so this
    //   row refreshes the instant the user changes their picture.
    // - others: the plain-pubkey-keyed member-profile store (D6 — no
    //   mlsGroupId component; the same pubkey resolves the same profile
    //   across every shared circle).
    // Both providers are autoDispose — released when the avatar leaves the
    // tree.
    final thumbnailBytes = isCurrentUser
        ? ref.watch(ownProfileProvider).valueOrNull?.pictureBytes
        : ref.watch(memberProfileProvider(pubkey)).valueOrNull?.pictureBytes;

    // On loading or error: show initials (no shimmer — bystander privacy).
    // On data: show HavenAvatar with image bytes when non-null.
    //
    // Wrap the whole initials-or-image decision in a single AnimatedSwitcher
    // so a nil→image transition crossfades rather than hard-popping.
    // The ValueKey differentiates the two widget types so Flutter knows to
    // animate the swap. No shimmer — bystander privacy.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: thumbnailBytes == null
          ? KeyedSubtree(key: const ValueKey('initials'), child: initialsAvatar)
          : HavenAvatar(
              key: const ValueKey('image'),
              imageBytes: thumbnailBytes,
              initials: initial,
              publicKey: pubkey,
              // Match the initials CircleAvatar exactly so a member with a
              // profile picture is the same size as one showing initials.
              diameter: memberAvatarDiameter,
            ),
    );
  }
}

/// The single glyph an initials avatar shows for [displayName] / [pubkey].
///
/// Grapheme-safe: `characters.first` takes a whole user-perceived character,
/// so a name starting with an emoji, a Devanagari cluster or a combining
/// sequence yields that character rather than half of its code units.
///
/// The FFI today always delivers a 64-char lowercase hex pubkey, but a
/// malformed record (short pubkey + no display name) must not take out a
/// whole list, so the fallbacks step down to a deterministic glyph.
String initialFor(String? displayName, String pubkey) {
  final name = displayName;
  if (name != null && name.isNotEmpty) {
    return name.characters.first.toUpperCase();
  }
  if (pubkey.length > 5) {
    return pubkey[5].toUpperCase();
  }
  if (pubkey.isNotEmpty) {
    return pubkey.characters.first.toUpperCase();
  }
  return '?';
}
