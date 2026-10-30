// What a circle change the driver answered is shown as, by its status only
// (Security Rule 8). Two promises: "awaiting relays" is never an error, and
// nothing but an acknowledged, applied commit is shown as made.
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show PublishStatusFfi, ReinviteResultFfi;
import 'package:haven/src/services/circle_service.dart';

void main() {
  test('every driver status maps to the delivery it means', () {
    expect({for (final s in PublishStatusFfi.values) s: changeDeliveryOf(s)}, {
      PublishStatusFfi.confirmed: ChangeDelivery.applied,
      // Staged and recorded, sent again until a relay takes it.
      PublishStatusFfi.unresolved: ChangeDelivery.awaitingRelays,
      // Not made: made later, or retired at the next open with a notice.
      PublishStatusFfi.queued: ChangeDelivery.awaitingRelays,
      PublishStatusFfi.rolledBack: ChangeDelivery.rejected,
      PublishStatusFfi.stale: ChangeDelivery.rejected,
      PublishStatusFfi.unrecorded: ChangeDelivery.rejected,
      PublishStatusFfi.refused: ChangeDelivery.rejected,
    });
  });

  test('only an acknowledged, applied commit is shown as made', () {
    expect(
      PublishStatusFfi.values.where(
        (s) => changeDeliveryOf(s) == ChangeDelivery.applied,
      ),
      [PublishStatusFfi.confirmed],
    );
  });

  test('a change still awaiting its relays is never shown as not made', () {
    // "Not made" carries the error copy and a retry; a retry of a change the
    // driver is still sending would stage it twice.
    for (final status in [
      PublishStatusFfi.unresolved,
      PublishStatusFfi.queued,
    ]) {
      expect(changeDeliveryOf(status), isNot(ChangeDelivery.rejected));
    }
  });

  test('every re-invite result maps to the delivery it means, none made', () {
    expect(
      {for (final r in ReinviteResultFfi.values) r: reinviteDeliveryOf(r)},
      {
        ReinviteResultFfi.reissuedAwaitingRelays:
            ReinviteDelivery.awaitingRelays,
        ReinviteResultFfi.queued: ReinviteDelivery.stillOwed,
        ReinviteResultFfi.notDue: ReinviteDelivery.stillOwed,
        ReinviteResultFfi.unsettled: ReinviteDelivery.stillOwed,
        ReinviteResultFfi.keyPackageMissing: ReinviteDelivery.stillOwed,
        // Looked for again on MDK's schedule.
        ReinviteResultFfi.noInbox: ReinviteDelivery.stillOwed,
        ReinviteResultFfi.unmade: ReinviteDelivery.stillOwed,
        // The user invites again; the change notice says so until then.
        ReinviteResultFfi.gaveUp: ReinviteDelivery.needsReinvite,
        ReinviteResultFfi.ended: ReinviteDelivery.ended,
      },
    );
  });
}
