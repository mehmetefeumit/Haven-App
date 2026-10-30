/// The production live-sync service hands every stop outcome to the
/// sharing-health model, so a session a stop left holding the guard is shown
/// in Circle details instead of dying in a debug log.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/subscription_service.dart';

class _Recording extends SharingHealthNotifier {
  final List<LiveSyncStopOutcome> outcomes = [];

  @override
  SharingHealth build() => SharingHealth.healthy;

  @override
  void recordStopOutcome(LiveSyncStopOutcome outcome) => outcomes.add(outcome);
}

void main() {
  test('subscriptionServiceProvider reports stop outcomes to the model', () {
    final health = _Recording();
    final container = ProviderContainer(
      overrides: [sharingHealthProvider.overrideWith(() => health)],
    );
    addTearDown(container.dispose);

    final service =
        container.read(subscriptionServiceProvider) as NostrSubscriptionService;
    final report = service.onStopOutcome;
    expect(report, isNotNull, reason: 'the app passed no callback');

    report!(LiveSyncStopOutcome.stillHolding);
    report(LiveSyncStopOutcome.stopped);
    expect(health.outcomes, [
      LiveSyncStopOutcome.stillHolding,
      LiveSyncStopOutcome.stopped,
    ]);
  });
}
