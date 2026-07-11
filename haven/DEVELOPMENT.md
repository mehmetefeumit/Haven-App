# Development Setup

## Dependencies

| Dependency | Purpose | Installation |
|------------|---------|--------------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install/linux/android) | App framework | See Flutter docs |
| [Android SDK](https://developer.android.com/studio) | Android build tools | Via Android Studio or command-line tools |
| [Android NDK](https://developer.android.com/ndk) | Native development (for Rust FFI) | Installed automatically by Flutter |

### Flutter Installation

Download and extract the Flutter SDK:

```bash
# Download from https://docs.flutter.dev/get-started/install/linux/android
# Extract to your preferred location, e.g., ~/flutter

# Add to PATH in ~/.bashrc or ~/.zshrc
export PATH="$HOME/flutter/bin:$PATH"

# Verify installation
flutter doctor
```

### Android SDK Installation

Option 1: Install [Android Studio](https://developer.android.com/studio) (includes SDK)

Option 2: Command-line tools only:

```bash
# Download from https://developer.android.com/studio#command-line-tools-only
mkdir -p ~/Android/Sdk/cmdline-tools
unzip commandlinetools-linux-*.zip -d ~/Android/Sdk/cmdline-tools
mv ~/Android/Sdk/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest

# Add to PATH
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# Accept licenses
sdkmanager --licenses

# Install required components
sdkmanager "platform-tools" "platforms;android-34" "build-tools;35.0.0" "emulator"
```

## Android Emulator Setup

### Create an Android Virtual Device

```bash
# Install a system image
sdkmanager "system-images;android-34;google_apis;x86_64"

# Create AVD
avdmanager create avd \
  --name haven_test \
  --package "system-images;android-34;google_apis;x86_64" \
  --device "pixel_6"
```

### Start the Emulator

```bash
emulator -avd haven_test
```

For headless/CI environments:

```bash
emulator -avd haven_test -no-window -no-audio
```

## Running the App

### Development (with hot reload)

```bash
cd haven

# Check connected devices
flutter devices

# Run on emulator or connected device
flutter run
```

### Build APK

Debug builds need no map key — the map renders error tiles (this is expected):

```bash
flutter build apk --debug
```

**Release builds MUST go through `scripts/build_release.sh`.** A bare
`flutter build --release` is intentionally gated to fail (Android Gradle + iOS
Xcode), because the wrapper does three things a plain build cannot:

- injects the Stadia Maps API key from the gitignored
  `haven/dart_defines/secrets.json` (via `--dart-define-from-file`, kept off your
  shell history and argv),
- forces `--obfuscate --split-debug-info=build/symbols`,
- runs the no-committed-secrets guard first, and exports
  `HAVEN_RELEASE_WRAPPER=1` so the native release gate passes.

```bash
# One-time: create your local key file from the committed template
# (gitignored — NEVER commit the real key), then paste your Stadia key into it.
cp haven/dart_defines/secrets.example.json haven/dart_defines/secrets.json

# Release builds (run from the repo root):
scripts/build_release.sh apk         # -> build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk (per-ABI splits)
scripts/build_release.sh appbundle   # -> build/app/outputs/bundle/release/app-release.aab
scripts/build_release.sh ios         # iOS release (no codesign)
scripts/build_release.sh ipa         # iOS signed App Store IPA for TestFlight (see below)
```

Why a wrapper and not a plain `flutter build`? `--dart-define`/`--obfuscate` are
consumed by the `flutter` CLI *before* Gradle/Xcode run, and Flutter exposes no
project-level default for them, so they cannot be auto-forced onto a bare build
(the leak-guard, however, *is* wired to run automatically on every release
build). Keep `build/symbols/` to de-obfuscate crash reports — it is gitignored;
archive it out-of-band, never commit it. To preview real Stadia tiles in a debug
run: `flutter run --dart-define-from-file=dart_defines/secrets.json` (from `haven/`).

> The bundled key is still extractable from any release binary — no client app
> can prevent this, and Stadia offers no app-locking. The real safeguard is
> operational (dashboard usage cap with overage OFF, the 80%-credit alert email,
> key rotation); see `docs/MAP_AND_PRIVACY_BACKLOG.md`.

Output: `build/app/outputs/flutter-apk/app-debug.apk` (debug) /
`app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk` (release, per-ABI splits — see
"Cutting a release" below).

### Install APK Manually

```bash
adb install build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.oblivioustech.haven/.MainActivity
```

### Cutting a release (tag → all channels)

A release is cut by pushing a version **tag** — the only manual git action. CI
never tags or commits. Pushing `vX.Y.Z` (or `vX.Y.Z-beta.N` for a pre-release) to
`origin` triggers `.github/workflows/release-build.yml`, which:

1. Runs the gate (rust-check, cross-check, coverage, no-committed-secrets,
   tile-provider-check) on the tagged commit.
2. **Refuses to proceed if the release keystore isn't configured** — a tag must be
   release-signed, never debug-signed.
3. Builds the **per-ABI release APKs** (`app-arm64-v8a-release.apk`,
   `…-armeabi-v7a-…`, `…-x86_64-…`). Marketing version comes from the tag
   (`vX.Y.Z → X.Y.Z`); the base versionCode is the CI run number.
4. Creates a **GitHub Release** for the tag and attaches the per-ABI APKs +
   `.sha256` sidecars. Tags containing `-` are flagged pre-release and not marked
   "Latest".
5. Publishes to **Zapstore** (`zsp publish`, gated on `ZAPSTORE_SIGN_WITH`) and
   uploads the iOS IPA to **TestFlight** (see below).

The GitHub Release is the canonical Android channel: the **direct APK download**,
**Obtainium**, and **Zapstore** all consume the APK from it (Obtainium pulls it
per-user; Zapstore's `zsp` pulls the arm64 asset and signs the Nostr events).

Pre-reqs before the first tag: set the `ANDROID_KEYSTORE_*` secrets (so the build
is release-signed), `STADIA_API_KEY`, the iOS Match/ASC secrets, and (for
Zapstore) `ZAPSTORE_SIGN_WITH`.

**versionCode caveat (`--split-per-abi`).** Flutter overrides versionCode per ABI:
arm64-v8a = `2000 + run_number`, armeabi-v7a = `1000 + run_number`,
x86_64 = `4000 + run_number`. Each ABI's lineage stays monotonic because the base
(run number) only increases — relevant if you ever inspect a built APK's
versionCode directly.

**Publish the signing fingerprint.** After the first release-signed build, run
`apksigner verify --print-certs app-arm64-v8a-release.apk` (or
`keytool -list -v -keystore <release.jks>`) and paste the **SHA-256** into the
README's "Install (beta)" verification block so users can confirm authenticity.

### Publishing to Zapstore

The `zapstore` job runs `zsp publish` on every tag. zsp signs only the Nostr
listing/release *events* — it never re-signs the APK, so Zapstore distributes
Haven's own signed APK (same key as the GitHub Release / Obtainium builds). It
pulls the `app-arm64-v8a-release.apk` straight from the GitHub Release.

**One-time setup:**

1. **Generate a DEDICATED publishing keypair** — NOT your personal Nostr
   identity. This key only ever signs Haven's Zapstore listing; if it leaks you
   simply rotate it. With the [`nak`](https://github.com/fiatjaf/nak) CLI:
   ```bash
   nak key generate            # prints a new hex private key (save it securely)
   nak key public <hexsec>     # -> hex public key
   nak encode npub <hexpub>    # -> npub1... (goes in zapstore.yaml)
   ```
2. **Set the `pubkey` in `zapstore.yaml`** (uncomment the line and paste the
   `npub1...`). The relay fetches this file from the repo and only whitelists
   Haven if the release event's author matches this pubkey.
3. **Set the `ZAPSTORE_SIGN_WITH` GitHub secret** — pick ONE:
   - **Dedicated nsec (recommended; no server needed).** Store the key in
     `nsec1...` (or 64-char hex) form. The key sits in the CI runner env (masked
     in logs) — acceptable for a dedicated, rotatable publishing key.
   - **NIP-46 bunker (only if you run an always-on signer).** The bunker holding
     the nsec must be reachable on its relay AT THE MOMENT a tag is pushed, so it
     must live on a VPS / always-on box (not your phone/laptop). Run it
     persistently and pre-authorize zsp's client key so no human approval is
     needed:
     ```bash
     nak bunker --sec ncryptsec1... --persist \
       -k <zsp-client-pubkey-hex> \
       wss://relay.zapstore.dev wss://relay.damus.io
     # prints: bunker://<signer-pubkey>?relay=...&secret=...
     ```
     Store that whole `bunker://...` string as `ZAPSTORE_SIGN_WITH`; the nsec then
     never enters the runner. (Scope permissions to Zapstore's kinds:
     `sign_event:32267`, `sign_event:30063`, `sign_event:3063`.)
4. **Do the first publish once INTERACTIVELY** to confirm whitelisting before
   relying on CI (new-npub rejection is normal until the relay has fetched your
   committed `zapstore.yaml` and matched the pubkey):
   ```bash
   SIGN_WITH=<nsec-or-bunker> GITHUB_TOKEN=<gh-token> zsp publish -y zapstore.yaml
   ```

After that, every tagged release auto-publishes via the `zapstore` CI job
(pre-release tags → the `beta` channel). The job installs a pinned,
sha256-verified `zsp` v0.4.11 and runs `scripts/ci/publish_zapstore.sh`; it skips
cleanly until `ZAPSTORE_SIGN_WITH` is set.

### Deploy to TestFlight (iOS)

iOS release builds are signed and uploaded to TestFlight automatically when you
push a version tag (`vX.Y.Z`). All Apple-side work (Xcode, signing, upload) runs
on a GitHub Actions **macOS runner** — you do not need a Mac. Signing uses
[Fastlane Match](https://docs.fastlane.tools/actions/match/) (certificates stored,
encrypted, in a separate private repo) and authenticates to App Store Connect with
an **API key** (no Apple ID / 2FA). The build itself still goes through
`scripts/build_release.sh ipa`, so the Stadia key injection + obfuscation + secret
guard always apply.

Pipeline (in `.github/workflows/release-build.yml`, `ios` job): install signing
assets read-only via Match → render the Team ID into `ios/ExportOptions.plist` →
`scripts/build_release.sh ipa` (single archive: compiles the Rust pod, injects the
key, obfuscates, exports a signed `.ipa`) → upload to TestFlight via
`fastlane ios upload`. The build number is the GitHub Actions run number
(`--build-number`), which is unique and monotonic — never set it in Fastlane (a
`flutter build` regenerates `Generated.xcconfig` and would clobber it).

**One-time setup (no Mac required):**

1. **Apple side.** Register the App ID `com.oblivioustech.haven` and create the app record in
   App Store Connect. Create an **App Store Connect API key** (Users and Access →
   Integrations → App Store Connect API); note the Key ID + Issuer ID and download
   the `.p8` once. The key needs **Admin** role for the one-time certificate
   bootstrap (App Manager is enough for ongoing uploads).
2. **Match repo.** Create a second **private** GitHub repo (e.g.
   `haven-ios-certificates`) — leave it empty.
3. **Generate the distribution key/CSR on Linux** (the cert itself is minted by the
   bootstrap workflow, so this is optional if you let Match create it):
   ```bash
   openssl genrsa -out dist.key 2048
   openssl req -new -key dist.key -out dist.csr -subj "/CN=Haven Distribution"
   ```
4. **Set the GitHub secrets** (repo → Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `MATCH_GIT_URL` | https URL of the private certs repo |
   | `MATCH_PASSWORD` | a strong passphrase you invent (encrypts the stored certs) |
   | `MATCH_GIT_BASIC_AUTHORIZATION` | `base64 -w0 <<<'github-username:PAT'` (PAT scoped to the certs repo) |
   | `APPLE_TEAM_ID` | your 10-char Apple Developer Team ID |
   | `ASC_KEY_ID` | App Store Connect API Key ID |
   | `ASC_ISSUER_ID` | App Store Connect API Issuer ID |
   | `ASC_KEY_P8_BASE64` | `base64 -w0 AuthKey_XXXX.p8` |

   (`STADIA_API_KEY` is already configured for the release pipeline.)
5. **Mint the certificate + profile once:** Actions tab → **iOS Certificates** →
   *Run workflow*. This stores them, encrypted, in the Match repo. Re-run it only
   when the distribution certificate expires (~1 year) or you rotate it.

**Cut a release — the git tag is the single source of truth for the version.**
Pushing an annotated `vMAJOR.MINOR.PATCH` tag is the *only* per-release step: the
pipeline derives the marketing version from the tag (`v1.2.3` → `1.2.3`,
CFBundleShortVersionString / Android versionName) and the build number from the CI
run number (unique + monotonic, CFBundleVersion / Android versionCode). You never
edit `pubspec.yaml` for a release, and nothing is pushed to `main`.

```bash
git tag -a v1.2.3 -m "Haven 1.2.3"   # tag must be vMAJOR.MINOR.PATCH (digits only)
git push origin v1.2.3               # -> Release Build workflow -> Android + iOS/TestFlight
```

The tag must be numeric `vX.Y.Z` (the wrapper rejects anything else, since Apple
requires a numeric short-version string). To re-build the same version (e.g. after
a fix to the pipeline), push a new build number by deleting and re-pushing the tag,
or just bump to the next patch — TestFlight accepts repeated versions as long as
the build number differs, which it always does (it's the run number).
A manual **Run workflow** (workflow_dispatch) on Release Build has no tag, so it
falls back to `pubspec.yaml`'s `version:` — handy for a throwaway signed test build.

**Export compliance:** the first build lands in App Store Connect as *Missing
Compliance*. Answer the encryption question there (Haven ships its own
MLS/Nostr/SQLCipher crypto, so the EAR classification — likely a 740.13(e)
open-source notification or a 5D992 self-classification — is a decision for the
project owner; consider legal review before public/external testing). Once decided,
you can bake `ITSAppUsesNonExemptEncryption` into `ios/Runner/Info.plist` to skip
the per-build prompt.

> **Local builds:** day-to-day development uses Debug (`flutter run`), which needs
> no signing. `scripts/build_release.sh ipa` expects the Match-provisioned cert and
> a real Team ID in `ExportOptions.plist`, so it is really a CI/release path.

## Verification Commands

```bash
# Format check
dart format --set-exit-if-changed .

# Lint
dart analyze

# Run tests
flutter test

# All checks
dart format --set-exit-if-changed . && dart analyze && flutter test
```

### Coverage gate (local, mirrors CI)

CI enforces line-coverage thresholds (`.github/workflows/coverage.yml`): **80%**
for Rust (`haven-core`) and **10%** for Flutter (`haven`). Run the same gate
locally to catch a regression — or a failing/flaky test, which is what actually
fails the CI "Rust Coverage" job — before it reaches CI:

```bash
scripts/ci/check_coverage.sh                 # both stacks (~4-6 min)
CHECK_FLUTTER=0 scripts/ci/check_coverage.sh # Rust (haven-core) only
CHECK_RUST=0    scripts/ci/check_coverage.sh # Flutter (haven) only
```

Enable it as a **pre-push** hook (runs automatically before every `git push`):

```bash
scripts/ci/install_git_hooks.sh   # sets core.hooksPath = .githooks (once per clone)
```

Bypass a single push with `git push --no-verify`; disable with
`git config --unset core.hooksPath`. Requires `cargo-llvm-cov`
(`cargo install cargo-llvm-cov`); otherwise only `flutter`/`cargo` are needed.
Thresholds can be overridden via `RUST_COVERAGE_MIN` / `FLUTTER_COVERAGE_MIN`.

## Troubleshooting

### KVM acceleration (Linux)

Android emulator requires KVM for acceptable performance:

```bash
# Check if KVM is available
kvm-ok

# Install KVM (Fedora)
sudo dnf install @virtualization

# Install KVM (Ubuntu/Debian)
sudo apt install qemu-kvm

# Add user to kvm group
sudo usermod -aG kvm $USER
# Log out and back in
```

### Flutter doctor issues

Run `flutter doctor -v` for detailed diagnostics. Common fixes:

```bash
# Accept Android licenses
flutter doctor --android-licenses

# Update Flutter
flutter upgrade
```
