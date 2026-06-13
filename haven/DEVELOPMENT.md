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
scripts/build_release.sh apk         # -> build/app/outputs/flutter-apk/app-release.apk
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
`app-release.apk` (release).

### Install APK Manually

```bash
adb install build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.oblivioustech.haven/.MainActivity
```

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

**Cut a release:**

```bash
git tag v0.1.0
git push origin v0.1.0   # releases are tag-driven; nothing is pushed to main
```

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
