/// Circles page for Haven.
///
/// Manages user's circles - groups of trusted contacts for location sharing.
library;

import 'package:flutter/material.dart';

import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page displaying and managing user's circles.
///
/// Shows a list of circles with pending invitations highlighted at the top.
/// Requires identity setup before circle creation is enabled.
class CirclesPage extends StatefulWidget {
  /// Creates the circles page.
  ///
  /// Optionally accepts an [identityService] for testing.
  const CirclesPage({super.key, IdentityService? identityService})
    : _identityService = identityService;

  final IdentityService? _identityService;

  @override
  State<CirclesPage> createState() => _CirclesPageState();
}

class _CirclesPageState extends State<CirclesPage> {
  late final IdentityService _identityService;
  Identity? _identity;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _identityService = widget._identityService ?? NostrIdentityService();
    _loadIdentity();
  }

  /// Loads the existing identity from secure storage.
  Future<void> _loadIdentity() async {
    try {
      final identity = await _identityService.getIdentity();
      if (mounted) {
        setState(() {
          _identity = identity;
          _isLoading = false;
        });
      }
    } on IdentityServiceException {
      // If loading fails, treat as no identity
      if (mounted) {
        setState(() {
          _identity = null;
          _isLoading = false;
        });
      }
    }
  }

  /// Handles the create circle button press.
  void _onCreateCirclePressed() {
    if (_identity == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Circle creation requires identity setup first'),
        ),
      );
      return;
    }

    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => const CreateCirclePage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Circles'),
        actions: const [
          EncryptionBadge(size: EncryptionBadgeSize.small),
          SizedBox(width: HavenSpacing.base),
        ],
      ),
      body: const _CirclesEmptyState(),
      floatingActionButton: _isLoading
          ? null
          : FloatingActionButton.extended(
              onPressed: _onCreateCirclePressed,
              icon: const Icon(Icons.add),
              label: const Text('Create Circle'),
            ),
    );
  }
}

class _CirclesEmptyState extends StatelessWidget {
  const _CirclesEmptyState();

  @override
  Widget build(BuildContext context) {
    return const HavenEmptyState(
      icon: Icons.groups_outlined,
      title: 'No Circles Yet',
      message:
          'Create a circle to start sharing your location '
          'with trusted friends and family. '
          'All location data is end-to-end encrypted.',
    );
  }
}
