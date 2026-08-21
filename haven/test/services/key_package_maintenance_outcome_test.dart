/// Proofs that a `KeyPackage` maintenance tick's three outcomes stay
/// distinguishable.
///
/// ## The defect these exist for
///
/// `MaintenanceService.maintainKeyPackage` used to return
/// `KeyPackageMaintenanceResult`, a plain class with an `.empty()` constructor
/// whose `action` defaulted to `alreadyHealthy` and whose counters defaulted to
/// zero. Every failure path produced exactly that value:
///
///   * the FFI call throwing (`NostrRelayService`'s `catch`),
///   * the circle handle or identity secret failing to resolve
///     (`MaintenanceService._withSecret`'s `onFailure`),
///
/// and one failure did not even need a `catch` to disappear: the Rust tick
/// reports a publish's acknowledgement in `relaysHealed`, and the Dart result
/// type did not carry that field. A publish that reached no relay came back
/// labelled `republishedFreshD`, which `keyPackagePublisherProvider` scored as
/// success.
///
/// So "the account is fine", "the account could not be checked", and "the
/// account's KeyPackage did not land" were one value. These tests pin each of
/// the three apart, at the layer that decides which is which.
///
/// Covers:
/// - the classifier's verdict for every FFI shape it can receive
/// - a publish acked by nobody is a failure, never health and never a publish
/// - a tick that reached no relay is a failure, never health
/// - the two zero-responder ticks — no relay CONFIGURED vs no relay REACHABLE
///   — told apart by `relaysTargeted` and by nothing else
/// - the retry disposition each failure kind carries, including the two
///   zero-responder kinds carrying OPPOSITE ones
/// - the constructor assertions that make an impossible outcome unbuildable
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

/// Builds an FFI tick outcome.
///
/// The four counters are REQUIRED, not defaulted: which combination of them
/// means "reachable" is the entire subject of this file, and a default would
/// let a case be written without stating the numbers it depends on — the same
/// move that let the production type default its way into "healthy".
///
/// [relaysTargeted] is held to that rule too, although only its zero-ness is
/// load-bearing, because a default would *pick a verdict* for every case that
/// stayed silent about it: defaulting to `0` relabels every unreachable tick
/// "nothing configured", and defaulting to non-zero lets a no-relays case be
/// written without ever saying so. Either way one of the two situations this
/// field exists to separate stops being spellable — the collapse it undoes,
/// restored by omission.
KpMaintenanceOutcomeFfi _ffi({
  required int canonicalOnRelays,
  required int relaysTargeted,
  required int respondersProbed,
  required int relaysHealed,
  KpMaintenanceActionFfi action = KpMaintenanceActionFfi.alreadyHealthy,
  int relayErrors = 0,
  bool expiredInitKeyPurged = false,
  bool retiredMalformedSlot = false,
}) {
  return KpMaintenanceOutcomeFfi(
    action: action,
    canonicalOnRelays: canonicalOnRelays,
    relaysTargeted: relaysTargeted,
    respondersProbed: respondersProbed,
    relaysHealed: relaysHealed,
    relayErrors: relayErrors,
    expiredInitKeyPurged: expiredInitKeyPurged,
    retiredMalformedSlot: retiredMalformedSlot,
  );
}

/// Every action a tick can report, so a new one cannot be added without a
/// classification decision being made for it somewhere in this file.
const List<KpMaintenanceActionFfi> _allActions =
    KpMaintenanceActionFfi.values;

/// The subset of actions that mean "material was written to a relay".
const List<KpMaintenanceActionFfi> _publishingActions = [
  KpMaintenanceActionFfi.republishedStableD,
  KpMaintenanceActionFfi.republishedFreshD,
  KpMaintenanceActionFfi.rotatedExpiringMaterial,
  KpMaintenanceActionFfi.rotatedUnreadableLifetime,
];

void main() {
  group('classifyKeyPackageMaintenance — the three outcomes', () {
    test('a confirmed canonical on a responding relay is healthy', () {
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 3,
          relaysTargeted: 2,
          respondersProbed: 2,
          relaysHealed: 0,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenanceHealthy>());
      final healthy = outcome as KeyPackageMaintenanceHealthy;
      expect(healthy.canonicalOnRelays, 3);
      expect(healthy.respondersProbed, 2);
      expect(healthy.seededStableSlot, isFalse);
    });

    test('an acked republish is published, and says how many acked', () {
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.republishedStableD,
          canonicalOnRelays: 1,
          relaysTargeted: 2,
          respondersProbed: 2,
          relaysHealed: 2,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenancePublished>());
      final published = outcome as KeyPackageMaintenancePublished;
      expect(published.relaysAcked, 2);
      expect(
        published.mintedFreshSlot,
        isFalse,
        reason: 'a stable-slot republish reuses the tracked d',
      );
    });

    test('a fresh-slot publish is published and flagged as a fresh mint', () {
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.republishedFreshD,
          canonicalOnRelays: 0,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 1,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenancePublished>());
      expect(
        (outcome as KeyPackageMaintenancePublished).mintedFreshSlot,
        isTrue,
      );
    });

    test('seeding a stable slot from an on-relay canonical is healthy', () {
      // Seeding writes nothing to a relay, but the canonical it adopted was
      // observed on one THIS tick — the account is reachable.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.seededD,
          canonicalOnRelays: 1,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 0,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenanceHealthy>());
      expect(
        (outcome as KeyPackageMaintenanceHealthy).seededStableSlot,
        isTrue,
      );
    });

    test('the three outcomes are mutually exclusive types', () {
      final healthy = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 2,
          relaysTargeted: 2,
          respondersProbed: 2,
          relaysHealed: 0,
        ),
      );
      final published = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.republishedFreshD,
          canonicalOnRelays: 0,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 1,
        ),
      );
      final failed = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.republishedFreshD,
          canonicalOnRelays: 0,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 0,
        ),
      );

      expect(healthy, isA<KeyPackageMaintenanceHealthy>());
      expect(healthy, isNot(isA<KeyPackageMaintenancePublished>()));
      expect(healthy, isNot(isA<KeyPackageMaintenanceFailed>()));

      expect(published, isA<KeyPackageMaintenancePublished>());
      expect(published, isNot(isA<KeyPackageMaintenanceHealthy>()));
      expect(published, isNot(isA<KeyPackageMaintenanceFailed>()));

      expect(failed, isA<KeyPackageMaintenanceFailed>());
      expect(failed, isNot(isA<KeyPackageMaintenanceHealthy>()));
      expect(failed, isNot(isA<KeyPackageMaintenancePublished>()));
    });
  });

  group('classifyKeyPackageMaintenance — a publish nobody acked', () {
    test(
      'a republish with zero acks is NOT healthy and NOT published',
      () {
        // THE regression. `republish_key_package` picks its action before it
        // knows whether the write landed and reports the ack in `relaysHealed`;
        // `publish_event` returns `AllRelaysFailed` when no relay acked, which
        // is exactly this shape. Reporting it as either of the two non-failure
        // outcomes means the account is silently uninvitable. Covers the
        // lifetime rotations too — they publish through the same helper, and a
        // rotation that does not land is the worst case of all.
        for (final action in _publishingActions) {
          final outcome = classifyKeyPackageMaintenance(
            _ffi(
              action: action,
              canonicalOnRelays: 0,
              relaysTargeted: 2,
              respondersProbed: 2,
              relaysHealed: 0,
              relayErrors: 1,
            ),
          );

          expect(
            outcome,
            isNot(isA<KeyPackageMaintenanceHealthy>()),
            reason: '$action with zero acks must never read as healthy',
          );
          expect(
            outcome,
            isNot(isA<KeyPackageMaintenancePublished>()),
            reason: '$action with zero acks did not publish anything',
          );
          expect(
            (outcome as KeyPackageMaintenanceFailed).kind,
            KeyPackageFailureKind.publishNotAcked,
          );
          expect(outcome.relayErrors, 1);
        }
      },
    );

    test('a publish acked by exactly one relay IS published', () {
      // The boundary on the other side: one ack is enough. Rule 13's standard
      // is "at least one relay acked", not "every relay acked".
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.republishedStableD,
          canonicalOnRelays: 0,
          relaysTargeted: 3,
          respondersProbed: 3,
          relaysHealed: 1,
          relayErrors: 2,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenancePublished>());
      expect((outcome as KeyPackageMaintenancePublished).relaysAcked, 1);
      expect(
        outcome.relayErrors,
        2,
        reason: 'a partial failure is reported, not promoted to a total one',
      );
    });
  });

  group('classifyKeyPackageMaintenance — nothing was probed', () {
    test('alreadyHealthy with no responder is a failure, not health', () {
      // `decide_kp_maintenance` fails closed on an empty responder set and
      // returns NoOp, which the FFI reports as `alreadyHealthy`. Correct as a
      // decision ("do not republish on no evidence"); wrong as a verdict.
      // Relays WERE configured here (`relaysTargeted: 2`) and simply did not
      // answer — the transient half of the two zero-responder cases, and the
      // one this test is named for.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 0,
          relaysTargeted: 2,
          respondersProbed: 0,
          relaysHealed: 0,
        ),
      );

      expect(
        outcome,
        isNot(isA<KeyPackageMaintenanceHealthy>()),
        reason: 'a tick that reached no relay confirmed no canonical',
      );
      expect(
        (outcome as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.noRelayResponded,
      );
    });

    test('alreadyHealthy with responders but no canonical is a failure', () {
      // Defensive: the Rust branch that produces this pairing does not exist
      // today (a NoOp with responders implies every responder serves the
      // slot), so if it ever appears it is a contract change, and the safe
      // reading of "we saw no canonical" is not "the account is fine".
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 0,
          relaysTargeted: 2,
          respondersProbed: 2,
          relaysHealed: 0,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenanceFailed>());
      expect(
        (outcome as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.noRelayResponded,
      );
    });

    test('no KeyPackage relays configured is a DIFFERENT failure', () {
      // The Rust tick returns before contacting anything when the account's
      // own NIP-65 KeyPackage set is empty, and that early return carries the
      // same action and the same zero counters as a tick whose every relay was
      // down. `relaysTargeted: 0` is the only thing that says which happened —
      // and it is still not health: an account nobody can fetch a KeyPackage
      // from is not invitable, however deliberate the reason.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 0,
          relaysTargeted: 0,
          respondersProbed: 0,
          relaysHealed: 0,
        ),
      );

      expect(
        outcome,
        isNot(isA<KeyPackageMaintenanceHealthy>()),
        reason: 'an account with no KeyPackage relay is not reachable',
      );
      expect(
        (outcome as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.noRelaysConfigured,
      );
    });

    test('the two zero-responder ticks differ ONLY in relaysTargeted', () {
      // The re-collapse detector at the classifier layer: every other field is
      // pinned equal, so a classifier that stops reading `relaysTargeted`
      // returns the same kind twice and this fails. Their remedies are
      // opposite — wait out the network vs. add a relay — so reporting either
      // as the other hammers a setting that will never change by itself, or
      // blames the user for an outage.
      KeyPackageFailureKind kindFor(int relaysTargeted) =>
          (classifyKeyPackageMaintenance(
                _ffi(
                  canonicalOnRelays: 0,
                  relaysTargeted: relaysTargeted,
                  respondersProbed: 0,
                  relaysHealed: 0,
                ),
              ) as KeyPackageMaintenanceFailed)
              .kind;

      expect(kindFor(0), KeyPackageFailureKind.noRelaysConfigured);
      expect(kindFor(3), KeyPackageFailureKind.noRelayResponded);
      expect(
        kindFor(0),
        isNot(kindFor(3)),
        reason: 'one field decides this; drop it and the two collapse back '
            'into a single kind, one of which then gets the wrong remedy',
      );
    });

    test(
      'a responder with zero targets reads as unreachable, not unconfigured',
      () {
        // Defensive, and deliberately fail-safe in one direction: responders
        // are a subset of the targets, so this shape cannot come out of the
        // Rust tick. If it ever does, "a relay answered" is the stronger
        // evidence — reading it as "you have no relays" would park the loop at
        // the nominal cadence and tell the user to configure something that
        // demonstrably exists, while the reverse merely retries sooner than
        // needed.
        final outcome = classifyKeyPackageMaintenance(
          _ffi(
            canonicalOnRelays: 0,
            relaysTargeted: 0,
            respondersProbed: 2,
            relaysHealed: 0,
          ),
        );

        expect(
          (outcome as KeyPackageMaintenanceFailed).kind,
          KeyPackageFailureKind.noRelayResponded,
        );
      },
    );
  });

  group('classifyKeyPackageMaintenance — an expired init key', () {
    test('is never healthy, whatever the probe saw', () {
      // The purge runs before any relay work and deletes the private half of
      // the tracked package. Relays may still be serving the public half, so
      // the probe reports canonicals — but a peer fetching one cannot produce
      // a Welcome this device can process. `canonicalOnRelays` is the exact
      // counter that would otherwise say "fine" here.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 3,
          relaysTargeted: 2,
          respondersProbed: 2,
          relaysHealed: 0,
          expiredInitKeyPurged: true,
        ),
      );

      expect(outcome, isNot(isA<KeyPackageMaintenanceHealthy>()));
      expect(
        (outcome as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.initKeyPurgedUnreplaced,
      );
      expect(outcome.expiredInitKeyPurged, isTrue);
    });

    test('is reported even when no relay was contacted at all', () {
      // The no-relays-configured early return (`relaysTargeted: 0`): the purge
      // still happened, and it is the more informative of the two failures, so
      // it OUTRANKS the configured/unconfigured split rather than being masked
      // by it. "Add a relay" is advice; "the init key is gone and nothing
      // replaced it" is the state.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 0,
          relaysTargeted: 0,
          respondersProbed: 0,
          relaysHealed: 0,
          expiredInitKeyPurged: true,
        ),
      );

      expect(
        (outcome as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.initKeyPurgedUnreplaced,
      );
    });

    test('an unacked rotation reports the purge, not just the missed ack', () {
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.rotatedExpiringMaterial,
          canonicalOnRelays: 1,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 0,
          relayErrors: 1,
          expiredInitKeyPurged: true,
        ),
      );

      expect(
        (outcome as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.initKeyPurgedUnreplaced,
      );
    });

    test('a rotation that DID land carries the purge without failing', () {
      // Replacing expired material is the healthy steady state, not a fault:
      // the purge flag survives so a caller can still see it happened.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.rotatedExpiringMaterial,
          canonicalOnRelays: 1,
          relaysTargeted: 2,
          respondersProbed: 2,
          relaysHealed: 2,
          expiredInitKeyPurged: true,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenancePublished>());
      expect(outcome.expiredInitKeyPurged, isTrue);
      expect(
        (outcome as KeyPackageMaintenancePublished).mintedFreshSlot,
        isFalse,
        reason: 'a rotation re-mints material into the SAME stable slot',
      );
    });
  });

  group('classifyKeyPackageMaintenance — total coverage of the FFI enum', () {
    test('every action classifies, and none defaults to health', () {
      // A new action added to the FFI enum must not fall into a permissive
      // branch. With zero acks and zero responders, NO action describes a
      // reachable account, so every one of them must classify as a failure —
      // with relays configured or without, since neither state is reachability.
      for (final action in _allActions) {
        for (final relaysTargeted in [0, 2]) {
          final outcome = classifyKeyPackageMaintenance(
            _ffi(
              action: action,
              canonicalOnRelays: 0,
              relaysTargeted: relaysTargeted,
              respondersProbed: 0,
              relaysHealed: 0,
            ),
          );
          expect(
            outcome,
            isA<KeyPackageMaintenanceFailed>(),
            reason: '$action with nothing probed and nothing acked is a '
                'failure (relaysTargeted: $relaysTargeted)',
          );
        }
      }
    });

    test('every publishing action needs an ack to count as published', () {
      for (final action in _publishingActions) {
        expect(
          classifyKeyPackageMaintenance(
            _ffi(
              action: action,
              canonicalOnRelays: 0,
              relaysTargeted: 1,
              respondersProbed: 1,
              relaysHealed: 0,
            ),
          ),
          isA<KeyPackageMaintenanceFailed>(),
          reason: '$action must not report a publish nobody acked',
        );
        expect(
          classifyKeyPackageMaintenance(
            _ffi(
              action: action,
              canonicalOnRelays: 0,
              relaysTargeted: 1,
              respondersProbed: 1,
              relaysHealed: 1,
            ),
          ),
          isA<KeyPackageMaintenancePublished>(),
          reason: '$action with an ack is a publish',
        );
      }
    });
  });

  group('classifyKeyPackageMaintenance — a retired malformed slot', () {
    // Installs created before the `d`-width fix publish a slot id the Marmot
    // transport binding treats as a MALFORMED event, which a conformant inviter
    // must reject — so nobody strict can invite them until the Rust tick retires
    // the slot. Dart's only view of that migration is this flag, and dropping it
    // on the way out of the FFI is precisely the class of defect this file
    // exists for (`relaysHealed` was dropped exactly that way).
    test('a completed re-point survives classification as a publish', () {
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.republishedFreshD,
          canonicalOnRelays: 1,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 1,
          retiredMalformedSlot: true,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenancePublished>());
      expect(outcome.retiredMalformedSlot, isTrue);
    });

    test('a completed retraction-only tick survives as health', () {
      // The account was already on a conformant slot and only the orphaned
      // coordinate was left to scrub: no KeyPackage is published, so the tick
      // is health — and it still completed the migration.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          canonicalOnRelays: 2,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 0,
          retiredMalformedSlot: true,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenanceHealthy>());
      expect(outcome.retiredMalformedSlot, isTrue);
    });

    test('an unacked re-point is a failure that claims no retirement', () {
      // The destructive half never runs before the replacement is acked, so a
      // tick that could not publish must not read as a completed migration.
      final outcome = classifyKeyPackageMaintenance(
        _ffi(
          action: KpMaintenanceActionFfi.republishedFreshD,
          canonicalOnRelays: 1,
          relaysTargeted: 1,
          respondersProbed: 1,
          relaysHealed: 0,
          relayErrors: 1,
        ),
      );

      expect(outcome, isA<KeyPackageMaintenanceFailed>());
      expect(outcome.retiredMalformedSlot, isFalse);
    });

    test('an ordinary tick never invents a retirement', () {
      for (final action in _allActions) {
        final outcome = classifyKeyPackageMaintenance(
          _ffi(
            action: action,
            canonicalOnRelays: 1,
            relaysTargeted: 1,
            respondersProbed: 1,
            relaysHealed: 1,
          ),
        );
        expect(
          outcome.retiredMalformedSlot,
          isFalse,
          reason: '$action reported no retirement, so none may be claimed',
        );
      }
    });

    test('a completed retirement is visible in what gets logged', () {
      // The scheduler's only report of a tick is `debugPrint('$outcome')`, so a
      // field the rendering drops is a field nobody can observe.
      expect(
        const KeyPackageMaintenancePublished(
          relaysAcked: 1,
          mintedFreshSlot: true,
          retiredMalformedSlot: true,
        ).toString(),
        contains('slotRetired: true'),
      );
      expect(
        const KeyPackageMaintenanceHealthy(
          canonicalOnRelays: 1,
          respondersProbed: 1,
          retiredMalformedSlot: true,
        ).toString(),
        contains('slotRetired: true'),
      );
    });
  });

  group('KeyPackageMaintenanceFailed — retry disposition', () {
    test('a relay-side failure is worth retrying promptly', () {
      for (final kind in [
        KeyPackageFailureKind.noRelayResponded,
        KeyPackageFailureKind.publishNotAcked,
        KeyPackageFailureKind.initKeyPurgedUnreplaced,
      ]) {
        expect(
          KeyPackageMaintenanceFailed(kind).disposition,
          KeyPackageRetryDisposition.retryPromptly,
          reason: 'until this lands, nobody can invite the account',
        );
      }
    });

    test('a local error backs off instead of looping', () {
      expect(
        const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.tickErrored,
        ).disposition,
        KeyPackageRetryDisposition.retryLater,
      );
    });

    test('a missing identity waits for the user, not for a timer', () {
      expect(
        const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.identityUnavailable,
        ).disposition,
        KeyPackageRetryDisposition.awaitUserAction,
      );
    });

    test('having no relay configured waits for the user too', () {
      // A timer cannot add a relay: every "retry" re-runs the same early
      // return, so this keeps the ordinary cadence instead of laddering.
      expect(
        const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.noRelaysConfigured,
        ).disposition,
        KeyPackageRetryDisposition.awaitUserAction,
      );
    });

    test('the two zero-responder kinds carry OPPOSITE dispositions', () {
      // Why the split is worth making at all: one tick shape, two remedies,
      // and swapping them is the user-visible defect.
      expect(
        const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.noRelayResponded,
        ).disposition,
        KeyPackageRetryDisposition.retryPromptly,
      );
      expect(
        const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.noRelaysConfigured,
        ).disposition,
        isNot(
          const KeyPackageMaintenanceFailed(
            KeyPackageFailureKind.noRelayResponded,
          ).disposition,
        ),
      );
    });

    test('every failure kind has a disposition', () {
      // Guards the `switch` in `disposition`: adding a kind without deciding
      // its retry policy should not compile, and if that guard is ever
      // loosened this catches the omission at runtime.
      for (final kind in KeyPackageFailureKind.values) {
        expect(KeyPackageMaintenanceFailed(kind).disposition, isNotNull);
      }
    });
  });

  group('outcome constructors reject impossible states', () {
    test('a published outcome cannot claim zero acks', () {
      expect(
        () => KeyPackageMaintenancePublished(
          relaysAcked: 0,
          mintedFreshSlot: true,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'the "acked means acked" invariant lives in the type, so a '
            'future edit to the classifier cannot lose it',
      );
    });

    test('a healthy outcome cannot claim zero responders', () {
      expect(
        () => KeyPackageMaintenanceHealthy(
          canonicalOnRelays: 1,
          respondersProbed: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a healthy outcome cannot claim zero canonicals', () {
      expect(
        () => KeyPackageMaintenanceHealthy(
          canonicalOnRelays: 0,
          respondersProbed: 1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('outcomes carry no relay-identifying text (Rule 4/6/8)', () {
      // Every outcome ends up in a `debugPrint`; none of them may carry a url,
      // a `d`, or hex. Only counters and closed tokens cross this boundary, so
      // the guard is that the rendered form contains nothing but those.
      final rendered = [
        const KeyPackageMaintenanceHealthy(
          canonicalOnRelays: 1,
          respondersProbed: 1,
        ).toString(),
        const KeyPackageMaintenancePublished(
          relaysAcked: 1,
          mintedFreshSlot: false,
        ).toString(),
        const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.publishNotAcked,
        ).toString(),
        const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.noRelaysConfigured,
        ).toString(),
      ];

      for (final text in rendered) {
        expect(text, isNot(contains('://')));
        expect(text, isNot(contains('wss')));
        expect(
          RegExp('[0-9a-f]{16,}').hasMatch(text),
          isFalse,
          reason: 'no hex-looking run may reach a log line: $text',
        );
      }
    });
  });
}
