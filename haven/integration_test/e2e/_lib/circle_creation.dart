/// Publish-before-apply (Security Rule 13) circle creation for E2E harnesses.
///
/// Scenarios that need a circle on a REAL [CircleManagerFfi] — rather than
/// through `NostrCircleService` — must still honour the same publish-then-
/// confirm contract the production service implements
/// (`nostr_circle_service.dart`'s `createCircle`). [createCircleConfirmed]
/// is that contract, factored out so no harness can quietly omit it.
///
/// **Why omitting the confirm is not a benign shortcut.** `createCircle`
/// stages a `GroupCreated` pending state and leaves the group in MDK's
/// `EpochState::PendingPublish`. Per the engine contract
/// (`cgka-traits`, `CgkaEngine::ingest`):
///
/// > Calls while the group is in `EpochState::PendingPublish` or
/// > `EpochState::Merging` return `IngestOutcome::Buffered` and replay once
/// > the state returns to `Stable`.
///
/// A harness that stages the create and never confirms therefore pins the
/// group in `PendingPublish` for the rest of the process: EVERY inbound
/// kind-445 for it buffers forever, the live-sync processor deliberately
/// withholds the per-circle cursor on `Buffered`, and the scenario times out
/// waiting for a peer location that the engine is holding on purpose. The
/// failure surfaces far from its cause — as a receive-path timeout, not as a
/// creation error — so route every direct-FFI create through here.
library;

import 'package:haven/src/rust/api.dart'
    show CircleCreationResultFfi, CircleManagerFfi, MemberKeyPackageFfi;

import 'test_relay.dart' show TestRelay;

/// Creates a circle on [manager], publishes every gift-wrapped Welcome to
/// [relay], then resolves the staged create per Security Rule 13: confirmed
/// once EVERY Welcome is relay-acked, rolled back otherwise.
///
/// With zero [members] there is no Welcome to ack, so the create is confirmed
/// unconditionally — a circle holding only its creator is still valid.
///
/// **Stricter than production on purpose.** `NostrCircleService.createCircle`
/// confirms on `total == 0 || sentCount > 0`, because in the field a Welcome
/// may legitimately fail to reach one peer's relays. The hermetic E2E relay
/// has no such excuse: a rejected Welcome there is a harness defect, and
/// letting it slide would silently under-populate a multi-invitee circle (the
/// 3-member M11 scenarios would then fail later, on an unrelated assertion).
/// So any rejection rolls the create back and throws immediately.
///
/// [label] prefixes the [StateError]s raised on a rejected Welcome or a failed
/// confirm so a harness failure names the scenario that caused it.
///
/// Returns the [CircleCreationResultFfi] whose `pending` has already been
/// resolved; callers must not confirm it a second time.
///
/// Throws a [StateError] if the relay rejects any Welcome (the create is
/// rolled back first) or if the engine refuses the confirm.
Future<CircleCreationResultFfi> createCircleConfirmed({
  required CircleManagerFfi manager,
  required TestRelay relay,
  required List<int> identitySecretBytes,
  required List<MemberKeyPackageFfi> members,
  required String name,
  required String circleType,
  required List<String> relays,
  required List<String> creatorFallbackRelays,
  String label = 'e2e',
}) async {
  final result = await manager.createCircle(
    identitySecretBytes: identitySecretBytes,
    members: members,
    name: name,
    circleType: circleType,
    relays: relays,
    creatorFallbackRelays: creatorFallbackRelays,
  );

  // Publish every Welcome first — the engine may only apply the staged create
  // once the network has had a chance to observe it.
  var rejection = '';
  for (final welcome in result.welcomeEvents) {
    try {
      final (ok, msg) = await relay.publishAndAwaitOk(welcome.eventJson);
      if (!ok && rejection.isEmpty) rejection = msg;
    } on Object catch (e) {
      // Security Rule 8: runtimeType only — a raw error can carry MLS state.
      if (rejection.isEmpty) rejection = '${e.runtimeType}';
    }
  }

  if (rejection.isNotEmpty) {
    // Roll the staged create back so the group does not linger in
    // PendingPublish and silently buffer every later inbound message.
    try {
      await manager.publishFailed(pending: result.pending);
    } on Object catch (e) {
      throw StateError(
        '[$label] a Welcome was rejected ($rejection) and the create '
        'rollback also failed: ${e.runtimeType}',
      );
    }
    throw StateError('[$label] relay rejected a Welcome: $rejection');
  }

  try {
    await manager.confirmPublished(pending: result.pending);
  } on Object catch (e) {
    throw StateError(
      '[$label] createCircle confirmPublished failed: ${e.runtimeType}',
    );
  }
  return result;
}
