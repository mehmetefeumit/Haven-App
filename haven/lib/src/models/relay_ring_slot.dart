/// Per-relay segment state for the shared app-bar refresh ring.
///
/// One [RelayRingSlotState] describes one arc of the `RefreshRingButton`
/// (`widgets/common/refresh_ring/`). It is the single shared vocabulary between
/// the two manual-refresh flows — invitation inbox polling
/// (`InvitationPollStatusNotifier`) and relay-event validation
/// (`RelayStatusNotifier`) — and the widget that renders them.
///
/// The relay URL is deliberately absent: the widget layer never needs it, and
/// keeping it out of the model prevents a relay URL from ever reaching the
/// semantics/accessibility tree (CLAUDE.md Security Rule #8, two-plane
/// privacy). Slots are matched to relays positionally; the order is stable
/// within one refresh lifetime.
///
/// Lives under `models/` (not `widgets/`) so the providers can depend on it
/// without the layering inversion of importing from the widget tree.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/colors.dart';

/// State of a single relay arc segment in the refresh ring.
///
/// The four states form the gray → amber → green/red progression the ring
/// animates through as each relay is contacted and resolves.
enum RelayRingSlotState {
  /// Relay not yet contacted this refresh (or the ring is idle).
  pending,

  /// Relay contact is in flight.
  checking,

  /// Relay responded and provided the data the refresh needed.
  ok,

  /// Relay was unreachable, or did not hold the required data.
  error,
}

/// Semantic colors for the ring states.
///
/// All four are fixed semantic constants (identical in light and dark) so a
/// hue on the ring always means the same thing — consistent with Haven's
/// achromatic-plus-semantic palette. `pending` uses
/// [HavenStatusColors.offline] (#737373) rather than `ColorScheme.outline`
/// (near-white in the light theme, and so invisible on a white app bar).
extension RelayRingSlotColor on RelayRingSlotState {
  /// The base arc color for this state.
  Color get color => switch (this) {
    RelayRingSlotState.pending => HavenStatusColors.offline, // #737373 gray
    RelayRingSlotState.checking => HavenSecurityColors.warning, // #D97706 amber
    RelayRingSlotState.ok => HavenSecurityColors.encrypted, // #16A34A green
    RelayRingSlotState.error => HavenSecurityColors.danger, // #DC2626 red
  };
}
