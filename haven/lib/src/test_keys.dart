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

  /// "Get Started" primary CTA on the intro screen (page 1 of 2).
  static const Key introCta = Key('intro_cta');

  /// "Create My Identity" primary CTA on the identity-creation screen
  /// (page 2 of 2) — the single tap that creates the identity, publishes the
  /// public profile, runs the location disclosure, and enters the map shell.
  static const Key createIdentityCta = Key('create_identity_cta');

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

  /// Refresh control in the invitations page app bar (the segmented
  /// `RefreshRingButton`).
  static const Key invitationsRefresh = Key('invitations_refresh');

  /// The segmented-ring `CustomPaint` inside a `RefreshRingButton`, so a
  /// recording-canvas test can target the painter to assert arc geometry and
  /// per-segment colors.
  static const Key refreshRingPaint = Key('refresh_ring_paint');

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

  /// The rejoin consent dialog's Cancel: its default, which changes nothing.
  static const Key rejoinDialogCancel = Key('rejoin_dialog_cancel');

  /// The rejoin consent dialog's Decline.
  static const Key rejoinDialogDecline = Key('rejoin_dialog_decline');

  /// The rejoin consent dialog's Join again.
  static const Key rejoinDialogConfirm = Key('rejoin_dialog_confirm');

  // ---------------------------------------------------------------------------
  // Circle management
  // ---------------------------------------------------------------------------

  /// Info button in the selected-circle header that opens the
  /// circle-details bottom sheet. Keyed so tests don't couple to the
  /// (user-facing, translatable) "Circle details" tooltip text.
  static const Key circleDetailsButton = Key('circle_details_button');

  /// The member-count subtitle inside the circle-details bottom sheet, which
  /// also carries the circle's MLS epoch and then the relay-expiry window for
  /// the location messages this device sends there — each appended only once
  /// it resolves. Keyed so tests can assert both appear, and that each
  /// degrades to the shorter line when unavailable, without matching
  /// translated text.
  static const Key circleDetailsMembers = Key('circle_details_members');

  /// "Add member" CTA inside the circle-details bottom sheet (admin only).
  static const Key addMemberCta = Key('add_member_cta');

  /// Confirm/submit button on the AddMemberPage.
  static const Key addMemberConfirm = Key('add_member_confirm');

  /// "Leave Circle" CTA inside the circle-details bottom sheet.
  static const Key leaveCircleCta = Key('leave_circle_cta');

  /// The confirming "Leave" button in the leave-circle dialog. Keyed
  /// so tests don't couple to the (translatable) button label, which
  /// also collides with the dialog title text under a text finder.
  static const Key leaveCircleConfirm = Key('leave_circle_confirm');

  /// "Re-create Circle" remedy of the sharing status card for a circle MDK
  /// halted on this device.
  static const Key sharingHealthRecreateCta = Key(
    'sharing_health_recreate_cta',
  );

  /// "Continue" on the one-time storage-reset notice.
  static const Key storageResetContinue = Key('storage_reset_continue');

  /// "Relay settings" on the one-time storage-reset notice.
  static const Key storageResetOpenRelaySettings = Key(
    'storage_reset_open_relay_settings',
  );

  /// Root [ListTile] of a [CircleMemberTile], keyed by the member's pubkey hex.
  static Key memberTile(String pubkeyHex) => ValueKey('member_tile_$pubkeyHex');

  /// The admin "Remove from circle" button on a member's row, keyed by that
  /// member's pubkey hex. Present only for an admin viewer, on someone
  /// else's row, in a circle that is not blocked.
  static Key memberRemoveButton(String pubkeyHex) =>
      ValueKey('member_remove_$pubkeyHex');

  /// The confirming "Remove" button in the remove-member dialog. Keyed for
  /// the same reason as [leaveCircleConfirm]: the label is translatable and
  /// collides with the title text under a text finder.
  static const Key memberRemoveConfirm = Key('member_remove_confirm');

  /// The selected-circle name [Expanded] inside the circle selector's
  /// collapsed trigger row, keyed by the circle's nostrGroupId hex.
  ///
  /// Present only when the identified circle is the active selection;
  /// absent when the "Select a circle" placeholder is shown or when a
  /// different circle is selected. Circle names are NOT unique, so the
  /// key is scoped to [nostrGroupIdHex] — the circle's CURRENT routing id,
  /// which another client's routing rotation changes (Haven never rotates
  /// its own), so a finder built from it holds only until then.
  ///
  /// E2E tests use this to wait for a specific circle to appear (after
  /// creation) or disappear (after leave) without text-matching, which
  /// is brittle to truncation, decoration, and SnackBar/toast false
  /// matches.
  static Key circleSelectorActive(String nostrGroupIdHex) =>
      ValueKey('circle_selector_active_$nostrGroupIdHex');

  /// A circle list item in the expanded dropdown panel, keyed by the
  /// circle's nostrGroupId hex.
  ///
  /// Only mounted while the dropdown panel is open. Use
  /// [circleSelectorActive] to detect the active selection in the
  /// collapsed trigger row — that widget is always in the tree when a
  /// circle is selected, regardless of dropdown state.
  static Key circleTile(String nostrGroupIdHex) =>
      ValueKey('circle_tile_$nostrGroupIdHex');

  // ---------------------------------------------------------------------------
  // Map
  // ---------------------------------------------------------------------------

  /// [MemberMarker] widget on the map, keyed by the member's pubkey hex.
  ///
  /// Replaces the former inline `ValueKey(loc.pubkey)` so test code can
  /// reference the same key without constructing one ad hoc.
  static Key memberMarker(String pubkeyHex) =>
      ValueKey('member_marker_$pubkeyHex');

  /// Root [Stack] of the unified member-marker overlay.
  static const Key memberMarkersLayer = Key('member_markers_layer');

  /// The teardrop [CustomPaint] inside a [MemberMarker], keyed by the member's
  /// pubkey hex so a recording-canvas test can target one marker.
  static Key markerTeardrop(String pubkeyHex) =>
      ValueKey('marker_teardrop_$pubkeyHex');

  /// The [Semantics] node of a [MemberMarker], wrapping its tap-sized box
  /// (not the larger paint footprint), keyed by the member's pubkey hex.
  static Key markerSemantics(String pubkeyHex) =>
      ValueKey('marker_semantics_$pubkeyHex');

  /// Root [Card] of the sharing-health banner.
  static const Key sharingHealthBanner = Key('sharing_health_banner');

  /// The single remedy button on the sharing-health banner.
  static const Key sharingHealthRepairButton = Key(
    'sharing_health_repair_button',
  );

  /// "Delete Identity" on the advanced identity page.
  static const Key identityDeleteCta = Key('identity_delete_cta');

  /// The change card in Circle details.
  static const Key changeNoticeCard = Key('change_notice_card');

  /// The change card's Dismiss, which acknowledges the notice.
  static const Key changeNoticeDismiss = Key('change_notice_dismiss');

  /// The change card's "Remove again" after a dropped removal.
  static const Key changeNoticeRemoveAgain = Key('change_notice_remove_again');

  /// The change card's "Keep them in the circle" after a dropped removal.
  static const Key changeNoticeKeepMembers = Key('change_notice_keep_members');

  /// The confirming button of the keep-them dialog.
  static const Key changeNoticeKeepConfirm = Key('change_notice_keep_confirm');

  /// The change card's "Review members" beside an undone removal.
  static const Key changeNoticeReviewMembers = Key(
    'change_notice_review_members',
  );

  /// The attention cue on the circle selector's trigger row: a circle other
  /// than the selected one needs attention.
  static const Key circleAttentionCue = Key('circle_attention_cue');

  /// The dot on the selected circle's avatar in the trigger row.
  static const Key circleSelectedAttentionDot = Key(
    'circle_selected_attention_dot',
  );

  /// The attention cue on a circle's row in the selector list, keyed by the
  /// circle's `nostrGroupId` hex as [circleTile] is.
  static Key circleRowAttentionCue(String nostrGroupIdHex) =>
      ValueKey('circle_row_attention_cue_$nostrGroupIdHex');

  // ---------------------------------------------------------------------------
  // Location disclosure
  // ---------------------------------------------------------------------------

  /// "Agree" primary CTA in the location prominent-disclosure dialog.
  static const Key locationDisclosureAgree = Key('location_disclosure_agree');

  /// "Not now" secondary CTA in the location prominent-disclosure dialog.
  static const Key locationDisclosureNotNow = Key(
    'location_disclosure_not_now',
  );

  // ---------------------------------------------------------------------------
  // Settings — location
  // ---------------------------------------------------------------------------

  /// The [SwitchListTile] for background location sharing on the Location
  /// settings page.
  static const Key backgroundSharingTile = Key('background_sharing_tile');

  // ---------------------------------------------------------------------------
  // Settings — identity
  // ---------------------------------------------------------------------------

  /// The circular save button in the display-name editor.
  ///
  /// Keyed so tests target the button regardless of its state-dependent icon
  /// (save / spinner / check / retry) without coupling to a text label.
  static const Key displayNameSaveButton = Key('display_name_save_button');

  /// Refresh [IconButton] on the Identity page (forces a network re-fetch of
  /// the user's own public profile).
  static const Key identityRefreshButton = Key('identity_refresh_button');

  // ---------------------------------------------------------------------------
  // Member detail sheet
  // ---------------------------------------------------------------------------

  /// Nickname [TextField] in the member detail bottom sheet.
  static const Key memberNicknameField = Key('member_nickname_field');

  /// "Save Nickname" button in the member detail bottom sheet.
  static const Key memberNicknameSave = Key('member_nickname_save');

  /// "Clear Nickname" button in the member detail bottom sheet.
  static const Key memberNicknameClear = Key('member_nickname_clear');

  /// "Copy Public Key" action in the member detail bottom sheet.
  static const Key memberDetailCopyPublicKey = Key(
    'member_detail_copy_public_key',
  );
}
