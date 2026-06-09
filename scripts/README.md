# Scripts

Utility scripts for Haven project development and CI.

## Coverage Testing

### `coverage.sh`

Runs unit tests with coverage for both Rust and Flutter packages.

**Usage:**
```bash
./scripts/coverage.sh
```

**Requirements:**
- `cargo-llvm-cov` (installed automatically if missing)
- `lcov` tools for HTML report generation (optional)
  - Ubuntu/Debian: `sudo apt-get install lcov`
  - macOS: `brew install lcov`

**Output:**
- Rust: `haven-core/target/llvm-cov/html/index.html`
- Flutter: `haven/coverage/html/index.html`
- lcov files for both packages

### Manual Coverage Commands

**Rust (haven-core):**
```bash
cd haven-core
cargo llvm-cov --open  # Run tests + open HTML report in browser
```

**Flutter (haven):**
```bash
cd haven
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html  # macOS
xdg-open coverage/html/index.html  # Linux
```

### CI Coverage

Coverage is automatically run on all PRs and commits to main branch:
- **Threshold:** 70% minimum line coverage
- **Reports:** Uploaded as GitHub Actions artifacts
- **CI fails** if coverage is below threshold

View coverage reports:
1. Go to Actions tab in GitHub
2. Click on the workflow run
3. Download artifacts: `rust-coverage-report` or `flutter-coverage-report`

## Release & Map Secrets

### `build_release.sh`

The **blessed path for release builds**. Injects the Stadia Maps API key,
forces Dart obfuscation, runs the secret guard, and passes the native release
gate. A bare `flutter build --release` is intentionally gated to fail; use this
instead. See `haven/DEVELOPMENT.md` → "Build APK".

**Usage:**
```bash
scripts/build_release.sh apk         # release APK
scripts/build_release.sh appbundle   # Play Store .aab
scripts/build_release.sh ios         # iOS release (no codesign)
```

**Key source (first match wins):**
- `haven/dart_defines/secrets.json` (gitignored; local dev), or
- `$STADIA_API_KEY` env var (CI; written to a chmod-600 temp file so the key
  never appears in argv).

Refuses to build if the key is missing/empty/placeholder. Emits debug symbols to
`haven/build/symbols/` (gitignored) — keep them to de-obfuscate crash reports.

### `ci/check_no_committed_secrets.sh`

Fails if the Stadia key (or any UUID-shaped secret) is committed, if the
gitignored `secrets.json` becomes tracked, or if `tiles.dart` stops injecting
the key at compile time. Runs in CI (`No Committed Secrets` job), inside
`build_release.sh`, and automatically on every release build (Gradle + Xcode).

**Usage:** `bash scripts/ci/check_no_committed_secrets.sh`

### `ci/setup_android_signing.sh`

CI-only. Decodes the Android release keystore from `ANDROID_KEYSTORE_BASE64` and
writes `haven/android/key.properties` (both gitignored). No-ops if the keystore
secret is unset (build then falls back to debug signing). Used by
`.github/workflows/release-build.yml`.
