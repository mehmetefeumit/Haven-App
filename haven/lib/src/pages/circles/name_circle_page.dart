/// Name circle page - circle naming step.
///
/// Second step of circle creation where users name their circle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/circles/selected_members_list.dart';
import 'package:haven/src/widgets/widgets.dart';

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
      body: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
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
                    Icons.groups,
                    size: 40,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: HavenSpacing.lg),

              // Circle name input
              TextFormField(
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
                          const Icon(Icons.people_outline, size: 20),
                          const SizedBox(width: HavenSpacing.sm),
                          Text(
                            _memberCountText,
                            style: Theme.of(context).textTheme.titleSmall,
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
                    'Security information: All location data will be '
                    'end-to-end encrypted using the Marmot Protocol',
                child: Card(
                  color: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
                  child: Padding(
                    padding: const EdgeInsets.all(HavenSpacing.base),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.lock_outline,
                          color: HavenSecurityColors.encrypted,
                          semanticLabel: 'Encryption indicator',
                        ),
                        const SizedBox(width: HavenSpacing.sm),
                        Expanded(
                          child: Text(
                            'All location data will be end-to-end encrypted '
                            'using the Marmot Protocol',
                            style: Theme.of(context).textTheme.bodySmall,
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
                  padding: const EdgeInsets.only(bottom: HavenSpacing.base),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: colorScheme.error),
                  ),
                ),

              // Create button
              FilledButton(
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

      // Create the circle using the CircleService.
      // Pass identity secret bytes directly to minimize exposure window.
      // The Rust layer handles secure memory (zeroize on drop).
      debugPrint('[CircleCreate] Getting identity secret bytes...');
      final secretBytes = await identityNotifier.getSecretBytes();
      debugPrint('[CircleCreate] Got secret bytes, calling createCircle...');
      final result = await circleService.createCircle(
        identitySecretBytes: secretBytes,
        memberKeyPackages: widget.memberKeyPackages,
        name: _nameController.text.trim(),
        circleType: CircleType.locationSharing,
      );
      debugPrint('[CircleCreate] createCircle returned successfully');

      // Send invitations (welcome events)
      setState(() => _stage = CreationStage.sendingInvites);

      final relayService = ref.read(relayServiceProvider);
      final total = result.welcomeEvents.length;
      var sentCount = 0;
      for (final welcomeEvent in result.welcomeEvents) {
        try {
          await relayService.publishWelcome(welcomeEvent: welcomeEvent);
          sentCount++;
        } on Exception catch (e) {
          debugPrint('Failed to send welcome invitation: $e');
        }
      }

      // Only finalize the pending commit if all welcomes were published.
      // Partial sends create inconsistent MLS state (phantom members).
      if (sentCount == total) {
        await circleService.finalizePendingCommit(result.circle.mlsGroupId);
      } else {
        throw CircleServiceException(
          'Only $sentCount of $total invitations sent. '
          'Circle was not finalized to prevent inconsistent state.',
        );
      }

      // Refresh circle list
      ref.invalidate(circlesProvider);

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
    } on IdentityServiceException catch (e) {
      debugPrint('Identity error during circle creation: ${e.message}');
      if (mounted) {
        setState(() {
          _errorMessage = 'Identity error. Please check your identity setup.';
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    } on CircleServiceException catch (e) {
      debugPrint('Circle service error during creation: ${e.message}');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to create circle. Please try again.';
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
    } on Exception catch (e) {
      debugPrint('Unexpected error during circle creation: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to create circle. Please try again.';
          _isCreating = false;
          _stage = CreationStage.idle;
        });
      }
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
