/// Provider for the local petname the user saved for one pubkey.
///
/// The member list gets petnames for free — they ride along on
/// `CircleMember.displayName`. A pending invitation has no member row: the
/// inviter is a stranger until Accept. This provider is how the invitation
/// card still honours a nickname the user saved for that person in some
/// other circle, so the one name an attacker cannot forge is not lost to the
/// one they chose (docs/MEMBER_PICKER_PLAN.md §7.2).
///
/// Purely local — a SQLCipher contact-table read, no relay traffic — and
/// autoDispose, so nothing is retained past the card that asked.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';

/// autoDispose family provider for a pubkey's local petname.
///
/// Returns `null` when no nickname is saved **and** when the lookup fails:
/// a name is a convenience on every surface that shows one, so a storage
/// error degrades to "no nickname" rather than to an error state.
final AutoDisposeFutureProviderFamily<String?, String> contactNicknameProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, pubkeyHex) async {
  final service = ref.watch(circleServiceProvider);
  try {
    return await service.getContactDisplayName(pubkey: pubkeyHex);
  } on Object catch (e) {
    debugPrint('[Contact] contactNicknameProvider: ${e.runtimeType}');
    return null;
  }
});
