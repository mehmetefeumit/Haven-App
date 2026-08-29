// Host tests for the subscription-health boundary: the FFI action mapping and
// the counters the maintenance tick reports.
//
// Both halves are plain value types — `SubscriptionHealthActionFfi` is a
// generated Dart enum and `SubscriptionHealthResult` is a const class — so this
// runs on the host with no Rust bridge, which is the point: the mapping is the
// whole of what Dart learns about a tick, and it must stay provable.

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart' show SubscriptionHealthActionFfi;
import 'package:haven/src/services/nostr_relay_service.dart'
    show mapSubscriptionHealthAction;
import 'package:haven/src/services/relay_service.dart';

void main() {
  group('mapSubscriptionHealthAction', () {
    test('maps every FFI variant to a distinct service action', () {
      // Totality: every generated variant must map. A `default` arm would make
      // a newly added FFI variant silently report whatever that arm returned;
      // with the exhaustive switch it is a compile error instead, and this
      // iterates `values` so a variant that were somehow unmapped throws here.
      final mapped = <SubscriptionHealthAction>{};
      for (final ffi in SubscriptionHealthActionFfi.values) {
        mapped.add(mapSubscriptionHealthAction(ffi));
      }
      expect(
        mapped.length,
        SubscriptionHealthActionFfi.values.length,
        reason:
            'each FFI action must map to its OWN service action; collapsing '
            'two of them loses the distinction the boundary exists to carry',
      );
    });

    test('pins the meaning of each variant', () {
      expect(
        mapSubscriptionHealthAction(SubscriptionHealthActionFfi.engineOff),
        SubscriptionHealthAction.engineOff,
      );
      expect(
        mapSubscriptionHealthAction(SubscriptionHealthActionFfi.healthy),
        SubscriptionHealthAction.healthy,
      );
      expect(
        mapSubscriptionHealthAction(SubscriptionHealthActionFfi.resubscribed),
        SubscriptionHealthAction.resubscribed,
      );
      expect(
        mapSubscriptionHealthAction(
          SubscriptionHealthActionFfi.targetedReanchor,
        ),
        SubscriptionHealthAction.targetedReanchor,
      );
    });

    test('keeps the two re-anchor remedies distinct', () {
      // They differ by orders of magnitude in cost, and a targeted re-anchor is
      // EXPECTED on a device whose circles are simply idle. Folding it into
      // `resubscribed` would show a normal quiet device as one that keeps
      // losing its relays.
      expect(
        mapSubscriptionHealthAction(
          SubscriptionHealthActionFfi.targetedReanchor,
        ),
        isNot(
          mapSubscriptionHealthAction(
            SubscriptionHealthActionFfi.resubscribed,
          ),
        ),
      );
    });
  });

  group('SubscriptionHealthResult', () {
    test('carries the subscription counters', () {
      const r = SubscriptionHealthResult(
        action: SubscriptionHealthAction.targetedReanchor,
        relaysTotal: 3,
        relaysStillConnecting: 1,
        subscriptionsExpected: 6,
        subscriptionsLive: 6,
        subscriptionsSilent: 2,
      );

      expect(r.action, SubscriptionHealthAction.targetedReanchor);
      expect(r.relaysTotal, 3);
      expect(r.relaysStillConnecting, 1);
      expect(r.relaysDisconnected, 0, reason: 'defaulted');
      expect(r.subscriptionsExpected, 6);
      expect(r.subscriptionsLive, 6);
      expect(r.subscriptionsSilent, 2);
    });

    test('a live-socket blackout is visible ONLY in the subscription counts',
        () {
      // The shape of the field failure: a relay ends our REQ with `CLOSED` but
      // keeps the socket open. Every connectivity counter reads healthy, and
      // the shortfall between expected and live is the only evidence.
      const r = SubscriptionHealthResult(
        action: SubscriptionHealthAction.resubscribed,
        relaysTotal: 2,
        subscriptionsExpected: 4,
        subscriptionsLive: 3,
      );

      expect(
        r.relaysDisconnected,
        0,
        reason: 'the socket never dropped — nothing to reconnect',
      );
      expect(
        r.subscriptionsExpected - r.subscriptionsLive,
        1,
        reason:
            'a REQ the session expects but the pool no longer holds must be '
            'visible to Dart, or the blackout stays invisible to the user',
      );
    });

    test('the empty fallback zeroes every counter', () {
      const r = SubscriptionHealthResult.empty();
      expect(r.action, SubscriptionHealthAction.engineOff);
      expect(r.relaysTotal, 0);
      expect(r.relaysStillConnecting, 0);
      expect(r.relaysDisconnected, 0);
      expect(r.subscriptionsExpected, 0);
      expect(r.subscriptionsLive, 0);
      expect(r.subscriptionsSilent, 0);
    });
  });
}
