/// The staged-member list shared by the two invite screens
/// (`create_circle_page.dart`, `add_member_page.dart`), so the two cannot
/// drift on who a staged row shows or on how often it asks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/stranger_profile_provider.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';

/// Holds one [stagedMemberIdentityProvider] subscription per staged npub on
/// the host page.
///
/// Staged rows live in a lazily built sliver list, so a row scrolled off
/// screen drops its own watch; without a holder above it the autoDispose
/// identity would be thrown away and asked for again on the way back.
/// [ConsumerState] closes whatever is still held when the page goes.
mixin StagedMemberIdentities<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  final Map<String, ProviderSubscription<StagedMemberIdentity?>> _held = {};

  /// Holds [npub]'s identity for as long as it stays staged.
  void holdStagedIdentity(String npub) {
    _held[npub] ??= ref.listenManual(
      stagedMemberIdentityProvider(npub),
      (_, _) {},
    );
  }

  /// Lets go of [npub]'s identity once it is no longer staged.
  void releaseStagedIdentity(String npub) => _held.remove(npub)?.close();

  /// Lets go of every staged identity.
  void releaseAllStagedIdentities() {
    for (final subscription in _held.values) {
      subscription.close();
    }
    _held.clear();
  }
}

/// A [PendingMemberTile] showing who [npub] belongs to, as far as
/// [stagedMemberIdentityProvider] knows.
///
/// Only watches: the host page holds the identity (see
/// [StagedMemberIdentities]).
class StagedMemberTile extends ConsumerWidget {
  /// Creates a [StagedMemberTile].
  const StagedMemberTile({
    required this.npub,
    required this.status,
    this.errorMessage,
    this.onRemove,
    this.onRetry,
    super.key,
  });

  /// The staged npub.
  final String npub;

  /// See [PendingMemberTile.status].
  final ValidationStatus status;

  /// See [PendingMemberTile.errorMessage].
  final String? errorMessage;

  /// See [PendingMemberTile.onRemove].
  final VoidCallback? onRemove;

  /// See [PendingMemberTile.onRetry].
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(stagedMemberIdentityProvider(npub));
    return PendingMemberTile(
      npub: npub,
      status: status,
      pubkeyHex: identity?.pubkeyHex,
      name: identity?.name,
      lookedUp: identity?.lookedUp ?? false,
      errorMessage: errorMessage,
      onRemove: onRemove,
      onRetry: onRetry,
    );
  }
}
