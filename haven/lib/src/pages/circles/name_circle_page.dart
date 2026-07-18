/// Name circle page - circle naming step.
///
/// Second step of circle creation where users name their circle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/selected_members_list.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Second step of circle creation: naming the circle.
class NameCirclePage extends ConsumerStatefulWidget {
  /// Creates a [NameCirclePage].
  ///
  /// [initialName], when provided, pre-fills the name field — used by the
  /// Dark Matter cutover "re-create circle" flow (DM-4c).
  const NameCirclePage({
    required this.memberKeyPackages,
    this.initialName,
    super.key,
  });

  /// KeyPackage data for each member to invite.
  final List<KeyPackageData> memberKeyPackages;

  /// Pre-filled circle name, or `null` for the normal empty-name flow.
  final String? initialName;

  @override
  ConsumerState<NameCirclePage> createState() => _NameCirclePageState();
}

class _NameCirclePageState extends ConsumerState<NameCirclePage> {
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final initialName = widget.initialName;
    if (initialName != null && initialName.isNotEmpty) {
      _nameController.text = initialName;
    }
  }

  bool _isCreating = false;
  String? _errorMessage;
  CreationStage _stage = CreationStage.idle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.nameCircleTitle)),
      // The form below uses a `Spacer` to push the Create button to the
      // bottom of the viewport. Without a scrollable wrapper, that flex
      // layout overflows the moment the soft keyboard appears (autofocus
      // on the name input means it pops up immediately on this page).
      // The LayoutBuilder + ConstrainedBox(minHeight:) + IntrinsicHeight
      // pattern gives the Column at least the available viewport height —
      // so Spacer keeps its design intent when there is room — while
      // allowing it to grow and scroll once the keyboard reduces the
      // viewport below the natural content size. SafeArea handles
      // notches/gesture insets so the bottom inset measurement is
      // accurate on all form factors.
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 2 * HavenSpacing.base,
              ),
              child: IntrinsicHeight(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Circle icon preview
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            LucideIcons.users,
                            size: 40,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(height: HavenSpacing.lg),

                      // Circle name input
                      TextFormField(
                        key: WidgetKeys.circleNameInput,
                        controller: _nameController,
                        decoration: InputDecoration(
                          labelText: l10n.nameCircleNameLabel,
                          hintText: l10n.nameCircleNameHint,
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return l10n.nameCircleNameEmptyError;
                          }
                          if (value.length > 50) {
                            return l10n.nameCircleNameTooLongError;
                          }
                          return null;
                        },
                        textCapitalization: TextCapitalization.words,
                        autofocus: true,
                        enabled: !_isCreating,
                      ),
                      const SizedBox(height: HavenSpacing.lg),

                      // Member summary
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(HavenSpacing.base),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(LucideIcons.users, size: 20),
                                  const SizedBox(width: HavenSpacing.sm),
                                  Text(
                                    l10n.nameCircleMembersToInvite(
                                      widget.memberKeyPackages.length,
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ],
                              ),
                              const SizedBox(height: HavenSpacing.sm),
                              SelectedMembersSummary(
                                members: widget.memberKeyPackages
                                    .map((kp) => kp.pubkey)
                                    .toList(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: HavenSpacing.base),

                      // What sharing in this circle means
                      Container(
                        padding: const EdgeInsets.all(HavenSpacing.base),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          l10n.nameCircleSharingInfo,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),

                      const Spacer(),

                      // Creation progress
                      if (_isCreating) _buildProgress(),

                      // Error message
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: HavenSpacing.base,
                          ),
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ),

                      // Create button
                      FilledButton(
                        key: WidgetKeys.createCircleConfirm,
                        onPressed: _isCreating ? null : _createCircle,
                        child: _isCreating
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation(
                                        colorScheme.onPrimary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: HavenSpacing.sm),
                                  Text(_stage.label(l10n)),
                                ],
                              )
                            : Text(l10n.nameCircleCreateCta),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress() {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      label: l10n.nameCircleProgressSemantics(_stage.label(l10n)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.base),
        child: Column(
          children: [
            Semantics(
              value: l10n.nameCirclePercentComplete(
                (_stage.progress * 100).round(),
              ),
              child: LinearProgressIndicator(value: _stage.progress),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              _stage.label(l10n),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createCircle() async {
    if (!_formKey.currentState!.validate()) return;

    final l10n = AppLocalizations.of(context);

    setState(() {
      _isCreating = true;
      _errorMessage = null;
      _stage = CreationStage.creatingGroup;
    });

    try {
      final circleService = ref.read(circleServiceProvider);
      final identityNotifier = ref.read(identityNotifierProvider.notifier);

      // Two-plane model: the creator's tier-3 Welcome-delivery fallback is
      // their OWN inbox relays (kind 10050), read locally. Best-effort — a
      // failure here must not block circle creation. If this and the
      // invitee's own relays are all empty, the Rust layer FAILS CLOSED
      // (no public-default fallback) rather than leaking the recipient's
      // pubkey to public relays.
      final creatorFallbackRelays = await _fetchCreatorFallbackRelays(ref);

      // Create the circle using the CircleService.
      // Pass identity secret bytes directly to minimize exposure window.
      // The Rust layer handles secure memory (zeroize on drop).
      final secretBytes = await identityNotifier.getSecretBytes();
      final result = await circleService.createCircle(
        identitySecretBytes: secretBytes,
        memberKeyPackages: widget.memberKeyPackages,
        name: _nameController.text.trim(),
        circleType: CircleType.locationSharing,
        creatorFallbackRelays: creatorFallbackRelays,
      );

      // `CircleService.createCircle` already published the gift-wrapped
      // Welcome events and confirmed (or rolled back) the engine's pending
      // group-creation state internally (publish-before-apply, Rule 13) —
      // nothing further to publish here.
      setState(() => _stage = CreationStage.sendingInvites);

      final total = result.welcomesTotal;
      final sentCount = result.welcomesSent;

      if (sentCount < total) {
        debugPrint('[CircleCreate] partial invitation send');
      }

      // Auto-select the newly created circle so the map immediately
      // shows member locations without requiring a manual tap.
      ref.read(selectedCircleIdProvider.notifier).state =
          result.circle.mlsGroupId;

      // Refresh circle list and trigger immediate location publishing.
      // read() after invalidate() is required for fire-and-forget
      // FutureProviders that nothing watches.
      ref
        ..invalidate(circlesProvider)
        ..invalidate(keyPackagePublisherProvider)
        ..read(keyPackagePublisherProvider)
        ..invalidate(locationPublisherProvider)
        ..read(locationPublisherProvider)
        ..invalidate(memberLocationsProvider);

      // Kick off the admin-side burst-poll window so the new joiner's
      // first wire activity (commit / first location) is picked up
      // within seconds rather than on the next 30 s / 60 s tick. The
      // burst self-terminates after a jittered 150–240 s window.
      ref
          .read(joinWatcherProvider.notifier)
          .startAdminWatch(result.circle.mlsGroupId);

      setState(() => _stage = CreationStage.complete);

      if (mounted) {
        final name = _nameController.text.trim();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.nameCircleCreatedSnack(name, total)),
          ),
        );

        // Pop back to circles page (pop twice: NameCircle and CreateCircle)
        Navigator.of(context)
          ..pop() // Pop NameCirclePage
          ..pop(); // Pop CreateCirclePage
      }
    } on IdentityServiceException catch (_) {
      debugPrint('[CircleCreate] Identity error');
      if (mounted) {
        setState(() {
          _errorMessage = l10n.nameCircleIdentityError;
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    } on CircleServiceException catch (_) {
      debugPrint('[CircleCreate] Service error');
      if (mounted) {
        setState(() {
          _errorMessage = l10n.nameCircleCreateError;
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    } on Object catch (_) {
      debugPrint('[CircleCreate] Unexpected error');
      if (mounted) {
        setState(() {
          _errorMessage = l10n.nameCircleCreateError;
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    }
  }

  /// Best-effort lookup of the creator's own inbox (kind 10050) relays.
  ///
  /// Used as the third-tier fallback in the Welcome-delivery cascade
  /// (member inbox → member NIP-65 → creator inbox → FAIL CLOSED). A failure
  /// here must never block circle creation — if the relay read throws we
  /// return an empty list. NOTE: an empty return does NOT fall through to
  /// public defaults; the Rust cascade now fails closed with
  /// `MissingWelcomeRelays` rather than leaking the recipient's pubkey. Do
  /// NOT re-introduce a default-relay fallback here.
  Future<List<String>> _fetchCreatorFallbackRelays(WidgetRef ref) async {
    // The creator's own inbox relays (kind 10050), read locally from
    // preferences. Haven never publishes a creator NIP-65 (kind 10002), so
    // fetching that from the network would always be empty; the creator's
    // configured inbox list is the correct, non-empty third-tier fallback.
    try {
      return await ref.read(inboxRelaysProvider.future);
    } on Object catch (e) {
      debugPrint(
        '[CircleCreate] creator inbox fallback fetch failed: ${e.runtimeType}',
      );
      return const [];
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
}

/// Circle creation stages for progress display.
enum CreationStage {
  /// Not started.
  idle,

  /// Creating the MLS group.
  creatingGroup,

  /// Sending invitations.
  sendingInvites,

  /// Creation complete.
  complete;

  /// Human-readable, localized label for this stage.
  String label(AppLocalizations l10n) => switch (this) {
    CreationStage.idle => '',
    CreationStage.creatingGroup => l10n.nameCircleStageCreatingGroup,
    CreationStage.sendingInvites => l10n.nameCircleStageSendingInvites,
    CreationStage.complete => l10n.nameCircleStageComplete,
  };

  /// Progress value (0.0 to 1.0) for this stage.
  double get progress => switch (this) {
    CreationStage.idle => 0.0,
    CreationStage.creatingGroup => 0.33,
    CreationStage.sendingInvites => 0.66,
    CreationStage.complete => 1.0,
  };
}
