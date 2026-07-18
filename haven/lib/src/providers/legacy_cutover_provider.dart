/// DM-4c Dark Matter cutover explainer state.
///
/// Whether the once-only cutover explainer should be shown this launch is
/// decided BEFORE `runApp` (in `main.dart`, alongside the
/// `LegacyCutoverService` call) and threaded in here as the seed value.
/// `MapShell` reads this once on its first frame, shows the explainer if
/// `true`, then flips it back to `false` so a widget rebuild (e.g. a
/// hot-reload in debug, or any provider invalidation cascade) never
/// re-shows it within the same app session.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the one-time Dark Matter cutover explainer is still owed this
/// app session.
///
/// Seeded from `main.dart` via `overrideWith` before `runApp`; defaults to
/// `false` (e.g. under test `ProviderScope`s that don't override it).
final legacyCutoverExplainerProvider = StateProvider<bool>((ref) => false);
