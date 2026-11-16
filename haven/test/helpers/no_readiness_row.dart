/// The Identity page and the Public Key QR page show no readiness row
/// (owner-directed 2026-11-16): whatever the account's readiness, neither page
/// says it, and neither offers that row's Retry or its Relay settings link.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';

class _FixedReachability extends OwnReachabilityNotifier {
  _FixedReachability(this.status);

  final OwnReachability status;
  bool read = false;
  int republishes = 0;

  @override
  OwnReachabilityState build() {
    read = true;
    return OwnReachabilityState(status: status);
  }

  @override
  Future<void> republish() async => republishes++;
}

/// The removed row's English copy and its two actions, frozen: the ARB no
/// longer holds them, so this is the only record of what it said.
const _removedRowCopy = [
  'Getting ready to receive invitations…',
  'Ready to be invited',
  "Can't check right now whether others can invite you",
  "Others can't invite you yet",
  "Others can't invite you until you add a relay",
  'Others can invite you once you continue past the relay settings notice',
  'Retry',
  'Relay settings',
];

/// Pumps the page [build] returns once per readiness state and fails if it
/// reads the readiness, shows any of the row's copy, or republishes.
Future<void> expectNoReadinessRow(
  WidgetTester tester,
  Widget Function(List<Override> overrides) build,
) async {
  for (final status in OwnReachability.values) {
    final readiness = _FixedReachability(status);
    // A fresh scope per state: a mounted ProviderScope keeps its overrides.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      build([ownReachabilityProvider.overrideWith(() => readiness)]),
    );
    await tester.pumpAndSettle();

    for (final text in _removedRowCopy) {
      expect(find.text(text), findsNothing, reason: '$status: "$text"');
    }
    expect(readiness.read, isFalse, reason: '$status: nothing reads it');
    expect(readiness.republishes, 0, reason: '$status');
  }
}
