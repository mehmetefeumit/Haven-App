/// Add member page — lets a circle admin invite new members to an
/// already-created circle.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/qr_scanner_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/member_directory_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
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

/// Page that lets a circle admin add new members to an existing circle.
///
/// Shares its shape with the create-circle step: a [MemberSearchField], the
/// [MemberPickerResults] list of people already known from other circles,
/// and the [PendingMemberTile] staging list — combined with confirmation on
/// a single screen, because the circle already exists and there is no
/// naming step to follow.
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

  /// [_selectedMembers], mirrored as a [Set] so the picker's O(1) staged-npub
  /// lookup never rebuilds a fresh `Set` from the list on every keystroke —
  /// kept in sync wherever [_selectedMembers] is mutated.
  final Set<String> _stagedNpubs = {};

  /// This circle's member pubkeys, LOWER-CASED once: [resolveMemberPickState]
  /// requires its `circleMemberPubkeysHex` already normalised, so folding
  /// happens here — once, when the roster is known — rather than per
  /// rendered row per keystroke. `widget.circle` does not change for the
  /// life of this page, so this needs computing only once.
  late final Set<String> _circleMemberPubkeysHexLower = {
    for (final member in widget.circle.members) member.pubkey.toLowerCase(),
  };

  /// This circle's member npubs, computed once for the same reason as
  /// [_circleMemberPubkeysHexLower].
  late final Set<String> _circleMemberNpubs = {
    for (final member in widget.circle.members) member.npub,
  };

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

  /// What is currently typed in the search field, held here because the list
  /// beside the field is derived from it. The field itself still owns the
  /// text that renders the caret.
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    // Someone who shares no circles yet has nobody to pick, so the guidance
    // is still the right content; someone who does gets rows instead of a
    // placeholder telling them to type. Loading counts as neither.
    final directory = ref.watch(memberDirectoryProvider);
    final directoryIsEmpty = directory.valueOrNull?.entries.isEmpty ?? false;
    final showGuidance = _selectedMembers.isEmpty && directoryIsEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addMemberTitle(widget.circle.displayName)),
      ),
      body: Padding(
        // Keep the bottom CTA clear of the gesture/home indicator without
        // reflowing the whole body. `paddingOf`, NOT `viewPaddingOf`: the
        // engine collapses `padding` to zero while the keyboard covers the
        // home indicator, whereas `viewPadding` deliberately does not — so
        // reading the latter reserves 34px of dead space below the keyboard
        // line, in exactly the squeezed case this layout exists to survive.
        padding: EdgeInsets.fromLTRB(
          HavenSpacing.base,
          HavenSpacing.base,
          HavenSpacing.base,
          HavenSpacing.base + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ONE viewport for everything except the CTA. Pinning the search
            // field, the roster header and the disclosure above a pinned
            // button made the fixed chrome taller than the body at a 2x text
            // scale — the page could not lay out at all, and clipped chrome
            // discloses nothing and cannot be tapped. Only the primary action
            // stays put; the rest scrolls when it has to.
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
                    circleMemberPubkeysHex: _circleMemberPubkeysHexLower,
                    circleMemberNpubs: _circleMemberNpubs,
                    onSelected: _onCandidateSelected,
                    onStrangerSelected: _onMemberAdded,
                  ),
                  if (showGuidance)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Column(
                        // Without this the note shrink-wraps to its longest
                        // wrapped line while the populated branch renders it
                        // edge to edge, so the box would change width the
                        // moment a member is added.
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _buildEmptyState()),
                          _buildSharingNote(),
                        ],
                      ),
                    )
                  else
                    SliverToBoxAdapter(child: _buildSharingNote()),
                ],
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
                        Text(_sendButtonLabel(l10n, inProgress: true)),
                      ],
                    )
                  : Text(_sendButtonLabel(l10n, inProgress: false)),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether [npub] can be staged, answered entirely from what is already on
  /// this device — so it holds with no network, unlike the KeyPackage-derived
  /// check in [_validateMember] below.
  MemberPickState _entryStateFor(String npub) {
    return resolveEntryPickState(
      npub,
      stagedNpubs: _stagedNpubs,
      circleMemberNpubs: _circleMemberNpubs,
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

  /// What adding a member means — kept as a neutral, plain-language note (not
  /// a green security badge) per the app's color doctrine.
  Widget _buildSharingNote() {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: HavenSpacing.base),
      child: Container(
        padding: const EdgeInsets.all(HavenSpacing.base),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          AppLocalizations.of(context).addMemberInfo,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  bool get _canAdd {
    if (_selectedMembers.isEmpty) return false;
    return _selectedMembers.every(
      (npub) => _memberStatus[npub] == ValidationStatus.valid,
    );
  }

  /// Label for the send button, pluralized by the number of selected members.
  String _sendButtonLabel(AppLocalizations l10n, {required bool inProgress}) {
    final count = _selectedMembers.length;
    if (inProgress) {
      return l10n.addMemberSendingInvitation(count);
    }
    return l10n.addMemberSendInvitation(count);
  }

  void _onMemberAdded(String npub) {
    setState(() {
      _selectedMembers.add(npub);
      _stagedNpubs.add(npub);
      _memberStatus[npub] = ValidationStatus.validating;
    });
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

      if (keyPackage == null) {
        setState(() {
          _memberStatus[npub] = ValidationStatus.invalid;
          _memberErrors[npub] = l10n.createCircleNoAccountFound;
        });
        return;
      }

      // Dark Matter migration (DM-4c, plan §6 F11): a legacy (kind 443)
      // KeyPackage means this person is still on a pre-migration Haven
      // build and cannot be invited into a circle on the new engine until
      // they update. Check this BEFORE the already-in-circle exclusion —
      // a stale-protocol peer is blocked regardless of membership overlap.
      if (isLegacyKeyPackageJson(keyPackage.eventJson)) {
        if (mounted && _selectedMembers.contains(npub)) {
          setState(() {
            _memberStatus[npub] = ValidationStatus.needsUpdate;
            _memberErrors[npub] = l10n.pendingMemberNeedsUpdate;
          });
        }
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
              _memberErrors[npub] = l10n.addMemberAlreadyInCircle;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.createCircleNoIdInQr)));
        return;
      }
      // A scanned code is an entry, so it answers to the same three refusals
      // as a typed one: scanning your own QR code must not stage you either.
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

  Future<void> _onAddMembers() async {
    final keyPackages = _selectedMembers
        .where(_memberKeyPackages.containsKey)
        .map((npub) => _memberKeyPackages[npub]!)
        .toList();

    if (keyPackages.isEmpty) return;

    final l10n = AppLocalizations.of(context);

    setState(() => _isAdding = true);

    try {
      // Two-plane model: the adder's tier-3 Welcome-delivery fallback is
      // their OWN inbox relays (kind 10050), read locally. Best-effort — a
      // failure here must not block the add. If this and the invitee's own
      // relays are all empty, the Rust layer FAILS CLOSED
      // (no public-default fallback) rather than leaking the recipient's
      // pubkey to public relays.
      final creatorFallbackRelays = await _fetchCreatorFallbackRelays(ref);

      // The identity secret is fetched FRESH inside addMember for each staging
      // attempt and scrubbed immediately after (Rule 9), so pass the notifier's
      // fetcher rather than holding raw bytes across the converge loop. The
      // notifier is a non-autoDispose singleton, so the tear-off stays valid.
      final identityNotifier = ref.read(identityNotifierProvider.notifier);
      final result = await ref
          .read(circleServiceProvider)
          .addMember(
            secretProvider: identityNotifier.getSecretBytes,
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
      final message = result.welcomesSent == result.welcomesTotal
          ? l10n.addMemberSentToCircle(result.welcomesTotal, circleName)
          : l10n.addMemberPartialDelivery(
              result.welcomesSent,
              result.welcomesTotal,
            );

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

      Navigator.of(context).pop();
    } on IdentityServiceException catch (_) {
      debugPrint('[AddMember] Identity error');
      if (!mounted) return;
      setState(() => _isAdding = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.addMemberError)));
    } on CircleServiceException catch (_) {
      debugPrint('[AddMember] Service error');
      if (!mounted) return;
      setState(() => _isAdding = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.addMemberError)));
    } on Object catch (_) {
      debugPrint('[AddMember] Unexpected error');
      if (!mounted) return;
      setState(() => _isAdding = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.addMemberError)));
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
