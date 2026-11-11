/// The fanout driver's entries for the changes a user makes to a circle.
library;

import 'package:haven/src/rust/api.dart';

/// Makes a circle change through the fanout driver: each stages its commit
/// under a durable record and sends it until a relay acknowledges it.
///
/// `foreground` on each is the caller's word that the app is in front of its
/// user; the engine makes a change only then (where a live plane exists it
/// reads its own claim instead). Never `true` from a background isolate or a
/// background path.
abstract interface class CircleChangeDriver {
  /// Creates a circle of [members]: a delivery record is written for each
  /// founding Welcome before this returns, and each is sent from it to its
  /// invitee's inbox relays until one acknowledges it. [relays] is the
  /// circle's relay list as the caller named it, empty for Rust to pick; it
  /// is never the Welcome route.
  Future<CircleCreationOutcomeFfi> createCircle({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
    required List<MemberKeyPackageFfi> members,
    required String name,
    required String circleType,
    required List<String> relays,
    required bool foreground,
    String? description,
  });

  /// Invites [members] to the circle.
  Future<EvolutionOutcomeFfi> addMembers({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<MemberKeyPackageFfi> members,
    required bool foreground,
  });

  /// Removes [memberPubkeys] (hex or npub) from the circle.
  Future<EvolutionOutcomeFfi> removeMembers({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> memberPubkeys,
    required bool foreground,
  });

  /// Replaces the circle's relays.
  Future<EvolutionOutcomeFfi> updateCircleRelays({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> relays,
    required bool foreground,
  });

  /// Makes [successor] an admin beside this device: a leaving admin's first
  /// step.
  Future<EvolutionOutcomeFfi> adminHandoff({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required String successor,
    required bool foreground,
  });

  /// Steps this device down from admin: a leaving admin's second step.
  Future<EvolutionOutcomeFfi> selfDemote({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  });

  /// The epoch-repair rotation.
  Future<RepairOutcomeFfi> repairRotation({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  });

  /// What the user needs to know first about the circle, worst first;
  /// `null` when nothing holds it. Sends nothing: what holds its sends is
  /// read in the [foreground] mode claimed.
  Future<RecoveryCauseFfi?> circleRecovery({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  });

  /// Ingests one received kind-445: its circle's records are driven first,
  /// and whatever the engine stages on the way is recorded and driven.
  Future<IngestOutcomeFfi> ingest({
    required CircleManagerFfi circle,
    required String eventJson,
    required bool foreground,
  });

  /// Drives every stored record that has something due, in every circle: for
  /// a process the live plane does not drive.
  Future<ResumeOutcomeFfi> resume({
    required CircleManagerFfi circle,
    required bool foreground,
  });

  /// The re-invites MDK owes whose lookup is due, in every circle, and the
  /// drive of the stored records that follows them.
  Future<ReinviteDrivenFfi> reinvite({
    required CircleManagerFfi circle,
    required bool foreground,
  });

  /// Leaves the circle: the intent is written first, and from then nothing
  /// is shared with the circle; the leave is then carried on as [resumeLeave]
  /// carries it.
  Future<LeaveOutcomeFfi> leave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  });

  /// Carries on the leave asked for in the circle, if any: the leave ends on
  /// this device once a peer committed it or its bound passed.
  Future<LeaveOutcomeFfi> resumeLeave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  });

  /// Seals a fix at [latitude], [longitude] for the circle and records it,
  /// after its records are driven; the sealed event goes to
  /// [publishLocation] and nowhere else. Nothing is sealed for a circle
  /// whose sends something holds, a leave included.
  Future<SealOutcomeFfi> sealLocation({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required double latitude,
    required double longitude,
    required bool foreground,
  });

  /// Sends a location [sealLocation] sealed, once, to the relays its record
  /// names, and ends its record whatever was answered. With the Bluetooth
  /// mesh on, that send also leaves the sealed event for the mesh.
  Future<LocationPublishFfi> publishLocation({
    required CircleManagerFfi circle,
    required SealedLocationFfi sealed,
  });
}
