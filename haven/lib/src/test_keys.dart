/// Stable widget keys for end-to-end automation (Patrol, flutter_test).
///
/// Centralised so test code can reference a single source of truth and
/// widget code reads its key from here rather than inventing strings inline.
/// Adding a key here is non-breaking; removing one is a contract change.
library;

import 'package:flutter/widgets.dart';

/// Stable widget keys used by E2E automation selectors.
///
/// All keys are [const] [Key] values except the composite factories, which
/// return [ValueKey] instances keyed by the caller-supplied identifier.
///
/// This class is part of the test-infrastructure surface. Widget code applies
/// the keys so that Patrol and [flutter_test] selectors can locate widgets
/// without brittle text-matching. Non-test production logic must not branch on
/// key identity.
abstract final class WidgetKeys {
  // ---------------------------------------------------------------------------
  // Onboarding
  // ---------------------------------------------------------------------------

  /// "Get Started" primary CTA on the welcome screen.
  static const Key welcomeCta = Key('welcome_cta');

  /// "Continue" primary CTA on the value-props screen.
  static const Key valuePropsCta = Key('value_props_cta');

  /// "Create Identity" primary CTA on the identity-creation screen.
  static const Key createIdentityCta = Key('create_identity_cta');

  /// "Skip" secondary CTA on the display-name screen.
  ///
  /// Tests that exercise the rest of onboarding without exercising the
  /// display-name input itself use this key to advance the state machine.
  static const Key displayNameSkip = Key('display_name_skip');

  /// "Enter Haven" primary CTA on the ready screen — the final tap that
  /// transitions out of onboarding into the map shell.
  static const Key readyCta = Key('ready_cta');

  /// "I'm 13 or older" primary CTA on the age-gate screen.
  static const Key ageGateConfirm = Key('age_gate_confirm');

  /// "I'm under 13" secondary CTA on the age-gate screen.
  static const Key ageGateUnder = Key('age_gate_under');

  // ---------------------------------------------------------------------------
  // Circle creation flow
  // ---------------------------------------------------------------------------

  /// "Create Circle" floating-action button on the circles page.
  static const Key circlesCreateCta = Key('circles_create_cta');

  /// Member npub search [TextField] on the create-circle page.
  static const Key memberSearchInput = Key('member_search_input');

  /// "Continue" [FilledButton] on the create-circle page.
  static const Key createCircleContinue = Key('create_circle_continue');

  /// Circle-name [TextFormField] on the name-circle page.
  static const Key circleNameInput = Key('circle_name_input');

  /// "Create Circle" [FilledButton] on the name-circle page.
  static const Key createCircleConfirm = Key('create_circle_confirm');

  // ---------------------------------------------------------------------------
  // Invitations
  // ---------------------------------------------------------------------------

  /// Floating IconButton on the map shell that opens the invitations page.
  static const Key invitationsFloatingButton = Key(
    'invitations_floating_button',
  );

  /// Refresh button in the invitations page app bar.
  static const Key invitationsRefresh = Key('invitations_refresh');

  /// Accept button for a specific invitation, keyed by an opaque,
  /// privacy-safe discriminator derived from public Nostr metadata
  /// (inviter pubkey + invitation timestamp).
  ///
  /// The discriminator deliberately does NOT use the MLS group ID:
  /// embedding it in a `ValueKey` puts it in the live widget tree
  /// where the widget inspector, accessibility/semantics dumps, and
  /// `flutter test --reporter=json` artifacts can read it — a
  /// regression of CLAUDE.md rule #4 ("Only publish `nostr_group_id`,
  /// never real MLS group ID"). See `InvitationCard._keyDiscriminator`
  /// (`lib/src/widgets/circles/invitation_card.dart`) for the
  /// canonical discriminator construction.
  static Key invitationAccept(String discriminator) =>
      ValueKey('invitation_accept_$discriminator');

  /// Decline button for a specific invitation. See [invitationAccept]
  /// for the rationale behind the discriminator scheme.
  static Key invitationDecline(String discriminator) =>
      ValueKey('invitation_decline_$discriminator');

  // ---------------------------------------------------------------------------
  // Circle management
  // ---------------------------------------------------------------------------

  /// Info button in the selected-circle header that opens the
  /// circle-details bottom sheet. Keyed so tests don't couple to the
  /// (user-facing, translatable) "Circle details" tooltip text.
  static const Key circleDetailsButton = Key('circle_details_button');

  /// "Leave Circle" CTA inside the circle-details bottom sheet.
  static const Key leaveCircleCta = Key('leave_circle_cta');

  /// The confirming "Leave" button in the leave-circle dialog. Keyed
  /// so tests don't couple to the (translatable) button label, which
  /// also collides with the dialog title text under a text finder.
  static const Key leaveCircleConfirm = Key('leave_circle_confirm');

  /// Root [ListTile] of a [CircleMemberTile], keyed by the member's pubkey hex.
  static Key memberTile(String pubkeyHex) => ValueKey('member_tile_$pubkeyHex');

  // ---------------------------------------------------------------------------
  // Map
  // ---------------------------------------------------------------------------

  /// [MemberMarker] widget on the map, keyed by the member's pubkey hex.
  ///
  /// Replaces the former inline `ValueKey(loc.pubkey)` so test code can
  /// reference the same key without constructing one ad hoc.
  static Key memberMarker(String pubkeyHex) =>
      ValueKey('member_marker_$pubkeyHex');

  // ---------------------------------------------------------------------------
  // Location disclosure
  // ---------------------------------------------------------------------------

  /// "Agree" primary CTA in the location prominent-disclosure dialog.
  static const Key locationDisclosureAgree = Key('location_disclosure_agree');

  /// "Not now" secondary CTA in the location prominent-disclosure dialog.
  static const Key locationDisclosureNotNow = Key(
    'location_disclosure_not_now',
  );
}
