/// Create circle page - member selection step.
///
/// First step of circle creation where users add members by ID or QR scan.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/circles/qr_scanner_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_directory_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/key_package_kind.dart';
import 'package:haven/src/utils/member_pick_state.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/member_picker.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// First step of circle creation: member selection.
class CreateCirclePage extends ConsumerStatefulWidget {
  /// Creates a [CreateCirclePage].
  ///
  /// [initialName] pre-fills the circle name on the naming step — used by
  /// the Dark Matter cutover "re-create circle" flow (DM-4c) so re-creating
  /// an orphaned legacy circle does not require retyping its old name. The
  /// member list still starts empty: a legacy circle's roster is not
  /// recoverable (see `Circle.isLegacyOrphaned`), so every member must be
  /// re-added and re-invited regardless.
  const CreateCirclePage({this.initialName, super.key});

  /// Pre-filled circle name for the naming step, or `null` for the normal
  /// empty-name flow.
  final String? initialName;

  @override
  ConsumerState<CreateCirclePage> createState() => _CreateCirclePageState();
}

class _CreateCirclePageState extends ConsumerState<CreateCirclePage> {
  /// Selected member npubs.
  final List<String> _selectedMembers = [];

  /// [_selectedMembers], mirrored as a [Set] so the picker's O(1) staged-npub
  /// lookup never rebuilds a fresh `Set` from the list on every keystroke —
  /// kept in sync wherever [_selectedMembers] is mutated.
  final Set<String> _stagedNpubs = {};

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

  /// What is currently typed in the search field, held here because the list
  /// beside the field is derived from it. The field itself still owns the
  /// text that renders the caret.
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Someone who shares no circles yet has nobody to pick, so the guidance
    // is still the right content; someone who does gets rows instead of a
    // placeholder telling them to type. Loading counts as neither.
    final directory = ref.watch(memberDirectoryProvider);
    final directoryIsEmpty = directory.valueOrNull?.entries.isEmpty ?? false;
    final showGuidance = _selectedMembers.isEmpty && directoryIsEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.createCircleTitle)),
      body: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ONE viewport for everything except the CTA, matching the sibling
            // AddMemberPage. Pinning the field and the section heading above a
            // pinned button makes the fixed chrome taller than the body at a
            // 2x text scale, which is how CI run 31462924650 clipped that page
            // on a device LARGER than the 320dp budget.
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: MemberSearchField(
                      onMemberAdded: _onMemberAdded,
                      onQrScanRequested: _openQrScanner,
                      onQueryChanged: (query) =>
                          setState(() => _query = query),
                      entryStateFor: _entryStateFor,
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: HavenSpacing.lg),
                  ),
                  if (_selectedMembers.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
                        // Wrap, not Row: at a large text scale the count and
                        // "Clear all" together exceed the body width, and a
                        // Row can only overflow where a Wrap moves the button
                        // to its own line.
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              l10n.createCircleSelectedCount(
                                _selectedMembers.length,
                              ),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            TextButton(
                              onPressed: _clearAll,
                              child: Text(l10n.commonClearAll),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: _selectedMembers.length,
                      itemBuilder: _buildMemberTile,
                    ),
                  ],
                  MemberPickerResults(
                    query: _query,
                    stagedNpubs: _stagedNpubs,
                    // No circle exists yet, so nobody can already be in it.
                    circleMemberPubkeysHex: const {},
                    circleMemberNpubs: const {},
                    onSelected: _onCandidateSelected,
                    onStrangerSelected: _onMemberAdded,
                  ),
                  if (showGuidance)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _buildEmptyState(),
                    ),
                  // Unreserved-height chrome, so it trails the scrolling body
                  // rather than growing the pinned area under it.
                  if (_errorMessage != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: HavenSpacing.base),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: HavenSpacing.base),

            FilledButton(
              key: WidgetKeys.createCircleContinue,
              onPressed: _canContinue ? _onContinue : null,
              child: Text(l10n.commonContinue),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether [npub] can be staged, answered entirely from what is already on
  /// this device.
  ///
  /// This screen previously read no identity at all: a user could stage their
  /// own npub, `_validateMember` would find their own KeyPackage, mark it
  /// valid, and carry it into circle creation (plan §9.5).
  MemberPickState _entryStateFor(String npub) {
    return resolveEntryPickState(
      npub,
      stagedNpubs: _stagedNpubs,
      // No circle exists yet, so nobody can already be in it.
      circleMemberNpubs: const {},
      selfNpub: ref.read(identityProvider).valueOrNull?.npub,
    );
  }

  void _onCandidateSelected(MemberCandidate candidate) =>
      _onMemberAdded(candidate.npub);

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);

    return HavenEmptyState(
      density: HavenEmptyStateDensity.compact,
      icon: LucideIcons.userPlus,
      title: l10n.createCircleEmptyTitle,
      message: l10n.createCircleEmptyMessage,
    );
  }

  Widget _buildMemberTile(BuildContext context, int index) {
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
      _stagedNpubs.add(npub);
      _memberStatus[npub] = ValidationStatus.validating;
      _errorMessage = null;
    });

    // Fetch KeyPackage from relays to validate member
    _validateMember(npub);
  }

  void _onMemberRemoved(String npub) {
    setState(() {
      _selectedMembers.remove(npub);
      _stagedNpubs.remove(npub);
      _memberStatus.remove(npub);
      _memberKeyPackages.remove(npub);
      _memberErrors.remove(npub);
      _networkFailures.remove(npub);
    });
  }

  void _clearAll() {
    setState(() {
      _selectedMembers.clear();
      _stagedNpubs.clear();
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
      final l10n = AppLocalizations.of(context);
      setState(() {
        if (keyPackage == null) {
          _memberStatus[npub] = ValidationStatus.invalid;
          _memberErrors[npub] = l10n.createCircleNoAccountFound;
        } else if (isLegacyKeyPackageJson(keyPackage.eventJson)) {
          // Dark Matter migration (DM-4c, plan §6 F11): a legacy (kind 443)
          // KeyPackage means this person is still on a pre-migration Haven
          // build and cannot be invited into a circle on the new engine
          // until they update.
          _memberStatus[npub] = ValidationStatus.needsUpdate;
          _memberErrors[npub] = l10n.pendingMemberNeedsUpdate;
        } else {
          _memberStatus[npub] = ValidationStatus.valid;
          _memberKeyPackages[npub] = keyPackage;
          _networkFailures.remove(npub);
        }
      });
    } on RelayServiceException catch (e) {
      debugPrint(
        'Relay error fetching KeyPackage for member: ${e.runtimeType}',
      );
      if (!mounted || !_selectedMembers.contains(npub)) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _memberStatus[npub] = ValidationStatus.invalid;
        _memberErrors[npub] = l10n.createCircleCouldNotVerify;
        _networkFailures.add(npub);
      });
    } on Object catch (e) {
      debugPrint('Unexpected error fetching KeyPackage: ${e.runtimeType}');
      if (!mounted || !_selectedMembers.contains(npub)) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _memberStatus[npub] = ValidationStatus.invalid;
        _memberErrors[npub] = l10n.createCircleSomethingWentWrong;
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
      final l10n = AppLocalizations.of(context);
      final npub = NpubValidator.extract(result);
      if (npub == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.createCircleNoIdInQr)),
        );
        return;
      }
      // A scanned code is an entry, so it answers to the same refusals as a
      // typed one: scanning your own QR code must not stage you either.
      final refusal = memberPickRefusalMessage(l10n, _entryStateFor(npub));
      if (refusal != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(refusal)));
        return;
      }
      _onMemberAdded(npub);
    }
  }

  Future<void> _onContinue() async {
    // Collect KeyPackages for all valid members
    final keyPackages = _selectedMembers
        .where(_memberKeyPackages.containsKey)
        .map((npub) => _memberKeyPackages[npub]!)
        .toList();

    if (keyPackages.isEmpty) {
      final l10n = AppLocalizations.of(context);
      setState(() => _errorMessage = l10n.createCircleNoValidMembers);
      return;
    }

    // Navigate to naming page
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => NameCirclePage(
          memberKeyPackages: keyPackages,
          initialName: widget.initialName,
        ),
      ),
    );
  }
}
