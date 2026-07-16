/// Member detail bottom sheet — nickname editing + copy-npub (plan §6.3 F10).
///
/// Chosen over consolidating these actions into a `PopupMenuButton` on
/// [CircleMemberTile]: that tile carries a hand-built, 1,799-line semantics
/// test suite covering its tap/long-press tree, and a menu rework would put
/// all of it at risk for a purely additive feature. This sheet is opened
/// separately (from a tap on the tile's avatar) and gets its own
/// from-scratch semantics — the tile's existing tap-to-center /
/// long-press-to-copy gestures are untouched.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/feature_flags.dart';
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
import 'package:haven/src/widgets/identity/avatar.dart';
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
    builder: (_) => MemberDetailSheet(member: member, isSelf: isSelf),
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
  late final _nicknameController = TextEditingController(
    text: widget.member.displayName ?? '',
  );
  bool _saving = false;

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  String get _shortNpub => NpubValidator.truncate(
    widget.member.npub,
    prefixLength: 12,
    suffixLength: 6,
  );

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

  Future<void> _saveNickname() async {
    final text = _nicknameController.text.trim();
    await _setNickname(text.isEmpty ? null : text);
  }

  Future<void> _clearNickname() async {
    _nicknameController.clear();
    await _setNickname(null);
  }

  Future<void> _setNickname(String? nickname) async {
    final l10n = AppLocalizations.of(context);
    final view = View.of(context);
    final textDirection = Directionality.of(context);
    setState(() => _saving = true);
    try {
      await ref
          .read(circleServiceProvider)
          .setContactDisplayName(
            pubkey: widget.member.pubkey,
            displayName: nickname,
          );
      ref.invalidate(circlesProvider);
      if (!mounted) return;
      await SemanticsService.sendAnnouncement(
        view,
        nickname == null
            ? l10n.memberNicknameSheetClearedAnnouncement
            : l10n.memberNicknameSheetSavedAnnouncement,
        textDirection,
      );
    } on Object catch (e) {
      debugPrint(
        '[MemberDetail] setContactDisplayName failed: ${e.runtimeType}',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
        localOverride: member.displayName,
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
      child: Padding(
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
              leading: HavenAvatar(
                imageBytes: pictureBytes,
                initials: effectiveName.isNotEmpty
                    ? effectiveName.characters.first.toUpperCase()
                    : null,
                publicKey: member.pubkey,
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
              TextField(
                key: WidgetKeys.memberNicknameField,
                controller: _nicknameController,
                enabled: !_saving,
                maxLength: 64,
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
                ),
              ),
              const SizedBox(height: HavenSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: WidgetKeys.memberNicknameClear,
                      onPressed: _saving ? null : _clearNickname,
                      child: Text(l10n.memberNicknameSheetClear),
                    ),
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  Expanded(
                    child: FilledButton(
                      key: WidgetKeys.memberNicknameSave,
                      onPressed: _saving ? null : _saveNickname,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.memberNicknameSheetSave),
                    ),
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
