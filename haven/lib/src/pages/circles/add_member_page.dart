/// Add member page — lets a circle admin invite new members to an
/// already-created circle.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/pages/circles/qr_scanner_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page that lets a circle admin add new members to an existing circle.
///
/// Reuses the same [MemberSearchBar] + [PendingMemberTile] picker pattern
/// as the create-circle flow but combines selection and confirmation on a
/// single screen (no separate naming step — the circle already exists).
class AddMemberPage extends ConsumerStatefulWidget {
  /// Creates an [AddMemberPage].
  const AddMemberPage({required this.circle, super.key});

  /// The circle to add members to.
  final Circle circle;

  @override
  ConsumerState<AddMemberPage> createState() => _AddMemberPageState();
}

class _AddMemberPageState extends ConsumerState<AddMemberPage> {
  /// Selected member npubs.
  final List<String> _selectedMembers = [];

  /// Validation status per member.
  final Map<String, ValidationStatus> _memberStatus = {};

  /// KeyPackage data per member (when validated).
  final Map<String, KeyPackageData> _memberKeyPackages = {};

  /// Error messages per member.
  final Map<String, String> _memberErrors = {};

  /// Members whose validation failed due to a network error (retryable).
  final Set<String> _networkFailures = {};

  /// True while the add operation is in flight.
  bool _isAdding = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text('Add to ${widget.circle.displayName}')),
      body: Padding(
        // Keep the bottom CTA clear of the gesture/home indicator without
        // reflowing the whole body (equivalent to a bottom SafeArea inset).
        padding: EdgeInsets.fromLTRB(
          HavenSpacing.base,
          HavenSpacing.base,
          HavenSpacing.base,
          HavenSpacing.base + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MemberSearchBar(
              onMemberAdded: _onMemberAdded,
              onQrScanRequested: _openQrScanner,
              existingMembers: _selectedMembers,
            ),
            const SizedBox(height: HavenSpacing.lg),

            if (_selectedMembers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Selected (${_selectedMembers.length})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    TextButton(
                      onPressed: _clearAll,
                      child: const Text('Clear All'),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: _selectedMembers.isEmpty
                  ? _buildEmptyState()
                  : _buildMemberList(),
            ),

            // What adding a member means — kept as a neutral, plain-language
            // note (not a green security badge) per the app's color doctrine.
            Container(
              padding: const EdgeInsets.all(HavenSpacing.base),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                "New members can see this circle's encrypted "
                'locations once they accept the invitation.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: HavenSpacing.base),

            FilledButton(
              key: WidgetKeys.addMemberConfirm,
              onPressed: (_canAdd && !_isAdding) ? _onAddMembers : null,
              child: _isAdding
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
                        Text(_sendButtonLabel(inProgress: true)),
                      ],
                    )
                  : Text(_sendButtonLabel(inProgress: false)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          LucideIcons.userPlus,
          size: 48,
          color: colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: HavenSpacing.base),
        Text(
          'Add circle members',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          'Search by ID or scan their QR code to add members.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildMemberList() {
    return ListView.builder(
      itemCount: _selectedMembers.length,
      itemBuilder: (context, index) {
        final npub = _selectedMembers[index];
        final status = _memberStatus[npub] ?? ValidationStatus.validating;
        final error = _memberErrors[npub];
        final isNetworkFailure = _networkFailures.contains(npub);

        return PendingMemberTile(
          npub: npub,
          status: status,
          errorMessage: error,
          onRemove: () => _onMemberRemoved(npub),
          onRetry: isNetworkFailure ? () => _retryMember(npub) : null,
        );
      },
    );
  }

  bool get _canAdd {
    if (_selectedMembers.isEmpty) return false;
    return _selectedMembers.every(
      (npub) => _memberStatus[npub] == ValidationStatus.valid,
    );
  }

  /// Label for the send button, pluralized by the number of selected members.
  String _sendButtonLabel({required bool inProgress}) {
    final plural = _selectedMembers.length > 1;
    if (inProgress) {
      return plural ? 'Sending invitations...' : 'Sending invitation...';
    }
    return plural ? 'Send invitations' : 'Send invitation';
  }

  void _onMemberAdded(String npub) {
    setState(() {
      _selectedMembers.add(npub);
      _memberStatus[npub] = ValidationStatus.validating;
    });
    _validateMember(npub);
  }

  void _onMemberRemoved(String npub) {
    setState(() {
      _selectedMembers.remove(npub);
      _memberStatus.remove(npub);
      _memberKeyPackages.remove(npub);
      _memberErrors.remove(npub);
      _networkFailures.remove(npub);
    });
  }

  void _clearAll() {
    setState(() {
      _selectedMembers.clear();
      _memberStatus.clear();
      _memberKeyPackages.clear();
      _memberErrors.clear();
      _networkFailures.clear();
    });
  }

  Future<void> _validateMember(String npub) async {
    final relayService = ref.read(relayServiceProvider);
    try {
      final keyPackage = await relayService.fetchKeyPackage(npub);
      if (!mounted || !_selectedMembers.contains(npub)) return;

      if (keyPackage == null) {
        setState(() {
          _memberStatus[npub] = ValidationStatus.invalid;
          _memberErrors[npub] = 'No Haven account found';
        });
        return;
      }

      // Exclude members who are already in this circle.
      // The KeyPackage event JSON carries the member's hex pubkey; compare
      // against circle.members[].pubkey (also hex). Do not compare npub↔hex
      // directly — the picker works in npub space.
      try {
        final eventMap =
            jsonDecode(keyPackage.eventJson) as Map<String, dynamic>;
        final hex = eventMap['pubkey'] as String;
        if (widget.circle.members.any((m) => m.pubkey == hex)) {
          if (mounted && _selectedMembers.contains(npub)) {
            setState(() {
              _memberStatus[npub] = ValidationStatus.invalid;
              _memberErrors[npub] = 'Already in this circle';
            });
          }
          return;
        }
      } on Object catch (_) {
        // JSON parse failure — skip the exclusion check, do not crash.
      }

      if (mounted && _selectedMembers.contains(npub)) {
        setState(() {
          _memberStatus[npub] = ValidationStatus.valid;
          _memberKeyPackages[npub] = keyPackage;
          _networkFailures.remove(npub);
        });
      }
    } on RelayServiceException catch (e) {
      debugPrint(
        'Relay error fetching KeyPackage for member: ${e.runtimeType}',
      );
      if (!mounted || !_selectedMembers.contains(npub)) return;
      setState(() {
        _memberStatus[npub] = ValidationStatus.invalid;
        _memberErrors[npub] = 'Could not verify member';
        _networkFailures.add(npub);
      });
    } on Object catch (e) {
      debugPrint('Unexpected error fetching KeyPackage: ${e.runtimeType}');
      if (!mounted || !_selectedMembers.contains(npub)) return;
      setState(() {
        _memberStatus[npub] = ValidationStatus.invalid;
        _memberErrors[npub] = 'Something went wrong';
        _networkFailures.add(npub);
      });
    }
  }

  void _retryMember(String npub) {
    setState(() {
      _memberStatus[npub] = ValidationStatus.validating;
      _memberErrors.remove(npub);
      _networkFailures.remove(npub);
    });
    _validateMember(npub);
  }

  Future<void> _openQrScanner() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const QrScannerPage()),
    );

    if (result != null && mounted) {
      final npub = NpubValidator.extract(result);
      if (npub != null && !_selectedMembers.contains(npub)) {
        _onMemberAdded(npub);
      } else if (npub != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Member already added')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No valid ID found in QR code')),
        );
      }
    }
  }

  Future<void> _onAddMembers() async {
    final keyPackages = _selectedMembers
        .where(_memberKeyPackages.containsKey)
        .map((npub) => _memberKeyPackages[npub]!)
        .toList();

    if (keyPackages.isEmpty) return;

    setState(() => _isAdding = true);

    try {
      // Two-plane model: the adder's tier-3 Welcome-delivery fallback is
      // their OWN inbox relays (kind 10050), read locally. Best-effort — a
      // failure here must not block the add. If this and the invitee's own
      // relays are all empty, the Rust layer FAILS CLOSED
      // (no public-default fallback) rather than leaking the recipient's
      // pubkey to public relays.
      final creatorFallbackRelays = await _fetchCreatorFallbackRelays(ref);

      final secretBytes =
          await ref.read(identityNotifierProvider.notifier).getSecretBytes();

      final result = await ref.read(circleServiceProvider).addMember(
        identitySecretBytes: secretBytes,
        mlsGroupId: widget.circle.mlsGroupId,
        memberKeyPackages: keyPackages,
        creatorFallbackRelays: creatorFallbackRelays,
      );

      if (!mounted) return;

      ref
        ..invalidate(circlesProvider)
        ..invalidate(memberLocationsProvider);

      ref
          .read(joinWatcherProvider.notifier)
          .startAdminWatch(widget.circle.mlsGroupId);

      final circleName = widget.circle.displayName;
      final plural = result.welcomesTotal > 1;
      final message = result.welcomesSent == result.welcomesTotal
          ? (plural
                ? 'Invitations sent to $circleName'
                : 'Invitation sent to $circleName')
          : 'Invitations sent (${result.welcomesSent} of '
                '${result.welcomesTotal}). Delivery pending for the rest.';

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

      Navigator.of(context).pop();
    } on IdentityServiceException catch (_) {
      debugPrint('[AddMember] Identity error');
      if (!mounted) return;
      setState(() => _isAdding = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to add member. Please try again.'),
        ),
      );
    } on CircleServiceException catch (_) {
      debugPrint('[AddMember] Service error');
      if (!mounted) return;
      setState(() => _isAdding = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to add member. Please try again.'),
        ),
      );
    } on Object catch (_) {
      debugPrint('[AddMember] Unexpected error');
      if (!mounted) return;
      setState(() => _isAdding = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to add member. Please try again.'),
        ),
      );
    }
  }

  /// Best-effort lookup of the adder's own inbox (kind 10050) relays.
  ///
  /// Used as the third-tier fallback in the Welcome-delivery cascade
  /// (member inbox → member NIP-65 → creator inbox → FAIL CLOSED). A failure
  /// here must never block the add — if the relay read throws we
  /// return an empty list. NOTE: an empty return does NOT fall through to
  /// public defaults; the Rust cascade now fails closed with
  /// `MissingWelcomeRelays` rather than leaking the recipient's pubkey. Do
  /// NOT re-introduce a default-relay fallback here.
  Future<List<String>> _fetchCreatorFallbackRelays(WidgetRef ref) async {
    try {
      return await ref.read(inboxRelaysProvider.future);
    } on Object catch (e) {
      debugPrint(
        '[AddMember] creator inbox fallback fetch failed: ${e.runtimeType}',
      );
      return const [];
    }
  }
}
