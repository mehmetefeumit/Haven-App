/// Provider for the count of pending invitations.
///
/// Derives the count from [pendingInvitationsProvider] to avoid unnecessary
/// rebuilds when invitation content changes but the count stays the same.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/invitation_provider.dart';

/// The number of pending invitations.
///
/// Returns 0 while loading or on error, and the list length on success.
/// Widgets that only need the count (e.g. badge) should watch this instead
/// of [pendingInvitationsProvider] to minimise rebuilds.
final invitationCountProvider = Provider<int>((ref) {
  final invitationsAsync = ref.watch(pendingInvitationsProvider);
  return invitationsAsync.valueOrNull?.length ?? 0;
});
