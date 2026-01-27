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

```bash
# Debug build
flutter build apk --debug

# Release build
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`

### Install APK Manually

```bash
adb install build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.haven.haven/.MainActivity
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
