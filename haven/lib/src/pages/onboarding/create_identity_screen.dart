/// Identity-creation screen — the second and final onboarding step.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/anonymous_name_generator.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Final onboarding screen: creates the Nostr identity and captures a display
/// name in one action, then enters the map.
///
/// The display-name field is pre-filled with a random anonymous
/// "Adjective Archetype" name (see [generateAnonymousName]) so a user can stay
/// pseudonymous by default and rename later. Tapping "Create My Identity" runs
/// the whole first-run sequence in order:
///
/// 1. Create the keypair — **only if one does not already exist**. A user who
///    created an identity on a prior, interrupted attempt (crash before
///    onboarding completed, or a mid-old-flow app upgrade) resumes here; the
///    [IdentityService.hasIdentity] check skips re-creation so an existing key
///    is never overwritten. (The Rust core also fails closed on a duplicate
///    create, as a backstop.)
/// 2. Fire-and-forget the KeyPackage publish (kind 30443/443 + relay lists).
/// 3. Save the display name locally.
/// 4. Publish the display name as the user's public kind-0 profile
///    (public-by-default, unconditional — owner-directed, matching White Noise;
///    disclosed by [PublicProfileNotice] above the field).
/// 5. Seed default relays.
/// 6. Run the background-location prominent disclosure → permission → enable
///    sequence (the sole Google Play "disclose before collection" point).
/// 7. Mark onboarding complete; `AppRouter` swaps in the map shell.
///
/// There is no "Skip": the name (pre-filled or edited) is always published. A
/// photo picker is intentionally absent (a separate known issue).
class CreateIdentityScreen extends ConsumerStatefulWidget {
  /// Creates an identity-creation screen.
  const CreateIdentityScreen({super.key});

  @override
  ConsumerState<CreateIdentityScreen> createState() =>
      _CreateIdentityScreenState();
}

class _CreateIdentityScreenState extends ConsumerState<CreateIdentityScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _busy = false;
  bool _userEdited = false;
  bool _selectedOnFirstFocus = false;
  Future<void>? _restoreFuture;

  @override
  void initState() {
    super.initState();
    // Pre-fill synchronously for the common fresh-install case so the field is
    // never briefly empty.
    _controller.text = generateAnonymousName();
    _focusNode.addListener(_selectAllOnFirstFocus);
    // On a resume where a name was already chosen on a prior attempt, prefer
    // that over a fresh random one — but never clobber an in-progress edit.
    // Tracked so `_finish` can await it before resolving the name (a very fast
    // tap must not publish a fresh random name over the restored one).
    _restoreFuture = _restoreExistingName();
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_selectAllOnFirstFocus)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _restoreExistingName() async {
    final existing = await ref.read(identityServiceProvider).getDisplayName();
    if (!mounted || _userEdited) return;
    if (existing != null && existing.trim().isNotEmpty) {
      _controller.text = existing.trim();
    }
  }

  /// Selects the whole field the first time it gains focus, so the user can
  /// immediately type over the pre-filled name instead of clearing it by hand.
  void _selectAllOnFirstFocus() {
    if (!_focusNode.hasFocus || _selectedOnFirstFocus) return;
    _selectedOnFirstFocus = true;
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Capture context-derived objects BEFORE any await so we never touch
    // `context` across an async gap.
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // (1) Create the keypair — only when none exists (idempotent resume).
    final hasIdentity = await ref.read(identityServiceProvider).hasIdentity();
    if (!mounted) return;
    if (!hasIdentity) {
      await ref.read(identityNotifierProvider.notifier).createIdentity();
      if (!mounted) return;
      // createIdentity() never rethrows (AsyncValue.guard) — inspect the
      // notifier's error state instead of wrapping it in a try/catch.
      if (ref.read(identityNotifierProvider).hasError) {
        setState(() => _busy = false);
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.onboardingCreateIdentityError),
            backgroundColor: HavenSecurityColors.danger,
          ),
        );
        return;
      }
    }

    // (2) Fire-and-forget the KeyPackage publish (kind 30443/443 + kind-10051
    // KeyPackage-relay list + kind-10050 inbox list). Idempotent: re-firing on
    // a resume rotates the KeyPackage rather than duplicating it.
    ref
      ..invalidate(keyPackagePublisherProvider)
      ..read(keyPackagePublisherProvider);

    // Make sure the existing-name restore has finished before reading the
    // field, so a very fast tap on a resume can't publish a fresh random name
    // over the user's previously-saved one.
    await _restoreFuture;
    if (!mounted) return;

    // Resolve the name: an explicit edit wins; else keep any name already saved
    // on a prior attempt; else fall back to a freshly generated one. Never
    // publish an empty name.
    final name = await _resolveName();
    if (!mounted) return;

    // (3)(4) Persist locally and publish the public kind-0 profile. Publishing
    // is unconditional (public-by-default, owner-directed). The publish itself
    // is fire-and-forget so a slow/unreachable relay can never stall entry into
    // the app; failures are stored in the controller's own state.
    try {
      await ref.read(identityServiceProvider).setDisplayName(name);
      if (!mounted) return;
      ref.invalidate(displayNameProvider);
      unawaited(
        ref
            .read(ownProfileControllerProvider.notifier)
            .saveDisplayName(displayName: name),
      );
    } on IdentityServiceException {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.onboardingDisplayNameError),
          backgroundColor: HavenSecurityColors.danger,
        ),
      );
      return;
    }

    // (5) Seed default relays before completing so the first publish has a
    // populated list. Best-effort — the provider self-heals on read.
    try {
      final relayPrefs = await ref.read(relayPreferencesServiceProvider.future);
      await relayPrefs.seedDefaultsIfUnseeded();
    } on Object catch (e) {
      debugPrint('Seed defaults during onboarding failed: ${e.runtimeType}');
    }

    // (6) First-run location setup: prominent disclosure → permission →
    // background sharing. Declining is fine — the user still enters the app.
    if (mounted) await _setUpLocationSharing();

    if (!mounted) return;
    // (7) Complete onboarding — AppRouter swaps in the main shell.
    await ref.read(onboardingControllerProvider.notifier).markCompleted();
  }

  /// Resolves the display name to save + publish.
  ///
  /// Priority: the current (possibly edited) field text → any name saved on a
  /// prior attempt → a freshly generated anonymous name. Guarantees a non-empty
  /// result so publishing is never skipped.
  Future<String> _resolveName() async {
    final typed = _controller.text.trim();
    if (typed.isNotEmpty) return typed;
    final existing = await ref.read(identityServiceProvider).getDisplayName();
    final trimmed = existing?.trim() ?? '';
    return trimmed.isNotEmpty ? trimmed : generateAnonymousName();
  }

  /// Runs the first-run location consent, permission, and background-sharing
  /// flow. Ported verbatim from the former ready screen.
  ///
  /// Gated behind the shared prominent-disclosure dialog (Google Play
  /// "disclosure before collection"). Each OS request is best-effort: a denial
  /// is swallowed so it can never block the user from entering the app.
  Future<void> _setUpLocationSharing() async {
    final disclosed = await ref
        .read(locationDisclosureControllerProvider.notifier)
        .ensureDisclosed(context, includeBackground: true);
    if (!disclosed) return;

    try {
      await ref.read(locationServiceProvider).requestPermission();
    } on Object catch (e) {
      debugPrint('Onboarding location permission failed: ${e.runtimeType}');
    }

    try {
      await ref
          .read(backgroundSharingProvider.notifier)
          .setEnabled(enabled: true);
    } on Object catch (e) {
      debugPrint('Onboarding background setup failed: ${e.runtimeType}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return OnboardingScaffold(
      stepNumber: kOnboardingStepCreateIdentity,
      totalSteps: kOnboardingTotalSteps,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.onboardingCreateIdentityTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.base),
          Text(
            l10n.onboardingCreateIdentityBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.base),
          _WarningCard(message: l10n.onboardingCreateIdentityWarning),
          const SizedBox(height: HavenSpacing.base),
          const PublicProfileNotice(),
          const SizedBox(height: HavenSpacing.base),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onChanged: (_) => _userEdited = true,
            // The consequential action requires an explicit CTA tap — the
            // keyboard "done" key only dismisses the keyboard.
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
            inputFormatters: [
              LengthLimitingTextInputFormatter(64),
              FilteringTextInputFormatter.singleLineFormatter,
            ],
            decoration: InputDecoration(
              // Reuse the Identity page's "Display Name" label so onboarding
              // adds no new localized copy (it exists in every locale already).
              labelText: l10n.displayNameCardTitle,
              hintText: l10n.onboardingDisplayNameHint,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.createIdentityCta,
        onPressed: _busy ? null : _finish,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: _busy
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  Text(l10n.onboardingCreateIdentityLoading),
                ],
              )
            : Text(l10n.onboardingCreateIdentityCta),
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(HavenSpacing.base),
      decoration: BoxDecoration(
        color: HavenSecurityColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(HavenSpacing.sm),
        border: Border.all(
          color: HavenSecurityColors.warning.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            LucideIcons.triangleAlert,
            color: HavenSecurityColors.warning,
          ),
          const SizedBox(width: HavenSpacing.sm),
          Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
