/// Name circle page - circle naming step.
///
/// Second step of circle creation where users name their circle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/selected_members_list.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Second step of circle creation: naming the circle.
class NameCirclePage extends ConsumerStatefulWidget {
  /// Creates a [NameCirclePage].
  const NameCirclePage({required this.memberKeyPackages, super.key});

  /// KeyPackage data for each member to invite.
  final List<KeyPackageData> memberKeyPackages;

  @override
  ConsumerState<NameCirclePage> createState() => _NameCirclePageState();
}

class _NameCirclePageState extends ConsumerState<NameCirclePage> {
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isCreating = false;
  String? _errorMessage;
  CreationStage _stage = CreationStage.idle;

  /// Returns the member count text for display.
  String get _memberCountText {
    final count = widget.memberKeyPackages.length;
    final noun = count == 1 ? 'member' : 'members';
    return '$count $noun will be invited';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Name Your Circle')),
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
                        decoration: const InputDecoration(
                          labelText: 'Circle Name',
                          hintText: 'e.g., Family, Close Friends',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a circle name';
                          }
                          if (value.length > 50) {
                            return 'Name must be 50 characters or less';
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
                                    _memberCountText,
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

                      // Privacy assurance
                      Semantics(
                        label:
                            'Security information: Your location is '
                            'encrypted and private to this circle',
                        child: Card(
                          color: HavenSecurityColors.encrypted.withValues(
                            alpha: 0.1,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(HavenSpacing.base),
                            child: Row(
                              children: [
                                const Icon(
                                  LucideIcons.lock,
                                  color: HavenSecurityColors.encrypted,
                                  semanticLabel: 'Encryption indicator',
                                ),
                                const SizedBox(width: HavenSpacing.sm),
                                Expanded(
                                  child: Text(
                                    'Your location is encrypted and private to '
                                    'this circle',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
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
                                  Text(_stage.label),
                                ],
                              )
                            : const Text('Create Circle'),
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
    return Semantics(
      liveRegion: true,
      label: 'Creation progress: ${_stage.label}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: HavenSpacing.base),
        child: Column(
          children: [
            Semantics(
              value: '${(_stage.progress * 100).round()} percent complete',
              child: LinearProgressIndicator(value: _stage.progress),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(_stage.label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Future<void> _createCircle() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isCreating = true;
      _errorMessage = null;
      _stage = CreationStage.creatingGroup;
    });

    try {
      final circleService = ref.read(circleServiceProvider);
      final identityNotifier = ref.read(identityNotifierProvider.notifier);
      final relayService = ref.read(relayServiceProvider);

      // Look up the creator's own NIP-65 (kind 10002) so the Welcome-delivery
      // cascade has a third-tier fallback that targets the creator's own
      // relays rather than only the protocol-defined defaults. Best-effort —
      // a failure here must not block circle creation, so we fall through
      // with an empty list and let the Rust layer apply DEFAULT_RELAYS.
      final creatorFallbackRelays = await _fetchCreatorFallbackRelays(
        ref,
        relayService,
      );

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

      // Send invitations (welcome events)
      setState(() => _stage = CreationStage.sendingInvites);

      final total = result.welcomeEvents.length;
      // Publish all welcome events in parallel — each is independently
      // gift-wrapped for a different recipient, no shared mutable state.
      final welcomeResults = await Future.wait(
        result.welcomeEvents.map(
          (we) => relayService
              .publishWelcome(welcomeEvent: we)
              .then((_) => true)
              .onError((_, _) {
                debugPrint('[CircleCreate] Welcome invitation send failed');
                return false;
              }),
        ),
      );
      final sentCount = welcomeResults.where((ok) => ok).length;

      // MDK's create_group auto-merges the pending commit internally,
      // so no finalizePendingCommit call is needed here.
      // finalizePendingCommit is only required after add_members/remove_members.
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
            content: Text('Circle "$name" created! $total invitation(s) sent.'),
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
          _errorMessage = 'Identity error. Please check your identity setup.';
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    } on CircleServiceException catch (_) {
      debugPrint('[CircleCreate] Service error');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to create circle. Please try again.';
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    } on Object catch (_) {
      debugPrint('[CircleCreate] Unexpected error');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to create circle. Please try again.';
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    }
  }

  /// Best-effort lookup of the creator's own NIP-65 (kind 10002) read relays.
  ///
  /// Used as the third-tier fallback in the Welcome-delivery cascade. A
  /// failure here must never block circle creation — if the identity is
  /// missing or the relay fetch throws, we return an empty list and let the
  /// Rust cascade fall through to the protocol defaults.
  Future<List<String>> _fetchCreatorFallbackRelays(
    WidgetRef ref,
    RelayService relayService,
  ) async {
    try {
      final identity = await ref.read(identityProvider.future);
      if (identity == null) return const [];
      return await relayService.fetchNip65Relays(identity.pubkeyHex);
    } on Object catch (e) {
      debugPrint(
        '[CircleCreate] NIP-65 fallback fetch failed: ${e.runtimeType}',
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

  /// Human-readable label for this stage.
  String get label => switch (this) {
    CreationStage.idle => '',
    CreationStage.creatingGroup => 'Creating secure group...',
    CreationStage.sendingInvites => 'Sending invitations...',
    CreationStage.complete => 'Done!',
  };

  /// Progress value (0.0 to 1.0) for this stage.
  double get progress => switch (this) {
    CreationStage.idle => 0.0,
    CreationStage.creatingGroup => 0.33,
    CreationStage.sendingInvites => 0.66,
    CreationStage.complete => 1.0,
  };
}
