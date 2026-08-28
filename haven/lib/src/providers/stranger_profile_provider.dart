/// Provider for the member picker's typed-stranger resolve (plan §10 D2).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

/// Resolves a complete, valid npub the user just typed or pasted, keyed by
/// the EXACT npub string.
///
/// `autoDispose` + a family keyed on the npub itself is the whole staleness
/// fix, not a detail of it: watching this provider with a DIFFERENT npub is a
/// different provider instance, so the moment the query changes, nothing is
/// left watching the old one — it is dropped, and its result (even if it
/// later completes) is never observed by any widget. Showing a
/// previously-resolved name beside a different key being typed now would be
/// a sharper impersonation risk than the truncation bugs P0 fixed, so this
/// must never be "fixed" with a manually-tracked "latest request" flag —
/// Riverpod already gives the correct behaviour for free from the family key
/// alone.
///
/// Callers MUST gate constructing/watching this provider on D2's three
/// caller-side eligibility checks (a complete npub match, not already known
/// locally, and `resolveEntryPickState` returning `selectable`) — see
/// `eligibleStrangerNpub` in `widgets/circles/member_picker.dart`. Riverpod
/// providers are lazy, so gating the `ref.watch` call IS gating the network
/// call; nothing inside this provider re-checks eligibility.
///
/// Errors are swallowed (never propagated) — matches
/// `memberProfileProvider`'s convention for the same reason: a row that
/// cannot resolve a stranger's profile degrades to the npub-only fallback,
/// never an error state, and never a raw FFI error string reaching a widget
/// (Security Rule 8).
final AutoDisposeFutureProviderFamily<Profile?, String>
    strangerProfileResolveProvider =
    FutureProvider.autoDispose.family<Profile?, String>((ref, npub) async {
  final service = ref.watch(profileServiceProvider);
  try {
    return await service.resolveTypedStrangerProfile(npub);
  } on Object catch (e) {
    debugPrint('[Profile] strangerProfileResolveProvider: ${e.runtimeType}');
    return null;
  }
});
