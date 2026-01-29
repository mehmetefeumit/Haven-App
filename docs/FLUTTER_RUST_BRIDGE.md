# Flutter Rust Bridge Integration

This document describes the Flutter Rust Bridge (FRB) integration in Haven-App, explaining the architecture, file organization, and development workflow.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Monorepo Structure](#monorepo-structure)
- [How FRB Integration Works](#how-frb-integration-works)
- [File Organization](#file-organization)
- [Adding New Rust APIs](#adding-new-rust-apis)
- [Regeneration Workflow](#regeneration-workflow)
- [Platform-Specific Build Process](#platform-specific-build-process)
- [Troubleshooting](#troubleshooting)
- [Additional Resources](#additional-resources)

## Architecture Overview

Haven-App uses a **monorepo structure** with two main components:

```
Haven-App/
├── haven-core/          # Rust crate (backend logic)
│   └── src/
│       ├── api.rs       # Public API exposed to Flutter
│       ├── frb_generated/
│       │   └── mod.rs   # FRB-generated Rust bindings
│       └── lib.rs       # Crate entry point
│
└── haven/               # Flutter app (UI)
    └── lib/
        └── src/
            └── rust/    # FRB-generated Dart bindings
                ├── api.dart
                ├── frb_generated.dart
                └── ...
```

**Data Flow:**
```
Flutter (Dart) ←→ FRB Dart Bindings ←→ FFI ←→ FRB Rust Bindings ←→ Rust Core
```

## Monorepo Structure

Haven-App follows FRB best practices for monorepo layout:

- **`haven-core/`**: Rust crate containing all backend logic
  - Standard Rust library (`lib.rs`)
  - Public API in `src/api.rs` (marked with `#[frb]` annotations)
  - Generated Rust bindings in `src/frb_generated/`

- **`haven/`**: Flutter application
  - Uses Cargokit to build the Rust crate for all platforms
  - Generated Dart bindings in `lib/src/rust/`
  - Imports Rust functionality via `package:haven/src/rust/api.dart`

## How FRB Integration Works

### 1. Build-Time Code Generation

FRB uses a **code generation approach**:

1. You write Rust code with `#[frb]` annotations
2. `flutter_rust_bridge_codegen` analyzes your Rust code
3. Generates:
   - **Rust bindings** (`frb_generated/mod.rs`) - FFI layer on Rust side
   - **Dart bindings** (`lib/src/rust/*.dart`) - FFI layer on Dart side

### 2. Runtime FFI Communication

At runtime:
- Flutter calls Dart binding functions
- Dart bindings use `dart:ffi` to call native functions
- Native functions (via FRB Rust bindings) call your Rust API
- Results flow back through the same path

### 3. Cargokit Integration

Cargokit handles building the Rust crate for all platforms:
- **Android**: Builds `.so` libraries for ARM/x86
- **iOS**: Builds universal frameworks
- **Desktop** (Linux/macOS/Windows): Builds native libraries
- Automatically invoked by Flutter build commands

## File Organization

### Configuration Files

**`flutter_rust_bridge.yaml`** (in `haven/`):
```yaml
rust_input:
  - ../haven-core/src/api.rs  # Rust API entry point
rust_root: ../haven-core/     # Rust crate root
dart_output:
  - lib/src/rust/             # Generated Dart files
```

**`Cargo.toml`** (in `haven-core/`):
```toml
[lib]
crate-type = ["staticlib", "cdylib", "lib"]
```
- `staticlib`: For iOS
- `cdylib`: For Android/desktop
- `lib`: For Rust tests

### Generated Files

**Rust Side** (`haven-core/src/frb_generated/mod.rs`):
- FFI function definitions
- Type conversions (Rust ↔ C)
- Wire protocol serialization
- **480+ lines** - organized in submodule for clarity

**Dart Side** (`haven/lib/src/rust/`):
- `frb_generated.dart`: FFI declarations and core infrastructure
- `api.dart`: Dart API mirroring your Rust API
- Additional files for complex types

**Both generated files are committed to git** (per FRB official recommendation) to:
- Ensure reproducible builds
- Support CI/CD without Rust toolchain
- Make code review easier

## Adding New Rust APIs

Follow these steps to add new functionality:

### Step 1: Write Rust Code

Add functions to `haven-core/src/api.rs`:

```rust
/// Example: Add a new greeting function
#[frb]
pub fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}
```

**Supported Types:**
- Primitives: `i32`, `u64`, `f64`, `bool`, `String`
- Collections: `Vec<T>`, `HashMap<K, V>`
- Custom structs with `#[frb]`
- Enums (including Rust enums)
- `Option<T>`, `Result<T, E>`
- Async functions (returns `Future` in Dart)

### Step 2: Regenerate Bindings

```bash
# From repository root:
./scripts/regenerate_frb.sh

# Or manually from haven/:
cd haven
flutter_rust_bridge_codegen generate
```

This updates:
- `haven-core/src/frb_generated/mod.rs`
- `haven/lib/src/rust/api.dart` and related files

### Step 3: Use in Flutter

```dart
import 'package:haven/src/rust/api.dart';

// Call your new function
final greeting = await greet(name: "World");
print(greeting);  // "Hello, World!"
```

### Step 4: Verify

Run all checks (per `CLAUDE.md`):

```bash
# Rust checks
cd haven-core
cargo fmt --check
cargo clippy
cargo build
cargo test

# Flutter checks
cd ../haven
dart format --set-exit-if-changed .
dart analyze
flutter build apk --debug
flutter test
```

## Regeneration Workflow

### When to Regenerate

Regenerate FRB bindings whenever you:
- Add/modify/remove `#[frb]` functions
- Change function signatures (parameters, return types)
- Add/modify structs or enums used in the API
- Update FRB version

### Quick Regeneration

```bash
./scripts/regenerate_frb.sh
```

This script:
1. Changes to the `haven/` directory
2. Runs `flutter_rust_bridge_codegen generate`
3. Updates all generated files

### Manual Regeneration

If you need more control:

```bash
cd haven
flutter_rust_bridge_codegen generate --verbose
```

**Options:**
- `--verbose`: Show detailed generation progress
- `--watch`: Auto-regenerate on Rust file changes (development mode)

### After Regeneration

1. **Review changes**: `git diff` to see what FRB generated
2. **Format code**:
   ```bash
   cd haven-core && cargo fmt
   cd ../haven && dart format .
   ```
3. **Run tests**: Ensure nothing broke
4. **Commit**: Include generated files in your commit

## Platform-Specific Build Process

### Android

```bash
cd haven
flutter build apk --debug    # or --release
```

Cargokit automatically:
- Detects target architectures (arm64-v8a, armeabi-v7a, x86_64)
- Invokes `cargo build` for each architecture
- Copies `.so` files to correct locations
- Bundles them in the APK

### iOS

```bash
cd haven
flutter build ios --debug --no-codesign
```

Cargokit:
- Builds for both simulator and device architectures
- Creates universal framework
- Integrates with Xcode build

**Note**: iOS builds require macOS and Xcode.

### Linux

```bash
cd haven
flutter build linux
```

Cargokit builds a native `.so` library.

### macOS

```bash
cd haven
flutter build macos
```

Cargokit builds a `.dylib` for macOS.

### Windows

```bash
cd haven
flutter build windows
```

Cargokit builds a `.dll` for Windows.

**Cross-compilation**: Possible for some platforms using `cross` or similar tools, but Cargokit handles most cases automatically.

## Troubleshooting

### Issue: "No such file or directory" during Flutter build

**Symptom**: Flutter can't find the Rust library.

**Solutions**:
1. Ensure Rust toolchain is installed: `rustc --version`
2. Clean and rebuild:
   ```bash
   cd haven
   flutter clean
   flutter pub get
   flutter build apk --debug
   ```
3. Check `rust_root` path in `flutter_rust_bridge.yaml`

### Issue: "Error: type does not implement Frb trait"

**Symptom**: FRB can't generate bindings for your type.

**Solutions**:
1. Ensure type is annotated with `#[frb]` (for custom types)
2. Check if the type is supported by FRB (see [FRB supported types](https://cjycode.com/flutter_rust_bridge/guides/types/types.html))
3. For unsupported types, use opaque types or serialization

### Issue: Generated bindings out of sync

**Symptom**: Compilation errors after changing Rust API.

**Solution**:
```bash
./scripts/regenerate_frb.sh
cd haven-core && cargo fmt
cd ../haven && dart format .
```

### Issue: "Error: undefined symbol" at runtime

**Symptom**: Flutter app crashes with missing symbol error.

**Solutions**:
1. Ensure Rust library is built for the correct architecture
2. Clean and rebuild everything:
   ```bash
   cd haven-core && cargo clean
   cd ../haven && flutter clean && flutter pub get
   flutter build apk --debug
   ```
3. Check that `crate-type` in `Cargo.toml` includes `cdylib` (Android/desktop) or `staticlib` (iOS)

### Issue: Slow regeneration

**Symptom**: `flutter_rust_bridge_codegen generate` takes a long time.

**Context**: Normal for large APIs. FRB analyzes all Rust code.

**Optimization**:
- Use `--skip-deps` flag if you haven't changed dependencies
- Consider splitting large APIs into multiple files

### Issue: FRB version mismatch

**Symptom**: Errors about incompatible FRB versions.

**Solution**:
```bash
# Update FRB CLI
cargo install flutter_rust_bridge_codegen

# Update FRB Rust dependency
cd haven-core
cargo update flutter_rust_bridge

# Update FRB Dart dependency
cd ../haven
flutter pub upgrade flutter_rust_bridge
```

Ensure versions are compatible (check FRB release notes).

## Additional Resources

### Official Documentation

- [FRB Official Website](https://cjycode.com/flutter_rust_bridge/)
- [FRB Guide](https://cjycode.com/flutter_rust_bridge/guides/quickstart.html)
- [Supported Types](https://cjycode.com/flutter_rust_bridge/guides/types/types.html)
- [Async Programming](https://cjycode.com/flutter_rust_bridge/guides/async.html)

### Project-Specific

- `RUST_CODING_STANDARDS.md`: Rust code style guide
- `FLUTTER_DART_BEST_PRACTICES.md`: Flutter/Dart style guide
- `CLAUDE.md`: Development workflow and verification requirements

### Tools

- [flutter_rust_bridge_codegen](https://pub.dev/packages/flutter_rust_bridge_codegen)
- [Cargokit](https://github.com/irondash/cargokit)

### Community

- [FRB GitHub Discussions](https://github.com/fzyzcjy/flutter_rust_bridge/discussions)
- [FRB Discord](https://discord.gg/ZGYwC7Z5fB)

---

**Questions or Issues?**

If you encounter problems not covered here:
1. Check FRB official docs (links above)
2. Search GitHub issues: [FRB Issues](https://github.com/fzyzcjy/flutter_rust_bridge/issues)
3. Ask in the FRB Discord community
