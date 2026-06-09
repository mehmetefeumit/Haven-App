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
adb shell am start -n com.haven.app/.MainActivity
```

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
