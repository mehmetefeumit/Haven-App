/// Re-export of widget keys for use from integration_test/e2e/ scenarios.
///
/// Importing the production source directly from a test file is awkward
/// because of `package:haven/src/...` vs `package:haven/lib/src/...` path
/// conventions. This shim gives scenarios a single import:
///
/// ```dart
/// import '_lib/widget_keys.dart';
/// ```
library;

export 'package:haven/src/test_keys.dart' show WidgetKeys;
