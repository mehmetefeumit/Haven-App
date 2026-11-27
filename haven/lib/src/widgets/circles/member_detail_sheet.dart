/// Member detail bottom sheet — nickname editing, the member's photo full
/// screen, and copy-npub (plan §6.3 F10).
///
/// Chosen over consolidating these actions into a `PopupMenuButton` on
/// [CircleMemberTile]: that tile carries a hand-built, 1,799-line semantics
/// test suite covering its tap/long-press tree, and a menu rework would put
/// all of it at risk for a purely additive feature. This sheet is opened
/// separately (from a tap on the tile's avatar) and gets its own
/// from-scratch semantics — the tile's existing tap-to-center /
/// long-press-to-copy gestures are untouched.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/constants/text_input_privacy.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/common/circular_save_button.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/avatar_fullscreen_viewer.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the member detail bottom sheet for [member].
///
/// Determines self-ness from the currently loaded identity so the sheet can
/// hide the nickname editor for the viewer's own row (self has no local
/// Contact-table petname concept — it keeps its dedicated
/// `resolveMemberDisplayName` path, D6 / Flutter review F3).
Future<void> showMemberDetailSheet(
  BuildContext context,
  WidgetRef ref,
  CircleMember member,
) {
  final selfPubkey = ref.read(identityProvider).valueOrNull?.pubkeyHex;
  final isSelf = isSelfMember(member, currentUserPubkey: selfPubkey);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HavenSpacing.base),
      ),
    ),
    // The sheet is in the navigator's overlay, outside any Scaffold that
    // would lift it above the keyboard.
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: MemberDetailSheet(member: member, isSelf: isSelf),
    ),
  );
}

/// Bottom sheet showing a circle member's identity, with nickname editing
/// (non-self only) and a copy-public-key action.
class MemberDetailSheet extends ConsumerStatefulWidget {
  /// Creates a [MemberDetailSheet].
  const MemberDetailSheet({
    required this.member,
    required this.isSelf,
    super.key,
  });

  /// The member this sheet describes.
  final CircleMember member;

  /// Whether [member] is the viewer's own row — hides the nickname editor
  /// when `true` (D6).
  final bool isSelf;

  @override
  ConsumerState<MemberDetailSheet> createState() => _MemberDetailSheetState();
}

class _MemberDetailSheetState extends ConsumerState<MemberDetailSheet> {
  /// The nickname as last persisted, trimmed; empty when there is none. The
  /// title and the save button key off this, not the snapshot in
  /// `widget.member`, so a save shows at once.
  late String _savedNickname = widget.member.displayName?.trim() ?? '';
  late final _nicknameController = TextEditingController(text: _savedNickname)
    ..addListener(_onNicknameChanged);
  final _nicknameFocus = FocusNode();
  SaveStatus _status = SaveStatus.saved;

  @override
  void dispose() {
    _nicknameController
      ..removeListener(_onNicknameChanged)
      ..dispose();
    _nicknameFocus.dispose();
    super.dispose();
  }

  String get _shortNpub => NpubValidator.shortenForDisplay(widget.member.npub);

  bool get _isDirty => _nicknameController.text.trim() != _savedNickname;

  VoidCallback? get _save => (_isDirty && _status != SaveStatus.saving)
      ? () => _setNickname(_nicknameController.text.trim())
      : null;

  void _onNicknameChanged() {
    // Rebuild either way: the clear icon follows the text. A keystroke during
    // an in-flight save leaves the status to that save's outcome.
    setState(() {
      if (_status == SaveStatus.saving) return;
      _status = _isDirty ? SaveStatus.unsaved : SaveStatus.saved;
    });
  }

  Future<void> _copyNpub() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await HapticFeedback.mediumImpact();
    await Clipboard.setData(ClipboardData(text: widget.member.npub));
    if (!mounted) return;
    final view = View.of(context);
    final textDirection = Directionality.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.circleMemberPublicKeyCopied),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await SemanticsService.sendAnnouncement(
      view,
      l10n.circleMemberPublicKeyCopied,
      textDirection,
    );
  }

  /// Empties the field only: clearing "Mom" to type "Mum" must not delete
  /// the saved nickname — saving the empty field does. The field takes focus:
  /// the next keystroke lands in it, and a screen reader on the clear button,
  /// which the emptied field no longer shows, has the focused field to move
  /// to rather than nothing.
  void _clearNickname() {
    _nicknameController.clear();
    _nicknameFocus.requestFocus();
  }

  Future<void> _setNickname(String nickname) async {
    final l10n = AppLocalizations.of(context);
    final view = View.of(context);
    final textDirection = Directionality.of(context);
    // The member list must refresh even if the sheet is dismissed mid-save,
    // when `ref` is no longer usable.
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _status = SaveStatus.saving);
    try {
      await ref
          .read(circleServiceProvider)
          .setContactDisplayName(
            pubkey: widget.member.pubkey,
            displayName: nickname.isEmpty ? null : nickname,
          );
    } on Object catch (e) {
      debugPrint(
        '[MemberDetail] setContactDisplayName failed: ${e.runtimeType}',
      );
      if (!mounted) return;
      // Assertive so the failure interrupts speech and is not missed.
      unawaited(
        SemanticsService.sendAnnouncement(
          view,
          l10n.memberNicknameSheetSaveFailedAnnouncement,
          textDirection,
          assertiveness: Assertiveness.assertive,
        ),
      );
      setState(() => _status = SaveStatus.failed);
      return;
    }
    container.invalidate(circlesProvider);
    if (!mounted) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        nickname.isEmpty
            ? l10n.memberNicknameSheetClearedAnnouncement
            : l10n.memberNicknameSheetSavedAnnouncement,
        textDirection,
      ),
    );
    setState(() {
      _savedNickname = nickname;
      // Text typed while the save was in flight still needs saving.
      _status = _nicknameController.text.trim() == nickname
          ? SaveStatus.saved
          : SaveStatus.unsaved;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final member = widget.member;

    final String effectiveName;
    // Tracks, like `CircleMemberTile._MemberAvatar`'s `hasRealName`, whether
    // a real name was resolved (`true`) vs. `effectiveName` falling back to
    // the npub itself (`false`) — drives the forced-LTR/mono title styling
    // below so the sheet's title mirrors the tile exactly (#3).
    final bool hasRealName;
    if (widget.isSelf) {
      final currentUserPubkey = ref
          .watch(identityProvider)
          .valueOrNull
          ?.pubkeyHex;
      final currentUserDisplayName = ref
          .watch(displayNameProvider)
          .valueOrNull;
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: currentUserPubkey,
        currentUserDisplayName: currentUserDisplayName,
      );
      hasRealName = resolved != null;
      effectiveName = resolved ?? _shortNpub;
    } else {
      final profile = publicProfilesEnabled
          ? ref.watch(memberProfileProvider(member.pubkey)).valueOrNull
          : null;
      final resolved = resolveEffectiveMemberName(
        localOverride: _savedNickname.isEmpty ? null : _savedNickname,
        profile: profile,
        npubFallback: _shortNpub,
      );
      hasRealName = resolved != _shortNpub;
      effectiveName = resolved;
    }

    Uint8List? pictureBytes;
    if (publicProfilesEnabled) {
      pictureBytes = widget.isSelf
          ? ref.watch(ownProfileProvider).valueOrNull?.pictureBytes
          : ref
                .watch(memberProfileProvider(member.pubkey))
                .valueOrNull
                ?.pictureBytes;
    }

    return SafeArea(
      // Scrolls when the keyboard and a large text scale leave too little
      // room; the focused field is scrolled into view.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          HavenSpacing.base,
          HavenSpacing.sm,
          HavenSpacing.base,
          HavenSpacing.base,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.only(bottom: HavenSpacing.base),
                decoration: BoxDecoration(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              l10n.memberDetailSheetTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: HavenSpacing.base),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _MemberPhoto(
                imageBytes: pictureBytes,
                initials: effectiveName.isNotEmpty
                    ? effectiveName.characters.first.toUpperCase()
                    : null,
                publicKey: member.pubkey,
                // The own photo shown is already the full-size one.
                loadFullSize: widget.isSelf
                    ? null
                    : () => ref
                          .read(profileServiceProvider)
                          .getMemberPicture(member.pubkey),
              ),
              title: Text(
                effectiveName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: hasRealName ? null : TextDirection.ltr,
                style: hasRealName
                    ? null
                    : HavenTypography.mono.copyWith(fontSize: 14),
              ),
              subtitle: Text(
                _shortNpub,
                textDirection: TextDirection.ltr,
                style: HavenTypography.monoSmall.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Divider(),
            if (!widget.isSelf) ...[
              const SizedBox(height: HavenSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: WidgetKeys.memberNicknameField,
                      controller: _nicknameController,
                      focusNode: _nicknameFocus,
                      maxLength: 64,
                      // A petname is a contact name kept only on this device;
                      // the keyboard learned-word dictionary is outside
                      // Haven's encrypted storage and its logout wipe.
                      enableIMEPersonalizedLearning: false,
                      autofillHints: kNoAutofill,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _save?.call(),
                      buildCounter:
                          (
                            _, {
                            required int currentLength,
                            required bool isFocused,
                            required int? maxLength,
                          }) => null,
                      decoration: InputDecoration(
                        labelText: l10n.memberNicknameSheetLabel,
                        hintText: l10n.memberNicknameSheetHint,
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: _nicknameController.text.isEmpty
                            ? null
                            : IconButton(
                                key: WidgetKeys.memberNicknameClear,
                                icon: const Icon(LucideIcons.x, size: 20),
                                tooltip: l10n.memberNicknameSheetClear,
                                onPressed: _clearNickname,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  CircularSaveButton(
                    buttonKey: WidgetKeys.memberNicknameSave,
                    status: _status,
                    onPressed: _save,
                    savedLabel: _savedNickname.isEmpty
                        ? l10n.memberNicknameSheetNoneLabel
                        : l10n.memberNicknameSheetSavedLabel,
                    saveLabel: l10n.memberNicknameSheetSave,
                    savingLabel: l10n.memberNicknameSheetSavingLabel,
                    retryLabel: l10n.memberNicknameSheetRetryLabel,
                  ),
                ],
              ),
              const SizedBox(height: HavenSpacing.base),
            ],
            ListTile(
              key: WidgetKeys.memberDetailCopyPublicKey,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(LucideIcons.copy),
              title: Text(l10n.circleMemberCopyPublicKeyMenuItem),
              onTap: _copyNpub,
            ),
          ],
        ),
      ),
    );
  }
}

/// The member's avatar; a button that opens the photo full screen when there
/// is one. Without a photo there is nothing to view, so the initials circle
/// stays a plain image rather than a dead tap target.
class _MemberPhoto extends StatelessWidget {
  const _MemberPhoto({
    required this.imageBytes,
    required this.initials,
    required this.publicKey,
    required this.loadFullSize,
  });

  final Uint8List? imageBytes;
  final String? initials;
  final String publicKey;

  /// Reads a sharper copy than [imageBytes] for the full-screen view, or
  /// `null` when [imageBytes] is already full size.
  final Future<Uint8List?> Function()? loadFullSize;

  @override
  Widget build(BuildContext context) {
    final avatar = HavenAvatar(
      imageBytes: imageBytes,
      initials: initials,
      publicKey: publicKey,
    );
    final bytes = imageBytes;
    if (bytes == null || bytes.isEmpty) return avatar;
    // The medium avatar is 48dp, so the photo is itself the full tap target.
    return InkWell(
      key: WidgetKeys.memberDetailPhoto,
      customBorder: const CircleBorder(),
      // The viewer opens on the tap with the thumbnail in hand rather than
      // waiting on the store; the full-size copy replaces it when read.
      onTap: () =>
          showAvatarFullscreen(context, bytes, fullSize: loadFullSize?.call()),
      // Replaces the avatar's own "Avatar for B" label, which the title
      // beside it already says.
      child: Semantics(
        button: true,
        label: AppLocalizations.of(context).photoHeaderViewPhotoSemantics,
        excludeSemantics: true,
        child: avatar,
      ),
    );
  }
}
