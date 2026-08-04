/// The map's single top-of-screen status slot.
///
/// ## Why one slot rather than two independent banners
///
/// Two surfaces exist that say "your location sharing is not working, and here
/// is why": [LocationAccessBanner] (the device cannot produce a fix, or Haven
/// is not allowed to read one) and [ClockSkewBanner] (fixes are produced and
/// sent, but this device's clock makes them useless). Each renders nothing
/// while its own condition is fine, so both are individually safe to place
/// unconditionally — which makes stacking them the tempting thing to do, and
/// the wrong one. They can be true at the same time, and two full-width error
/// cards over the map would eat the viewport and force the user to work out
/// which one to act on first.
///
/// ## Precedence, and why it goes this way
///
/// [LocationAccessBanner] wins. Its causes are strictly upstream: with the
/// device provider off or the permission gone there is no fix to timestamp at
/// all, so the clock is not the thing standing between the user and working
/// location sharing — and telling them to fix their clock first would send them
/// to a settings screen that changes nothing. Fixing access is also what makes
/// the clock evidence trustworthy again: `ClockSkewDetector`'s signals come
/// from publishes completing and peer locations decrypting, neither of which
/// happens while access is blocked, so a skew verdict formed before the outage
/// is stale by the time the banner would show it.
///
/// ## Why only ONE of the two is conditional
///
/// [LocationAccessBanner] already renders `SizedBox.shrink()` whenever access
/// is fine — that is a documented property of it, and the reason it is safe to
/// place unconditionally in the map stack. Wrapping it in `if (accessBlocked)`
/// here would restate the same condition in a second place, which is how the
/// two drift apart later. So it is built unconditionally and left to hide
/// itself, and the ONE thing this widget adds is the precedence: the clock
/// banner is suppressed while the access banner has something to say.
///
/// A note for anyone tempted to "simplify" this into
/// `blocked ? locationBanner : clockBanner`: it happens to work today, but only
/// because Riverpod fires `ref.listen` callbacks before the rebuild that would
/// unmount the listener, so [LocationAccessBanner]'s blocked → available
/// screen-reader announcement still escapes on the very edge that removes it.
/// That is an ordering Riverpod does not promise, and the cost of relying on it
/// is a screen-reader user being told sharing stopped and never told it
/// resumed. Not worth it to save a widget that costs a `SizedBox.shrink()`.
///
/// The clock banner is the conditional one because it has no such edge, and
/// because not building it while access is blocked also keeps it from
/// announcing the recovery of a warning the user was never shown.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/widgets/location/clock_skew_banner.dart';
import 'package:haven/src/widgets/map/location_access_banner.dart';

/// Renders whichever map status banner currently applies, at most one at a
/// time. See the library doc for the precedence rule.
///
/// Both children shrink-wrap and both need a bounded height to keep their
/// content reachable at large text scales, so this passes the incoming
/// constraints straight through: a `Stack` hands each child
/// `constraints.loosen()`, i.e. the same bounded max height this widget was
/// given, and sizes itself to whichever child actually rendered something.
class MapStatusBanners extends ConsumerWidget {
  /// Creates the map's status-banner slot.
  const MapStatusBanners({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accessBlocked = ref.watch(locationAccessProvider).isBlocked;
    // `Stack` rather than a `Column`: a `Column` hands its non-flex children
    // UNBOUNDED main-axis constraints, which would undo the very height bound
    // the caller supplies and put both banners back to running off the
    // viewport at large text scales. Exactly one child is ever non-empty, so
    // there is nothing to lay out side by side anyway.
    return Stack(
      children: [
        // Unconditional: it hides itself when access is fine, and duplicating
        // that condition here is how the two drift apart. See the library doc.
        const LocationAccessBanner(),
        if (!accessBlocked) const ClockSkewBanner(),
      ],
    );
  }
}
