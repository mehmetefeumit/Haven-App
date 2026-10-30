/// Circle creation with every Welcome delivered, for E2E harnesses.
///
/// Scenarios that need a circle on a REAL [CircleManagerFfi] — rather than
/// through `NostrCircleService` — create it through the product's own driven
/// create: each founding Welcome is recorded before the call returns and sent
/// from that record to its invitee's inbox relays. [createCircleDelivered] is
/// that call plus the one thing a harness must not let slide: a Welcome no
/// relay acknowledged during the call.
///
/// A founded circle is canonical the moment the create returns (MDK v0.10.4
/// `PublishWork::FoundingGroupCreated`): there is no staged state to confirm
/// or roll back, and nothing here may try to.
library;

import 'dart:convert';

import 'package:haven/src/rust/api.dart'
    show
        CircleCreationOutcomeFfi,
        CircleFfi,
        CircleManagerFfi,
        CircleWithMembersFfi,
        InvitationFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;

/// A circle [createCircleDelivered] founded, every Welcome acknowledged.
class DeliveredCircle {
  const DeliveredCircle._(this.circle);

  /// The circle, as stored.
  final CircleFfi circle;
}

/// Creates a circle on [manager] through [relayManager]'s driven create and
/// requires every founding Welcome to be relay-acked during the call.
///
/// **Stricter than production on purpose.** `NostrCircleService.createCircle`
/// keeps the circle and reports how many Welcomes were acknowledged, because
/// in the field an invitee's relays may be unreachable for a while (later
/// foreground drives send the rest). The hermetic E2E relay has no such
/// excuse: an unacknowledged Welcome there is a harness defect, and letting it
/// slide would silently under-populate a multi-invitee circle (the 3-member
/// M11 scenarios would then fail later, on an unrelated assertion). So a
/// refusal, a missing Welcome or an unacknowledged one throws immediately.
///
/// [scenario] prefixes the [StateError] so a harness failure names the
/// scenario that caused it — a fixed harness tag (e.g. `'M11'`, `'FE-2'`),
/// never circle/user data.
Future<DeliveredCircle> createCircleDelivered({
  required CircleManagerFfi manager,
  required RelayManagerFfi relayManager,
  required List<int> identitySecretBytes,
  required List<MemberKeyPackageFfi> members,
  required String name,
  required String circleType,
  required List<String> relays,
  String scenario = 'e2e',
}) async {
  final outcome = await relayManager.createCircleDriven(
    circle: manager,
    identitySecretBytes: identitySecretBytes,
    members: members,
    name: name,
    circleType: circleType,
    relays: relays,
    // A harness drives the app in front of its user; nothing here is a
    // background path.
    foreground: true,
  );
  final circle = outcome.circle;
  if (circle == null) {
    // The refusal by variant name only (Rule 15).
    throw StateError('[$scenario] create refused: ${outcome.refusal}');
  }
  if (outcome.welcomesTotal != members.length ||
      outcome.welcomesSent != outcome.welcomesTotal) {
    // No count (Rule 15): only that the delivery fell short.
    throw StateError('[$scenario] a founding Welcome was not acknowledged');
  }
  return DeliveredCircle._(circle);
}

/// Creates a circle on [manager] through [relayManager]'s driven create, as
/// [createCircleDelivered] does, but takes an unacknowledged founding Welcome
/// as what it is in the field — owed, and sent again from its record by later
/// foreground drives — and hands the outcome back. Only a refusal throws.
///
/// For the scenarios about that redelivery; every other harness wants
/// [createCircleDelivered].
Future<CircleCreationOutcomeFfi> createCircleOwingWelcomes({
  required CircleManagerFfi manager,
  required RelayManagerFfi relayManager,
  required List<int> identitySecretBytes,
  required List<MemberKeyPackageFfi> members,
  required String name,
  required String circleType,
  required List<String> relays,
  String scenario = 'e2e',
}) async {
  final outcome = await relayManager.createCircleDriven(
    circle: manager,
    identitySecretBytes: identitySecretBytes,
    members: members,
    name: name,
    circleType: circleType,
    relays: relays,
    foreground: true,
  );
  if (outcome.circle == null) {
    throw StateError('[$scenario] create refused: ${outcome.refusal}');
  }
  return outcome;
}

/// Joins [invitee] to the circle a driven create invited it to, from the gift
/// wrap the create sent to [relays]: how an invitee in the same process
/// receives its Welcome rather than being handed it. A wrap an earlier run
/// left for the same identity cannot be accepted by this fresh store and is
/// passed over.
Future<CircleWithMembersFfi> joinDeliveredWelcome({
  required RelayManagerFfi relayManager,
  required CircleManagerFfi invitee,
  required List<int> inviteeSecretBytes,
  required String inviteePubkeyHex,
  required List<String> relays,
  String scenario = 'e2e',
}) async {
  final wraps = await relayManager.fetchGiftWraps(
    recipientPubkey: inviteePubkeyHex,
    relays: relays,
  );
  for (final wrap in wraps) {
    final InvitationFfi? invitation;
    try {
      invitation = await invitee.processGiftWrappedInvitation(
        identitySecretBytes: inviteeSecretBytes,
        giftWrapEventJson: wrap,
      );
    } on Object catch (_) {
      continue;
    }
    if (invitation == null) continue;
    // The invitation's `mlsGroupId` is the gift-wrap id it is keyed by.
    final outcome = await invitee.acceptInvitation(
      giftWrapId: invitation.mlsGroupId,
    );
    if (outcome.joined case final joined?) return joined;
  }
  throw StateError('[$scenario] no delivered Welcome could be accepted');
}

/// The ids of every gift wrap [relays] hold for [recipientPubkeyHex]: taken
/// before and after a driven create, their difference is the wrap it sent.
Future<Set<String>> giftWrapIdsFor({
  required RelayManagerFfi relayManager,
  required String recipientPubkeyHex,
  required List<String> relays,
}) async => {
  for (final wrap in await relayManager.fetchGiftWraps(
    recipientPubkey: recipientPubkeyHex,
    relays: relays,
  ))
    (jsonDecode(wrap) as Map<String, dynamic>)['id'] as String,
};
