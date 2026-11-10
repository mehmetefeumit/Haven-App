import 'package:flutter/widgets.dart';

/// Whether the user asked the OS to reduce motion.
///
/// Both flags are read because neither platform reports through one: Android's
/// "remove animations" reaches Flutter as [MediaQueryData.disableAnimations],
/// while iOS Reduce Motion arrives only as the engine's
/// `AccessibilityFeatures.reduceMotion`, which [MediaQueryData] does not carry.
///
/// Call it from `build`. A change to the engine flag alone does not notify
/// [MediaQuery] dependents, so a value cached in `didChangeDependencies` would
/// go stale.
bool reduceMotionOf(BuildContext context) =>
    (MediaQuery.maybeOf(context)?.disableAnimations ?? false) ||
    WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .reduceMotion;
