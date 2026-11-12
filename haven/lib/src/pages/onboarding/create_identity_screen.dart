/// Identity-creation screen — the second and final onboarding step.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/text_input_privacy.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/anonymous_name_generator.dart';
import 'package:haven/src/utils/profile_sync_trigger.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/avatar_initials.dart';
import 'package:haven/src/widgets/identity/avatar_picker.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Final onboarding screen: creates the Nostr identity and captures a display
/// name in one action, then enters the map once others can invite the user.
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
/// 2. Seed default relays — before anything is published, since an unseeded
///    relay list reads as empty and a publish to it does nothing.
/// 3. Start the reachability publish: relay lists (kind 10002, then 10050),
///    then the KeyPackage (kind 30443).
/// 4. Save the display name locally (a fast SQLCipher write; no relay yet).
/// 5. Save the optional photo, if one was chosen, LOCALLY too — chained
///    *after* the name save so the local merge always carries the name —
///    then trigger the background publish of the public kind-0 profile
///    (public-by-default, unconditional — owner-directed, matching White
///    Noise; disclosed by [PublicProfileNotice] above the field). Name and
///    photo publish together in ONE kind-0 event once the trigger's sync
///    pass runs.
/// 6. "Finishing setup…": wait, up to [finishSetupTimeout], until the
///    reachability publish proves others can invite the user
///    ([OwnReachability.ready]). On a timeout or a proven failure the screen
///    shows a fixed error with Retry, which publishes again without creating
///    anything again; there is no way past it. Owner decision OD-C
///    (2026-11-12), matching White Noise: for this step it replaces the rule
///    that a slow relay never stalls entry, because a user who enters before
///    this is shown a QR code nobody can invite.
/// 7. Run the background-location prominent disclosure → permission → enable
///    sequence (the sole Google Play "disclose before collection" point).
/// 8. Mark onboarding complete; `AppRouter` swaps in the map shell.
///
/// There is no "Skip": the name (pre-filled or edited) is always saved and
/// published. Adding a profile photo is optional — an avatar circle above
/// the field opens the same gallery picker + square crop editor as the
/// Identity settings page ([pickAndCropAvatar]). A chosen photo is held
/// locally and, once the identity exists, saved and queued for publish
/// *after* the name (never concurrently, so the local merge can't land the
/// two edits out of order).
class CreateIdentityScreen extends ConsumerStatefulWidget {
  /// Creates an identity-creation screen.
  const CreateIdentityScreen({
    super.key,
    this.pickPhoto = pickAndCropAvatar,
    this.finishSetupTimeout = const Duration(seconds: 60),
  });

  /// Gallery pick + crop function, injectable for widget tests that cannot
  /// drive the native photo picker.
  ///
  /// Production leaves this at its default, [pickAndCropAvatar]; tests supply a
  /// fake that returns fixed bytes (or `null` to simulate cancel).
  @visibleForTesting
  final Future<Uint8List?> Function(BuildContext context) pickPhoto;

  /// How long "Finishing setup…" waits for the reachability publish before
  /// offering Retry. Injectable so a test can reach it on a fake clock.
  @visibleForTesting
  final Duration finishSetupTimeout;

  @override
  ConsumerState<CreateIdentityScreen> createState() =>
      _CreateIdentityScreenState();
}

class _CreateIdentityScreenState extends ConsumerState<CreateIdentityScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _busy = false;

  /// Waiting for the reachability publish ("Finishing setup…").
  bool _finishing = false;

  /// The reachability publish timed out or proved a failure: Retry is offered.
  bool _setupFailed = false;

  /// The identity exists and the profile is saved: a Retry only publishes.
  bool _profileSaved = false;
  bool _userEdited = false;
  bool _selectedOnFirstFocus = false;
  Future<void>? _restoreFuture;

  /// The optional profile photo the user picked, held locally until the
  /// identity is created and it can be published (see [_finish]). `null` means
  /// no photo was chosen — the profile is published without one.
  Uint8List? _pickedPhoto;

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

  /// Opens the gallery picker + square crop editor and holds the chosen bytes
  /// locally.
  ///
  /// Nothing is uploaded here: the identity does not exist yet, and both the
  /// Blossom upload and the kind-0 publish require the identity secret key. The
  /// photo is published in [_finish], after the keypair is created. Cancelling
  /// the picker/crop is a silent no-op (bytes stay unchanged).
  Future<void> _onPickPhoto() async {
    final bytes = await widget.pickPhoto(context);
    if (!mounted || bytes == null) return;
    setState(() => _pickedPhoto = bytes);
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _setupFailed = false;
    });
    // Capture context-derived objects BEFORE any await so we never touch
    // `context` across an async gap.
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final reachability = ref.read(ownReachabilityProvider.notifier);

    final Future<void> publish;
    if (_profileSaved) {
      publish = reachability.republish();
    } else {
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

      // (2) Seed default relays BEFORE the publish below: an unseeded list
      // reads as empty, and a publish to it does nothing. Best-effort — the
      // Rust tick seeds an unseeded list itself as a backstop.
      try {
        final relayPrefs = await ref.read(
          relayPreferencesServiceProvider.future,
        );
        await relayPrefs.seedDefaultsIfUnseeded();
      } on Object catch (e) {
        debugPrint('Seed defaults during onboarding failed: ${e.runtimeType}');
      }
      if (!mounted) return;

      // (3) Relay lists (10002, then 10050), then the KeyPackage (30443).
      // Started now so it runs while the profile is saved; awaited in (6).
      publish = reachability.republish();

      // Make sure the existing-name restore has finished before reading the
      // field, so a very fast tap on a resume can't publish a fresh random
      // name over the user's previously-saved one.
      await _restoreFuture;
      if (!mounted) return;

      // Resolve the name: an explicit edit wins; else keep any name already
      // saved on a prior attempt; else fall back to a freshly generated one.
      // Never publish an empty name.
      final name = await _resolveName();
      if (!mounted) return;

      // (4)(5) Persist locally, then trigger the public kind-0 publish.
      // Publishing is unconditional (public-by-default, owner-directed). The
      // kind-0 publish itself is fire-and-forget (`triggerProfileSync`): an
      // invitation does not need it.
      try {
        await ref.read(identityServiceProvider).setDisplayName(name);
        if (!mounted) return;
        ref.invalidate(displayNameProvider);
        // Save the public kind-0 profile LOCALLY: the display name always,
        // and the optional photo only if one was picked, in series (name ->
        // photo) so (a) the two edits can't land out of order in the local
        // merge and (b) the photo is gated on the name save SUCCEEDING — a
        // picture-only kind-0 must never publish without the intended name.
        // Both are fast, local-only SQLCipher writes (no relay/Blossom I/O),
        // so they are awaited directly; a genuine local failure is logged and
        // swallowed so it can never block onboarding completion.
        final photo = _pickedPhoto;
        await _saveOnboardingProfileLocally(
          ref.read(profileServiceProvider),
          name,
          photo,
        );
        if (!mounted) return;
        triggerProfileSync(ref);
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
      _profileSaved = true;
    }

    // (6) Finishing setup: nobody can invite this account until its relay
    // lists and KeyPackage are where an inviter looks.
    setState(() => _finishing = true);
    final ready = await _awaitReachable(publish);
    if (!mounted) return;
    if (!ready) {
      setState(() {
        _busy = false;
        _finishing = false;
        _setupFailed = true;
      });
      return;
    }

    // (7) First-run location setup: prominent disclosure → permission →
    // background sharing. Declining is fine — the user still enters the app.
    await _setUpLocationSharing();

    if (!mounted) return;
    // (8) Complete onboarding — AppRouter swaps in the main shell.
    await ref.read(onboardingControllerProvider.notifier).markCompleted();
  }

  /// Whether [publish] proved others can invite this account within
  /// [CreateIdentityScreen.finishSetupTimeout]. A timeout leaves the publish
  /// running; a Retry supersedes it.
  Future<bool> _awaitReachable(Future<void> publish) async {
    try {
      await publish.timeout(widget.finishSetupTimeout);
    } on TimeoutException {
      debugPrint('[Onboarding] finishing setup timed out');
      return false;
    }
    if (!mounted) return false;
    return ref.read(ownReachabilityProvider).status == OwnReachability.ready;
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
          const PublicProfileNotice(),
          const SizedBox(height: HavenSpacing.base),
          Center(
            child: _AvatarPicker(
              photoBytes: _pickedPhoto,
              nameController: _controller,
              // Once the profile is saved a Retry only publishes, so an edit
              // here would be silently dropped; the Identity page edits it.
              onTap: _busy || _profileSaved ? null : _onPickPhoto,
              onRemove: _pickedPhoto == null || _profileSaved
                  ? null
                  : () => setState(() => _pickedPhoto = null),
            ),
          ),
          const SizedBox(height: HavenSpacing.sm),
          // Same card, padding and dense outlined field as the Identity
          // page's DisplayNameCard, so the two read as one control.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(HavenSpacing.base),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: !_profileSaved,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                // Publishing this name is the user's choice; the keyboard's
                // learned-word dictionary is a different recipient — outside
                // Haven's storage and its logout wipe.
                enableIMEPersonalizedLearning: false,
                autofillHints: kNoAutofill,
                onChanged: (_) => _userEdited = true,
                // The consequential action requires an explicit CTA tap — the
                // keyboard "done" key only dismisses the keyboard.
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                inputFormatters: [
                  LengthLimitingTextInputFormatter(64),
                  FilteringTextInputFormatter.singleLineFormatter,
                ],
                decoration: InputDecoration(
                  labelText: l10n.displayNameCardTitle,
                  hintText: l10n.onboardingDisplayNameHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ),
          if (_setupFailed) ...[
            const SizedBox(height: HavenSpacing.sm),
            Semantics(
              liveRegion: true,
              child: Row(
                key: WidgetKeys.createIdentitySetupError,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    LucideIcons.circleAlert,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  Expanded(
                    child: Text(
                      l10n.onboardingFinishSetupError,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.createIdentityCta,
        onPressed: _busy ? null : _finish,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: _busy
            ? _BusyLabel(
                label: _finishing
                    ? l10n.onboardingFinishingSetup
                    : l10n.onboardingCreateIdentityLoading,
              )
            : Text(
                _setupFailed
                    ? l10n.commonRetry
                    : l10n.onboardingCreateIdentityCta,
              ),
      ),
    );
  }
}

/// The CTA's busy content: a spinner announced as progress with [label], and
/// [label] itself, announced again whenever it changes.
class _BusyLabel extends StatelessWidget {
  const _BusyLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: label,
            ),
          ),
          const SizedBox(width: HavenSpacing.sm),
          ExcludeSemantics(child: Text(label)),
        ],
      ),
    );
  }
}

/// Saves the onboarding public kind-0 profile LOCALLY — display name then,
/// if one was picked, the photo — gated so the photo save only runs if the
/// name save SUCCEEDED.
///
/// Both are now fast, local-only writes (`ProfileService.updateOwnProfile` /
/// `ProfileService.setOwnAvatar` no longer touch a relay or Blossom), so this
/// takes plain values (no `ref`/`context`) purely to stay testable in
/// isolation — unlike before this migration, it no longer needs to survive a
/// possibly-disposed widget, since [triggerProfileSync] (called by the
/// caller once this returns) is what runs in the background. On any local
/// failure the name is still saved by the caller
/// ([IdentityService.setDisplayName]) and republishes on the next profile
/// edit. Errors are logged by runtime type only, never surfaced raw
/// (Security Rule 8).
Future<void> _saveOnboardingProfileLocally(
  ProfileService service,
  String name,
  Uint8List? photo,
) async {
  try {
    await service.updateOwnProfile(displayName: name);
    if (photo != null) {
      await service.setOwnAvatar(photo);
    }
  } on Object catch (e) {
    debugPrint('Onboarding profile local save failed: ${e.runtimeType}');
  }
}

/// Optional profile-photo picker shown above the display-name field.
///
/// Tapping the circle opens the same gallery picker + square crop editor used
/// on the Identity settings page ([pickAndCropAvatar]); the chosen bytes are
/// held by the parent and published after the identity is created. Shows the
/// picked photo when set (with a "Remove" action), otherwise the name's
/// initials behind a camera badge inviting the user to add one.
///
/// The whole 96dp circle is the tap target (well above the 48dp WCAG minimum);
/// the camera badge is decorative ([IgnorePointer]) so it never steals the tap.
/// The caption/Remove row sits in a fixed-height slot so it neither shifts the
/// field below when a photo is chosen nor breaks the page's no-scroll budget.
class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.photoBytes,
    required this.nameController,
    required this.onTap,
    required this.onRemove,
  });

  /// The picked photo bytes, or `null` when none has been chosen.
  final Uint8List? photoBytes;

  /// The display-name controller, watched so the fallback initials preview
  /// tracks the name as it is edited or restored.
  final TextEditingController nameController;

  /// Opens the picker. `null` disables the control (e.g. while submitting).
  final VoidCallback? onTap;

  /// Clears the picked photo. `null` when there is nothing to remove.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final bytes = photoBytes;
    final hasPhoto = bytes != null && bytes.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          enabled: onTap != null,
          label: hasPhoto
              ? l10n.photoHeaderChangePhotoSemantics
              : l10n.photoHeaderAddPhotoSemantics,
          // Announce only the clean button label — exclude HavenAvatar's own
          // "user avatar" semantics (which would otherwise merge into a verbose
          // composite) and re-declare the tap action the exclude would strip
          // (mirrors PublicProfileNotice and the onboarding step indicator).
          excludeSemantics: true,
          onTap: onTap,
          child: SizedBox(
            width: 96,
            height: 96,
            child: Stack(
              children: [
                InkWell(
                  onTap: onTap,
                  customBorder: const CircleBorder(),
                  child: ListenableBuilder(
                    listenable: nameController,
                    builder: (context, _) => HavenAvatar(
                      imageBytes: bytes,
                      initials: avatarInitials(nameController.text),
                      size: HavenAvatarSize.xlarge,
                    ),
                  ),
                ),
                PositionedDirectional(
                  end: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colorScheme.surface,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        LucideIcons.camera,
                        size: 16,
                        color: colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: HavenSpacing.xs),
        // Fixed-height slot: the caption and the (taller) Remove button occupy
        // the same vertical space, so choosing a photo neither nudges the field
        // below nor grows the page past the no-scroll budget.
        SizedBox(
          height: 30,
          child: Center(
            child: hasPhoto
                ? TextButton(
                    onPressed: onRemove,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: HavenSpacing.sm,
                      ),
                    ),
                    child: Text(l10n.photoHeaderRemove),
                  )
                : Text(
                    l10n.onboardingAddPhotoOptional,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
