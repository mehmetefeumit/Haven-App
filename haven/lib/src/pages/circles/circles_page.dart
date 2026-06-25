/// Circles page for Haven.
///
/// Manages user's circles - groups of trusted contacts for location sharing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page displaying and managing user's circles.
///
/// Shows a list of circles with pending invitations highlighted at the top.
/// Requires identity setup before circle creation is enabled.
class CirclesPage extends ConsumerWidget {
  /// Creates the circles page.
  const CirclesPage({super.key});

  /// Handles the create circle button press.
  void _onCreateCirclePressed(BuildContext context) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (context) => const CreateCirclePage()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final identityAsync = ref.watch(identityProvider);
    final circlesAsync = ref.watch(circlesProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.circlesTitle),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            tooltip: l10n.circlesRefreshTooltip,
            onPressed: () {
              ref.invalidate(circlesProvider);
            },
          ),
        ],
      ),
      body: _buildBody(context, circlesAsync: circlesAsync),
      floatingActionButton: identityAsync.when(
        data: (identity) => FloatingActionButton.extended(
          key: WidgetKeys.circlesCreateCta,
          onPressed: identity != null
              ? () => _onCreateCirclePressed(context)
              : () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.circlesRequiresIdentity),
                    ),
                  );
                },
          icon: const Icon(LucideIcons.plus),
          label: Text(l10n.circlesCreateCta),
        ),
        loading: () => null,
        error: (_, _) => FloatingActionButton.extended(
          key: WidgetKeys.circlesCreateCta,
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.circlesRequiresIdentity),
              ),
            );
          },
          icon: const Icon(LucideIcons.plus),
          label: Text(l10n.circlesCreateCta),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required AsyncValue<List<Circle>> circlesAsync,
  }) {
    final circles = circlesAsync.valueOrNull ?? [];

    if (circles.isEmpty && !circlesAsync.isLoading) {
      return const _CirclesEmptyState();
    }

    if (circlesAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HavenSpacing.base,
            HavenSpacing.sm,
            HavenSpacing.base,
            HavenSpacing.sm,
          ),
          child: Text(
            AppLocalizations.of(context).circlesYourCircles,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final circle in circles) CircleListTile(circle: circle),
      ],
    );
  }
}

class _CirclesEmptyState extends StatelessWidget {
  const _CirclesEmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return HavenEmptyState(
      icon: LucideIcons.users,
      title: l10n.circlesEmptyTitle,
      message: l10n.circlesEmptyMessage,
    );
  }
}
