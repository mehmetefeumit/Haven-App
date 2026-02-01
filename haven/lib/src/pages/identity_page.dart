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
            backgroundColor: Colors.green,
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
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Deletes the identity after confirmation.
  Future<void> _deleteIdentity() async {
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
            style: TextButton.styleFrom(foregroundColor: Colors.red),
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
            backgroundColor: Colors.orange,
          ),
        );
      }
    } on IdentityServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete: ${e.message}'),
            backgroundColor: Colors.red,
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
      appBar: AppBar(
        title: const Text('Nostr Identity'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_errorMessage != null)
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: Colors.red.shade700),
                        ),
                      ),
                    ),
                  if (_identity == null) _buildNoIdentityView(),
                  if (_identity != null) _buildIdentityView(),
                ],
              ),
            ),
    );
  }

  /// Builds the view when no identity exists.
  Widget _buildNoIdentityView() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.person_add, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'No Identity Found',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Generate a new Nostr identity to get started. '
              'This identity will be securely stored on your device.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
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
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the view when an identity exists.
  Widget _buildIdentityView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.verified_user,
                        color: Colors.green.shade700,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Identity Active',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Stored securely on device',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Public Key (npub)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _identity!.npub,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () =>
                            _copyToClipboard(_identity!.npub, 'npub'),
                        tooltip: 'Copy npub',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Public Key (hex)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _identity!.pubkeyHex,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () => _copyToClipboard(
                          _identity!.pubkeyHex,
                          'Public key',
                        ),
                        tooltip: 'Copy hex',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Created: ${_identity!.createdAt.toLocal()}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    const Text(
                      'Secret Key (nsec)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your secret key gives full access to your identity. '
                  'Never share it with anyone.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                if (!_showNsec)
                  OutlinedButton.icon(
                    onPressed: _exportNsec,
                    icon: const Icon(Icons.visibility),
                    label: const Text('Reveal Secret Key'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange.shade700,
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _nsec!,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 20),
                              onPressed: () => _copyToClipboard(_nsec!, 'nsec'),
                              tooltip: 'Copy nsec',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
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
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _deleteIdentity,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete Identity'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
        ),
      ],
    );
  }
}
