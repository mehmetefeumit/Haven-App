/// Every verdict's copy, title, body and remedy, by the table the plan and
/// the frozen English set (D2 §3/§4): no remedy on a false premise.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/widgets/map/sharing_health_banner.dart';

void main() {
  late AppLocalizations l10n;
  final since = DateTime.utc(2026, 8, 28, 12);
  final now = since.add(const Duration(minutes: 30));

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  const repair = SharingHealthRemedy.repair;
  const none = SharingHealthRemedy.none;

  /// (title, body, remedy, shows an age) for each paused reason.
  Map<SharingPausedReason, (String, String?, SharingHealthRemedy, bool)>
  table() => {
    SharingPausedReason.relayDisconnected: (
      l10n.sharingHealthTitleStopped,
      null,
      repair,
      true,
    ),
    SharingPausedReason.receiveSubscriptionLost: (
      l10n.sharingHealthTitleNotReceiving,
      null,
      repair,
      true,
    ),
    SharingPausedReason.sessionStillHeld: (
      l10n.sharingHealthTitleStopped,
      l10n.sharingHealthBodySessionHeld,
      none,
      true,
    ),
    SharingPausedReason.circleQuarantined: (
      l10n.sharingHealthTitleQuarantined,
      l10n.sharingHealthBodyQuarantined,
      SharingHealthRemedy.tryAgain,
      false,
    ),
    SharingPausedReason.circleDisbanded: (
      l10n.sharingHealthTitleDisbanded,
      l10n.sharingHealthBodyDisbanded,
      none,
      true,
    ),
    SharingPausedReason.circleUnrecoverable: (
      l10n.sharingHealthTitleUnrecoverable,
      l10n.sharingHealthBodyUnrecoverable,
      SharingHealthRemedy.recreate,
      true,
    ),
    SharingPausedReason.routingCollision: (
      l10n.sharingHealthTitlePaused,
      l10n.sharingHealthBodyCollision,
      none,
      true,
    ),
    SharingPausedReason.routingUnchecked: (
      l10n.sharingHealthTitlePaused,
      l10n.sharingHealthBodyCannotCheck,
      none,
      true,
    ),
    SharingPausedReason.leaving: (
      l10n.sharingHealthTitleLeaving,
      l10n.sharingHealthBodyLeaving,
      none,
      true,
    ),
    SharingPausedReason.stalled: (
      l10n.sharingHealthTitleStalled,
      l10n.sharingHealthBodyStalled,
      none,
      true,
    ),
    SharingPausedReason.removalUnmade: (
      l10n.sharingHealthTitleNotSending,
      l10n.sharingHealthBodyRemovalUnmade,
      none,
      true,
    ),
    SharingPausedReason.removalUnmadeUntold: (
      l10n.sharingHealthTitleNotSending,
      l10n.sharingHealthBodyRemovalUnmadeNoNotice,
      none,
      true,
    ),
    SharingPausedReason.departureDue: (
      l10n.sharingHealthTitleNotSending,
      l10n.sharingHealthBodyDepartureDue,
      repair,
      true,
    ),
    SharingPausedReason.awaitsForeground: (
      l10n.sharingHealthTitleBackgroundPaused,
      l10n.sharingHealthBodyAwaitsForeground,
      repair,
      true,
    ),
    SharingPausedReason.awaitingRelays: (
      l10n.sharingHealthTitleStopped,
      l10n.sharingHealthBodyAwaitingRelays,
      repair,
      true,
    ),
    SharingPausedReason.acknowledged: (
      l10n.sharingHealthTitleStopped,
      l10n.sharingHealthBodyAcknowledged,
      repair,
      true,
    ),
    SharingPausedReason.stagedWithoutRecord: (
      l10n.sharingHealthTitleStopped,
      l10n.sharingHealthBodyStagedWithoutRecord,
      repair,
      true,
    ),
    SharingPausedReason.storedInput: (
      l10n.sharingHealthTitleNotSending,
      l10n.sharingHealthBodyStoredInput,
      repair,
      true,
    ),
  };

  test('the table covers every reason', () {
    expect(table().keys.toSet(), SharingPausedReason.values.toSet());
  });

  test('every paused reason resolves to its title, body and remedy', () {
    for (final MapEntry(key: reason, value: (title, body, remedy, aged))
        in table().entries) {
      final copy = resolveSharingHealthCopy(
        SharingHealth.paused(reason, since),
        l10n,
        now,
      )!;
      expect(copy.title, title, reason: '$reason title');
      expect(copy.body, body, reason: '$reason body');
      expect(copy.remedy, remedy, reason: '$reason remedy');
      expect(
        copy.age,
        aged ? formatSharingHealthAge(l10n, const Duration(minutes: 30)) : null,
        reason: '$reason age',
      );
    }
  });

  test('no remedy on a false premise: a stall, a leave and a removal not '
      'made offer no Repair, and a halted circle offers Re-create', () {
    SharingHealthRemedy remedyOf(SharingPausedReason reason) =>
        resolveSharingHealthCopy(
          SharingHealth.paused(reason, since),
          l10n,
          now,
        )!.remedy;
    for (final reason in const [
      SharingPausedReason.stalled,
      SharingPausedReason.leaving,
      SharingPausedReason.removalUnmade,
      SharingPausedReason.removalUnmadeUntold,
      SharingPausedReason.routingUnchecked,
      SharingPausedReason.routingCollision,
      SharingPausedReason.circleDisbanded,
      SharingPausedReason.sessionStillHeld,
    ]) {
      expect(remedyOf(reason), none, reason: '$reason');
    }
    expect(
      remedyOf(SharingPausedReason.circleUnrecoverable),
      SharingHealthRemedy.recreate,
    );
  });

  test('an age is shown only when a delivery proves it', () {
    final copy = resolveSharingHealthCopy(
      SharingHealth.paused(
        SharingPausedReason.awaitingRelays,
        since,
        ageProvable: false,
      ),
      l10n,
      now,
    )!;
    expect(copy.age, isNull);
  });

  test('inferred verdicts carry a title and an age, and Repair', () {
    final sending = resolveSharingHealthCopy(
      SharingHealth.publishFailing(since),
      l10n,
      now,
    )!;
    expect(sending.title, l10n.sharingHealthTitleNotSending);
    expect(sending.body, isNull);
    expect(sending.remedy, repair);
    final receiving = resolveSharingHealthCopy(
      SharingHealth.receiveSilent(since),
      l10n,
      now,
    )!;
    expect(receiving.title, l10n.sharingHealthTitleNotReceiving);
    expect(receiving.age, isNotNull);
    expect(resolveSharingHealthCopy(SharingHealth.healthy, l10n, now), isNull);
  });
}
