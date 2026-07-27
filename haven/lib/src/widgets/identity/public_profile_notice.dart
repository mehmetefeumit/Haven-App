/// Combined "your profile is public" disclosure notice.
///
/// Public profiles are public-by-default and UNCONDITIONAL (owner-directed
/// 2026-07-16, matching the White Noise reference app): saving a display name
/// or photo always publishes it as a kind-0 Nostr event, visible to anyone on
/// the network — not just members of the user's circles. There is no
/// opt-in/consent toggle; this widget is the single, neutral disclosure of
/// that fact, shown in exactly two places (same widget, so the copy never
/// drifts):
/// - Onboarding's `CreateIdentityScreen` (`create_identity_screen.dart`), near
///   the pre-filled display-name field.
/// - The Identity settings page (`identity_page.dart`), adjacent to the photo
///   header and the display-name card — the two editable fields the notice
///   describes.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/widgets/common/info_note.dart';

/// A neutral (informational, not a warning) callout disclosing that the
/// user's public profile (display name + photo) is visible to anyone on the
/// Nostr network.
///
/// Deliberately has no dismiss/toggle action — it is a standing disclosure,
/// not a one-time prompt.
///
/// A thin wrapper over [HavenInfoNote], which supplies the shared explainer-box
/// styling and merges the title and body into a single [Semantics] node so a
/// screen reader announces the disclosure as one coherent statement rather
/// than two disconnected fragments. This widget exists as a named type so its
/// two call sites and its reviewed copy stay pinned in place.
class PublicProfileNotice extends StatelessWidget {
  /// Creates a [PublicProfileNotice].
  const PublicProfileNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return HavenInfoNote(
      title: l10n.profileIsPublicNoticeTitle,
      paragraphs: [l10n.profileIsPublicNoticeBody],
    );
  }
}
