# Scripts

Utility scripts for Haven project development and CI.

## Coverage Testing

One gate, three entry points, all reading the same manifest, the same filters
and the same pinned toolchains. There is deliberately no fourth way to compute
Haven's coverage — there used to be, and the numbers it printed matched nothing
that was enforced.

| Command | Cost | What it checks |
|---------|------|----------------|
| `scripts/ci/check_coverage.sh --static-only` | < 1 s | Manifest pin rule + guard self-tests. Runs on **pre-commit**. |
| `scripts/ci/check_coverage.sh` | ~6-11 min | **Everything** `.github/workflows/coverage.yml` runs. Runs on **pre-push**. |
| `scripts/coverage.sh` | ~6-11 min | The same gate, plus HTML reports. |

```bash
scripts/ci/install_git_hooks.sh              # once per clone — enables both hooks
scripts/ci/check_coverage.sh --static-only   # instant; catches most red coverage runs
scripts/ci/check_coverage.sh                 # full gate, both stacks in parallel
CHECK_FLUTTER=0 scripts/ci/check_coverage.sh # Rust (haven-core) only
CHECK_RUST=0    scripts/ci/check_coverage.sh # Flutter (haven) only
scripts/coverage.sh                          # full gate + HTML reports
```

### The per-path floors

The 80%/50% aggregates are budgets the whole crate shares, so
`scripts/ci/coverage_floors.txt` pins a MINIMUM PER PATH for the security- and
privacy-critical ones. **Never edit a floor by hand** — two commands maintain
the file:

```bash
scripts/ci/check_coverage_floors.sh --lint          # does every floor obey the pin rule?
scripts/ci/check_coverage_floors.sh --lint --fix    # correct the mechanical ones
scripts/ci/check_coverage_floors.sh --repin flutter haven/coverage/lcov_filtered.info
scripts/ci/check_coverage_floors.sh --repin rust    haven-core/coverage.lcov
```

`--repin` raises floors the code has outgrown and refreshes their recorded
measurement. It **never lowers one**: a path whose coverage fell needs tests,
not a smaller number.

### Measuring toolchains are pinned

`scripts/ci/coverage_toolchain.env` fixes the rustc and Flutter versions the
coverage job measures with, because a coverage percentage is a ratio whose
denominator is instrumented lines — a property of the compiler, not of the
tests. Every other workflow keeps floating on `stable`, so new-SDK breakage
still surfaces; it just no longer surfaces as a coverage number nobody changed.
The local Rust gate refuses to run on a different rustc; a Flutter mismatch is
reported and its percentages marked advisory.

### CI Coverage

Coverage runs on every PR and push to main (`.github/workflows/coverage.yml`):
- **Thresholds:** 80% (Rust, `haven-core`), 50% (Flutter, `haven`), plus the
  per-path floors above.
- **Reports:** uploaded as GitHub Actions artifacts.

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
scripts/build_release.sh apk         # per-ABI release APKs (--split-per-abi) — the release artifacts
scripts/build_release.sh appbundle   # Android App Bundle .aab (not used by the release pipeline)
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
