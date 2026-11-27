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
| `scripts/ci/check_coverage.sh` | ≈ 31 min, measured 2026-11-02 with --sequential | **Everything** `.github/workflows/coverage.yml` runs. Run it on demand; CI enforces the same gates. |
| `scripts/coverage.sh` | ≈ 31 min, measured 2026-11-02 with --sequential | The same gate, plus HTML reports. |

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
scripts/build_release.sh ipa         # iOS signed App Store IPA for TestFlight (BUILD_NUMBER required)
scripts/build_release.sh version     # print the version arguments a build would use; builds nothing
```

**Version:** `BUILD_NAME` (the release tag without its `v`, set by
`release-build.yml`) is compiled into the app in full as
`--dart-define=HAVEN_VERSION` (About page), and passed without its
`-prerelease`/`+build` suffix as the native `--build-name`. Unset, both come
from `pubspec.yaml`'s `version:`. Anything that is not a version is refused;
`ci/check_release_version_stamp.sh` holds this.

**Key source (first match wins):**
- `haven/dart_defines/secrets.json` (gitignored; local dev), or
- `$STADIA_API_KEY` env var (CI; written to a chmod-600 temp file so the key
  never appears in argv).

Refuses to build if the key is missing/empty/placeholder. Emits debug symbols to
`haven/build/symbols/` (gitignored) — keep them to de-obfuscate crash reports.

**Offline:** `HAVEN_GRADLE_OFFLINE=1` builds from the local Gradle dependency
cache alone, after provisioning (on CI) the NDK and CMake an offline AGP cannot
install. The Android launch gate's build mode sets it over its run's verified
set; `release-build.yml` never does. Any other value is refused.

## Android Gradle builds in CI

Every Android lane builds OFFLINE from one dependency set per run, resolved and
proved complete by `.github/workflows/android-gradle-deps.yml`; a lane never
meets the network at its Gradle build. The pieces:

| Script | Role |
|---|---|
| `ci/gradle_deps.sh produce` | The deps job: reuse a trusted main run's verified set (`gradle-deps-src-<key>`, 90 days) or resolve online, verify it offline, run the offline and strictness canaries, pack it as the `gradle-deps` artifact (7 days). |
| `ci/gradle_deps.sh unpack <dir>` | A lane: install the set into `~/.gradle` and pin Flutter to the version it was resolved with. |
| `ci/gradle-resolve-all.init.gradle.kts` | `havenResolveAll`: every resolvable configuration of the composite, Flutter's included build too, non-leniently. |
| `ci/gradle-offline.init.gradle.kts` | Offline for the build and every build it includes. |
| `ci/build_apk_with_retry.sh` | The one build site: `HAVEN_GRADLE_OFFLINE=1` installs the offline switch for the build only, a gap is tried once and named as the deps job's; `--resolve-only` is the deps job's resolution; `--provision-only` the NDK and CMake. |
| `ci/check_gradle_build_hardened.sh` | Holds every Gradle-building job to that shape. |
| `ci/check_all_jobs_passed.sh` | The `verdict` job: a run whose deps job failed is red, never passed by skipped lanes. |

The shell scripts take `--self-test`. `docs/E2E_TROUBLESHOOTING.md` failure modes 6 and 6b
say what to do when the deps job or an offline build is red.

### `generate_map_style_previews.sh`

Renders the Map style page's bundled preview images from Stadia's cacheable
Static Maps endpoint with the same key. Billed per request, and storing the
images depends on a paid Stadia plan: see `haven/DEVELOPMENT.md` → "Map-style
previews" for the licensing, the exact command and the add-a-style checklist.

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
