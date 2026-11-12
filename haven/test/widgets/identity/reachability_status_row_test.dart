/// Widget tests for [ReachabilityStatusRow]: every state says what it means
/// in words beside an icon (never colour alone), offers only the action that
/// can change it, and is announced when it changes — not on every tick.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/widgets/identity/reachability_status_row.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_relay_service.dart' show relayListsCurrent;

/// Holds [status] and records Retry presses instead of publishing.
class _FixedReachability extends OwnReachabilityNotifier {
  _FixedReachability(this.status);

  final OwnReachability status;
  int retries = 0;

  @override
  OwnReachabilityState build() => OwnReachabilityState(status: status);

  @override
  Future<void> republish() async => retries++;
}

const _copy = {
  OwnReachability.checking: 'Getting ready to receive invitations…',
  OwnReachability.ready: 'Ready to be invited',
  OwnReachability.cantCheck:
      "Can't check right now whether others can invite you",
  OwnReachability.notReady: "Others can't invite you yet",
  OwnReachability.noRelaysConfigured:
      "Others can't invite you until you add a relay",
  OwnReachability.awaitingReset:
      'Others can invite you once you continue past the relay settings notice',
};

Future<_FixedReachability> _pump(
  WidgetTester tester,
  OwnReachability status,
) async {
  final notifier = _FixedReachability(status);
  // A fresh scope per state: a mounted ProviderScope keeps its overrides.
  await tester.pumpWidget(const SizedBox());
  await pumpLocalized(
    tester,
    const Scaffold(body: ReachabilityStatusRow()),
    overrides: [ownReachabilityProvider.overrideWith(() => notifier)],
  );
  return notifier;
}

void main() {
  testWidgets('every state is words beside an icon', (tester) async {
    for (final status in OwnReachability.values) {
      await _pump(tester, status);
      expect(find.text(_copy[status]!), findsOneWidget, reason: '$status');
      expect(find.byType(Icon), findsOneWidget, reason: '$status');
    }
  });

  testWidgets('Retry is offered only where a relay coming back can change '
      'the answer, at a 48 dp target', (tester) async {
    for (final status in OwnReachability.values) {
      final notifier = await _pump(tester, status);
      final offered =
          status == OwnReachability.notReady ||
          status == OwnReachability.cantCheck;
      expect(
        find.text('Retry'),
        offered ? findsOneWidget : findsNothing,
        reason: '$status',
      );
      if (!offered) continue;
      final size = tester.getSize(find.widgetWithText(TextButton, 'Retry'));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('Retry'));
      expect(notifier.retries, 1);
    }
  });

  testWidgets('no relays configured links to Relay settings, at a 48 dp '
      'target', (tester) async {
    await _pump(tester, OwnReachability.noRelaysConfigured);

    final link = find.widgetWithText(TextButton, 'Relay settings');
    expect(link, findsOneWidget);
    expect(tester.getSize(link).height, greaterThanOrEqualTo(48));
  });

  testWidgets('the status is a live region and the icon is not read', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, OwnReachability.notReady);

    expect(
      tester.getSemantics(find.text(_copy[OwnReachability.notReady]!)),
      matchesSemantics(
        label: _copy[OwnReachability.notReady],
        isLiveRegion: true,
      ),
    );
    expect(
      find.descendant(
        of: find.byType(ExcludeSemantics),
        matching: find.byIcon(LucideIcons.triangleAlert),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('a routine tick that changes nothing does not change what is '
      'announced', (tester) async {
    await pumpLocalized(tester, const Scaffold(body: ReachabilityStatusRow()));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReachabilityStatusRow)),
    );
    expect(find.text(_copy[OwnReachability.checking]!), findsOneWidget);

    container.read(ownReachabilityProvider.notifier)
      ..recordRelayLists(relayListsCurrent)
      ..recordKeyPackage(
        const KeyPackageMaintenancePublished(
          relaysAcked: 1,
          isFreshSlotMinted: true,
        ),
      );
    await tester.pump();
    expect(find.text(_copy[OwnReachability.ready]!), findsOneWidget);

    // An offline maintenance tick: no flicker through "checking" or
    // "can't check" — the label, and so the announcement, stays.
    container
        .read(ownReachabilityProvider.notifier)
        .recordKeyPackage(
          const KeyPackageMaintenanceFailed(
            KeyPackageFailureKind.noRelayResponded,
          ),
        );
    await tester.pump();
    expect(find.text(_copy[OwnReachability.ready]!), findsOneWidget);
    expect(find.text(_copy[OwnReachability.checking]!), findsNothing);
  });
}
