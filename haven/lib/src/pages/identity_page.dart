/// Identity management page for Haven.
///
/// This page allows users to:
/// - Generate a new Nostr identity
/// - View their public key (npub)
/// - Export their secret key (nsec) for backup
/// - Delete their identity (with confirmation)
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:haven/src/theme/theme.dart';

/// Page for managing the user's Nostr identity.
class IdentityPage extends StatefulWidget {
  /// Creates the identity page.
  const IdentityPage({super.key});

  @override
  State<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends State<IdentityPage> {
  late final IdentityService _identityService;
  Identity? _identity;
  String? _nsec;
  bool _isLoading = true;
  bool _isGenerating = false;
  bool _showNsec = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _identityService = NostrIdentityService();
    _loadIdentity();
  }

  /// Loads the existing identity from secure storage.
  Future<void> _loadIdentity() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final identity = await _identityService.getIdentity();
      if (mounted) {
        setState(() {
          _identity = identity;
          _isLoading = false;
        });
      }
    } on IdentityServiceException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
          _isLoading = false;
        });
      }
    }
  }

  /// Generates a new Nostr identity.
  Future<void> _generateIdentity() async {
    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });

    try {
      final identity = await _identityService.createIdentity();
      if (mounted) {
        setState(() {
          _identity = identity;
          _isGenerating = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Identity created and saved securely!'),
            backgroundColor: HavenSecurityColors.encrypted,
          ),
        );
      }
    } on IdentityServiceException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
          _isGenerating = false;
        });
      }
    }
  }

  /// Exports the nsec for display.
  Future<void> _exportNsec() async {
    try {
      final nsec = await _identityService.exportNsec();
      if (mounted) {
        setState(() {
          _nsec = nsec;
          _showNsec = true;
        });
      }
    } on IdentityServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export: ${e.message}'),
            backgroundColor: HavenSecurityColors.danger,
          ),
        );
      }
    }
  }

  /// Deletes the identity after confirmation.
  Future<void> _deleteIdentity() async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Identity?'),
        content: const Text(
          'This will permanently delete your Nostr identity. '
          'Make sure you have backed up your nsec if you want to recover it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _identityService.deleteIdentity();
      if (mounted) {
        setState(() {
          _identity = null;
          _nsec = null;
          _showNsec = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Identity deleted'),
            backgroundColor: HavenSecurityColors.warning,
          ),
        );
      }
    } on IdentityServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete: ${e.message}'),
            backgroundColor: HavenSecurityColors.danger,
          ),
        );
      }
    }
  }

  /// Copies text to clipboard.
  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nostr Identity')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(HavenSpacing.base),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_errorMessage != null) _buildErrorCard(),
                  if (_identity == null) _buildNoIdentityView(),
                  if (_identity != null) _buildIdentityView(),
                ],
              ),
            ),
    );
  }

  Widget _buildErrorCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Text(
          _errorMessage!,
          style: TextStyle(color: colorScheme.onErrorContainer),
        ),
      ),
    );
  }

  /// Builds the view when no identity exists.
  Widget _buildNoIdentityView() {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.lg),
        child: Column(
          children: [
            Icon(
              Icons.person_add,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: HavenSpacing.base),
            Text(
              'No Identity Found',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'Generate a new Nostr identity to get started. '
              'This identity will be securely stored on your device.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.lg),
            FilledButton.icon(
              onPressed: _isGenerating ? null : _generateIdentity,
              icon: _isGenerating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: Text(
                _isGenerating ? 'Generating...' : 'Generate Identity',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the view when an identity exists.
  Widget _buildIdentityView() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Identity status card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(HavenSpacing.md),
                  decoration: BoxDecoration(
                    color: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(HavenSpacing.md),
                  ),
                  child: const Icon(
                    Icons.verified_user,
                    color: HavenSecurityColors.encrypted,
                    size: 32,
                  ),
                ),
                const SizedBox(width: HavenSpacing.base),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Identity Active',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        'Stored securely on device',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: HavenSpacing.base),

        // Public keys card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Public Key (npub)',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: HavenSpacing.sm),
                _buildKeyContainer(
                  value: _identity!.npub,
                  onCopy: () => _copyToClipboard(_identity!.npub, 'npub'),
                  tooltip: 'Copy npub',
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  'Public Key (hex)',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: HavenSpacing.sm),
                _buildKeyContainer(
                  value: _identity!.pubkeyHex,
                  onCopy: () =>
                      _copyToClipboard(_identity!.pubkeyHex, 'Public key'),
                  tooltip: 'Copy hex',
                  useSmallFont: true,
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  'Created: ${_identity!.createdAt.toLocal()}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: HavenSpacing.base),

        // Secret key card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber,
                      color: HavenSecurityColors.warning,
                    ),
                    const SizedBox(width: HavenSpacing.sm),
                    Text(
                      'Secret Key (nsec)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(
                  'Your secret key gives full access to your identity. '
                  'Never share it with anyone.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: HavenSpacing.md),
                if (!_showNsec)
                  OutlinedButton.icon(
                    onPressed: _exportNsec,
                    icon: const Icon(Icons.visibility),
                    label: const Text('Reveal Secret Key'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HavenSecurityColors.warning,
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(HavenSpacing.md),
                        decoration: BoxDecoration(
                          color: HavenSecurityColors.warning.withValues(
                            alpha: 0.1,
                          ),
                          borderRadius: BorderRadius.circular(HavenSpacing.sm),
                          border: Border.all(
                            color: HavenSecurityColors.warning.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(_nsec!, style: HavenTypography.mono),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 20),
                              onPressed: () => _copyToClipboard(_nsec!, 'nsec'),
                              tooltip: 'Copy nsec',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: HavenSpacing.sm),
                      TextButton(
                        onPressed: () => setState(() => _showNsec = false),
                        child: const Text('Hide Secret Key'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: HavenSpacing.lg),

        // Delete button
        OutlinedButton.icon(
          onPressed: _deleteIdentity,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete Identity'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }

  Widget _buildKeyContainer({
    required String value,
    required VoidCallback onCopy,
    required String tooltip,
    bool useSmallFont = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(HavenSpacing.md),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(HavenSpacing.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              value,
              style: useSmallFont
                  ? HavenTypography.monoSmall
                  : HavenTypography.mono,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            onPressed: onCopy,
            tooltip: tooltip,
          ),
        ],
      ),
    );
  }
}
