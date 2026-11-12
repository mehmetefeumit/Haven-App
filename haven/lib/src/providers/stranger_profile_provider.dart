/// Providers for resolving who an npub on the invite screens belongs to: the
/// member picker's typed-stranger resolve (plan §10 D2) and the staged list.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/member_directory_provider.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/utils/member_display.dart';

/// Resolves a complete, valid npub the user just typed, pasted, scanned or
/// staged, keyed by the EXACT npub string.
///
/// `autoDispose` + a family keyed on the npub itself is the whole staleness
/// fix, not a detail of it: watching this provider with a DIFFERENT npub is a
/// different provider instance, so the moment the query changes, nothing is
/// left watching the old one — it is dropped once settled, and its result is
/// never observed by any widget. Showing a previously-resolved name beside a
/// different key being typed now would be a sharper impersonation risk than
/// the truncation bugs P0 fixed, so this must never be "fixed" with a
/// manually-tracked "latest request" flag — Riverpod already gives the
/// correct behaviour for free from the family key alone.
///
/// Two sanctioned triggers, and no others: the picker's typed-npub row, and
/// [stagedMemberIdentityProvider] for a staged npub. Callers MUST gate
/// watching this provider: the picker on D2's caller-side eligibility checks
/// (a complete npub match, not already known locally, a directory that read
/// cleanly, and `resolveEntryPickState` returning `selectable`) — see
/// `eligibleStrangerNpub` in `widgets/circles/member_picker.dart`; the
/// staged list on the directory-first rule in [stagedMemberIdentityProvider].
/// Riverpod providers are lazy, so gating the `ref.watch` call IS gating the
/// network call; nothing inside this provider re-checks eligibility.
///
/// Errors are swallowed (never propagated) — matches
/// `memberProfileProvider`'s convention for the same reason: a row that
/// cannot resolve a stranger's profile degrades to the npub-only fallback,
/// never an error state, and never a raw FFI error string reaching a widget
/// (Security Rule 8).
final AutoDisposeFutureProviderFamily<Profile?, String>
strangerProfileResolveProvider = FutureProvider.autoDispose
    .family<Profile?, String>((ref, npub) async {
      final service = ref.watch(profileServiceProvider);
      // Held only while the lookup is in flight: deleting and retyping a
      // character re-watches this npub before the answer is in, and must reuse
      // the request rather than send a second one. Released once settled, so an
      // abandoned key's answer is still dropped as described above.
      final link = ref.keepAlive();
      try {
        return await service.resolveTypedStrangerProfile(npub);
      } on Object catch (e) {
        debugPrint(
          '[Profile] strangerProfileResolveProvider: ${e.runtimeType}',
        );
        return null;
      } finally {
        link.close();
      }
    });

/// Downloads the published picture of ONE person whose npub resolved through
/// [strangerProfileResolveProvider] with no picture cached yet (owner
/// direction 2026-11-12, plan §10 D2).
///
/// A separate provider rather than a step of the resolve, so the name is
/// never held back by a picture: the resolve answers first, and the avatar
/// re-reads the cache when this lands. Watch it only for a resolved profile
/// whose `pictureBytes` is null — never for an unresolved or abandoned npub.
///
/// The picture is an HTTPS GET to a server the person chose, which learns
/// this device's network address and when it asked; the disclosure note on
/// the typed-npub row and on a looked-up staged row says so.
final AutoDisposeFutureProviderFamily<void, String> strangerPictureProvider =
    FutureProvider.autoDispose.family<void, String>((ref, pubkeyHex) async {
      // One in-flight download per pubkey, however often the row is rebuilt.
      final link = ref.keepAlive();
      var disposed = false;
      ref.onDispose(() => disposed = true);
      try {
        await ref.read(profileServiceProvider).downloadMemberPictures([
          pubkeyHex,
        ]);
      } finally {
        link.close();
      }
      if (!disposed) ref.invalidate(memberProfileProvider(pubkeyHex));
    });

/// Who a staged npub belongs to, as far as can be said: a hex pubkey for
/// the avatar and the name to show, each `null` while none resolved, and
/// whether relays were asked about them, which the row must then disclose.
typedef StagedMemberIdentity = ({
  String? pubkeyHex,
  String? name,
  bool lookedUp,
});

/// The identity shown on a staged-member row, keyed by npub, or `null` while
/// nothing is known, no relay was asked and the row shows the npub alone.
///
/// Keyed by the npub, never by how it was staged (suggestion tap, typed-row
/// tap, paste button, Done/Enter, QR), so every path shows the same person.
/// Directory first: a co-member in the local directory is answered from it
/// with NO network request, and only an npub the directory does not hold is
/// resolved — the same single-key lookup as the typed-npub row, once per
/// npub (it shares that row's provider instance), with the picture fetched
/// as there. A degraded directory, a failed read or one still on its first
/// load asks nothing: "not already known locally" cannot be judged from a
/// read that did not complete.
///
/// A plain synchronous provider so every dependency is re-watched in the
/// same build: a directory refresh keeps the previous value and never drops
/// the resolve it holds, so it cannot ask again. `lookedUp` is set here, by
/// the branch that asks, so the row's disclosure (the typed-npub row's, owner
/// direction 2026-11-12) cannot drift from the lookup it discloses. The host
/// page holds one subscription per staged npub, so a row scrolled out of a
/// lazy list does not re-ask on the way back.
final AutoDisposeProviderFamily<StagedMemberIdentity?, String>
stagedMemberIdentityProvider = Provider.autoDispose
    .family<StagedMemberIdentity?, String>((ref, npub) {
      final directory = ref.watch(memberDirectoryProvider).valueOrNull;
      if (directory == null) return null;
      for (final entry in directory.entries) {
        if (entry.npub == npub) {
          return (
            pubkeyHex: entry.pubkeyHex,
            name: entry.displayName,
            lookedUp: false,
          );
        }
      }
      if (directory.degraded || !publicProfilesEnabled) return null;
      final profile = ref
          .watch(strangerProfileResolveProvider(npub))
          .valueOrNull;
      if (profile == null) return (pubkeyHex: null, name: null, lookedUp: true);
      if (profile.pictureBytes == null) {
        ref.watch(strangerPictureProvider(profile.pubkeyHex));
      }
      final name = resolveEffectiveMemberName(
        npubFallback: '',
        profile: profile,
      );
      return (
        pubkeyHex: profile.pubkeyHex,
        name: name.isEmpty ? null : name,
        lookedUp: true,
      );
    });
