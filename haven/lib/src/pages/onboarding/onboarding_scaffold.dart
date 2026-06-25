/// Shared layout primitive for onboarding screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Consistent layout for every onboarding screen.
///
/// Provides safe-area padding, an optional step indicator, an optional back
/// button, and a bottom actions area. Accessibility is baked in: the step
/// indicator is announced via [SemanticsService.sendAnnouncement] whenever
/// this widget is re-mounted, and the back button uses a localisable label.
class OnboardingScaffold extends StatefulWidget {
  /// Creates an onboarding scaffold.
  const OnboardingScaffold({
    required this.body,
    required this.primaryAction,
    this.stepNumber,
    this.totalSteps,
    this.showBackButton = false,
    this.onBack,
    this.secondaryAction,
    this.announcement,
    super.key,
  });

  /// The main scrollable content of the screen.
  final Widget body;

  /// The bottom primary call-to-action.
  final Widget primaryAction;

  /// Optional secondary action rendered above [primaryAction].
  final Widget? secondaryAction;

  /// Current step number for the "Step X of Y" indicator.
  ///
  /// If `null`, the indicator is not rendered.
  final int? stepNumber;

  /// Total number of steps for the indicator.
  final int? totalSteps;

  /// When `true`, renders a back button in the top-left corner.
  final bool showBackButton;

  /// Custom back-button handler. If `null` and [showBackButton] is `true`,
  /// falls back to `Navigator.maybePop`.
  final VoidCallback? onBack;

  /// Optional text announced by screen readers when this screen mounts.
  ///
  /// Defaults to the step indicator if [stepNumber] and [totalSteps] are
  /// both set.
  final String? announcement;

  @override
  State<OnboardingScaffold> createState() => _OnboardingScaffoldState();
}

class _OnboardingScaffoldState extends State<OnboardingScaffold> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final announcement = widget.announcement ?? _stepAnnouncement(context);
      if (announcement == null) return;
      SemanticsService.sendAnnouncement(
        View.of(context),
        announcement,
        // Announce in the active locale's direction (RTL for ar/he/fa).
        Directionality.of(context),
      );
    });
  }

  String? _stepAnnouncement(BuildContext context) {
    final current = widget.stepNumber;
    final total = widget.totalSteps;
    if (current == null || total == null) return null;
    return AppLocalizations.of(context).onboardingStepOf(current, total);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(
                showBackButton: widget.showBackButton,
                onBack: widget.onBack,
                stepNumber: widget.stepNumber,
                totalSteps: widget.totalSteps,
                colorScheme: theme.colorScheme,
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      top: HavenSpacing.lg,
                      bottom: HavenSpacing.base,
                    ),
                    child: widget.body,
                  ),
                ),
              ),
              if (widget.secondaryAction != null) ...[
                widget.secondaryAction!,
                const SizedBox(height: HavenSpacing.sm),
              ],
              Padding(
                padding: const EdgeInsets.only(bottom: HavenSpacing.base),
                child: widget.primaryAction,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.showBackButton,
    required this.onBack,
    required this.stepNumber,
    required this.totalSteps,
    required this.colorScheme,
  });

  final bool showBackButton;
  final VoidCallback? onBack;
  final int? stepNumber;
  final int? totalSteps;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final hasIndicator = stepNumber != null && totalSteps != null;

    return SizedBox(
      height: 48,
      child: Row(
        children: [
          if (showBackButton)
            IconButton(
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: AppLocalizations.of(context).commonBack,
              onPressed: onBack ?? () => Navigator.maybePop(context),
            )
          else
            const SizedBox(width: 48),
          Expanded(
            child: hasIndicator
                ? Center(
                    child: _StepIndicator(
                      current: stepNumber!,
                      total: totalSteps!,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({
    required this.current,
    required this.total,
    required this.color,
  });

  final int current;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final stepLabel = AppLocalizations.of(context).onboardingStepOf(
      current,
      total,
    );
    return Semantics(
      label: stepLabel,
      excludeSemantics: true,
      child: Text(
        stepLabel,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    );
  }
}
