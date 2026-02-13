/// Create circle page - member selection step.
///
/// First step of circle creation where users add members by npub or QR scan.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/circles/qr_scanner_page.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/widgets.dart';

/// First step of circle creation: member selection.
class CreateCirclePage extends ConsumerStatefulWidget {
  /// Creates a [CreateCirclePage].
  const CreateCirclePage({super.key});

  @override
  ConsumerState<CreateCirclePage> createState() => _CreateCirclePageState();
}

class _CreateCirclePageState extends ConsumerState<CreateCirclePage> {
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

  /// General error message.
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Members'),
        actions: const [
          EncryptionBadge(size: EncryptionBadgeSize.small),
          SizedBox(width: HavenSpacing.base),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Search bar
            MemberSearchBar(
              onMemberAdded: _onMemberAdded,
              onQrScanRequested: _openQrScanner,
              existingMembers: _selectedMembers,
            ),
            const SizedBox(height: HavenSpacing.lg),

            // Selected members header
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
                    if (_selectedMembers.isNotEmpty)
                      TextButton(
                        onPressed: _clearAll,
                        child: const Text('Clear All'),
                      ),
                  ],
                ),
              ),

            // Member list or empty state
            Expanded(
              child: _selectedMembers.isEmpty
                  ? _buildEmptyState()
                  : _buildMemberList(),
            ),

            // Error message
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: HavenSpacing.base),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),

            // Continue button
            FilledButton(
              onPressed: _canContinue ? _onContinue : null,
              child: const Text('Continue'),
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
          Icons.person_add_outlined,
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
          'Search by npub or scan their QR code.\n'
          'All invitations are end-to-end encrypted.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
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

  bool get _canContinue {
    if (_selectedMembers.isEmpty) return false;

    // All members must be valid
    return _selectedMembers.every(
      (npub) => _memberStatus[npub] == ValidationStatus.valid,
    );
  }

  void _onMemberAdded(String npub) {
    setState(() {
      _selectedMembers.add(npub);
      _memberStatus[npub] = ValidationStatus.validating;
      _errorMessage = null;
    });

    // Fetch KeyPackage from relays to validate member
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
      setState(() {
        if (keyPackage != null) {
          _memberStatus[npub] = ValidationStatus.valid;
          _memberKeyPackages[npub] = keyPackage;
          _networkFailures.remove(npub);
        } else {
          _memberStatus[npub] = ValidationStatus.invalid;
          _memberErrors[npub] = 'No Haven account found';
        }
      });
    } on RelayServiceException catch (e) {
      debugPrint('Relay error fetching KeyPackage for member: $e');
      if (!mounted || !_selectedMembers.contains(npub)) return;
      setState(() {
        _memberStatus[npub] = ValidationStatus.invalid;
        _memberErrors[npub] = 'Could not reach relays';
        _networkFailures.add(npub);
      });
    } on Object catch (e) {
      debugPrint('Unexpected error fetching KeyPackage: $e');
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
      // Extract and validate the npub from QR result
      final npub = NpubValidator.extract(result);
      if (npub != null && !_selectedMembers.contains(npub)) {
        _onMemberAdded(npub);
      } else if (npub != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Member already added')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No valid npub found in QR code')),
        );
      }
    }
  }

  Future<void> _onContinue() async {
    // Collect KeyPackages for all valid members
    final keyPackages = _selectedMembers
        .where((npub) => _memberKeyPackages.containsKey(npub))
        .map((npub) => _memberKeyPackages[npub]!)
        .toList();

    if (keyPackages.isEmpty) {
      setState(() => _errorMessage = 'No valid members to invite');
      return;
    }

    // Navigate to naming page
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => NameCirclePage(memberKeyPackages: keyPackages),
      ),
    );
  }
}
