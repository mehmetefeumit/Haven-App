/// The app version shown to the user and sent in Haven's own User-Agent.
library;

/// The release tag's version (`v0.2.3-beta.1` → `0.2.3-beta.1`), compiled in
/// by `scripts/build_release.sh` as `--dart-define=HAVEN_VERSION=…`; the
/// native version stamp drops the pre-release suffix, so it cannot be read
/// back at runtime. `dev` in any build that did not go through the wrapper.
const String havenVersion = String.fromEnvironment(
  'HAVEN_VERSION',
  defaultValue: 'dev',
);
