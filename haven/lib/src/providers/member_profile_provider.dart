/// Provider for a single circle member's public Nostr profile (M8 F2).
///
/// Replaces `member_avatar_provider.dart` (deleted at the Wave 6 cutover,
/// D11). Unlike the old avatar provider, this is keyed by a **plain
/// `String pubkeyHex`** —
/// per D6/plan §6.2, public profiles are resolved by pubkey alone, with no
/// `mlsGroupId` component: the same pubkey resolves to the same profile
/// across every circle the user shares with that member.
///
/// Security design:
/// - Last-known value kept for the identity's session (owner-directed
///   2026-11-26: a member with a name or photo never falls back to the npub).
///   Every member read under an identity stays alive, so a row that remounts
///   shows its name and photo at once, and a failed re-read keeps them. The
///   values are public kind-0 data already held at rest in the SQLCipher
///   store, not secrets (Rule 9 concerns key material).
/// - A logout or login releases every kept member, which disposes them and so
///   drops every value (`identityScopedProviders`).
/// - A failed read is an error carrying the previous value, never `null`
///   data: a `null` would overwrite the last-known name with the npub. Every
///   consumer reads `.valueOrNull`, so no error UI is ever shown, and only
///   the error's type is logged (Rule 15).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/profile_service.dart';

/// Keeps a member's [memberProfileProvider] alive once anything listens to
/// it, until this provider is invalidated with the identity scope.
///
/// A listener rather than `ref.keepAlive()`: Riverpod drops keep-alive links
/// at every invalidation, so the batch refresh's invalidation of the family
/// would dispose — and lose the value of — every member no row was showing.
/// On the container rather than this ref: a member reads this provider, and
/// Riverpod counts a ref's listen as a dependency, which makes that a cycle.
final Provider<void Function(String pubkeyHex)> memberProfileKeeperProvider =
    Provider<void Function(String)>((ref) {
      final kept = <String>{};
      final subscriptions = <ProviderSubscription<Object?>>[];
      var live = true;
      ref.onDispose(() {
        live = false;
        for (final subscription in subscriptions) {
          subscription.close();
        }
      });
      return (pubkeyHex) {
        // Added before listening: the listen re-enters through the member's
        // own add-listener hook.
        if (live && kept.add(pubkeyHex)) {
          subscriptions.add(
            ref.container.listen(memberProfileProvider(pubkeyHex), (_, _) {}),
          );
        }
      };
    });

/// Family provider for a circle member's public profile.
///
/// `null` when the member has never been fetched or published. A failed read
/// is an error that keeps the previous value (see the library doc), and is
/// read again once the circle session next opens: on Android every read
/// fails while the session is handed to the foreground service, and nothing
/// else would ask again until the next refresh.
///
/// Invalidate the whole family (e.g. via [`memberProfileRefreshProvider`])
/// after a batch refresh to re-read every kept member.
///
/// Usage:
/// ```dart
/// final profile = ref.watch(memberProfileProvider(member.pubkey)).valueOrNull;
/// ```
final AutoDisposeFutureProviderFamily<Profile?, String> memberProfileProvider =
    FutureProvider.autoDispose.family<Profile?, String>((ref, pubkeyHex) async {
      final service = ref.watch(profileServiceProvider);
      final keep = ref.read(memberProfileKeeperProvider);
      // On a listener, not here: listening to this member from its own first
      // build would mount it a second time.
      ref.onAddListener(() => keep(pubkeyHex));
      final circleService = ref.read(circleServiceProvider);
      // Taken before the read, so an open that completes while it fails counts.
      final reopened = circleService is NostrCircleService
          ? circleService.nextSessionOpen
          : null;
      var current = true;
      ref.onDispose(() => current = false);
      try {
        return await service.getMemberProfile(pubkeyHex);
      } on Object catch (e) {
        debugPrint('[Profile] memberProfileProvider: ${e.runtimeType}');
        if (reopened != null) {
          unawaited(
            reopened.then((_) {
              if (current) ref.invalidateSelf();
            }),
          );
        }
        rethrow;
      }
    });
