/// Navigation state provider.
///
/// Manages the bottom navigation bar's selected index across the app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bottom navigation bar index provider.
///
/// Tracks which tab is currently selected in the app shell.
/// Defaults to 0 (Map tab).
///
/// Update with:
/// ```dart
/// ref.read(navigationIndexProvider.notifier).state = 1;
/// ```
final navigationIndexProvider = StateProvider<int>((ref) => 0);
