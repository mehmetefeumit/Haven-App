# Flutter Rust Bridge Integration

This document describes the Flutter Rust Bridge (FRB) integration in Haven-App, explaining the architecture, file organization, and development workflow.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Dual-Crate Structure](#dual-crate-structure)
- [How FRB Integration Works](#how-frb-integration-works)
- [File Organization](#file-organization)
- [Adding New Rust APIs](#adding-new-rust-apis)
- [Regeneration Workflow](#regeneration-workflow)
- [Platform-Specific Build Process](#platform-specific-build-process)
- [Troubleshooting](#troubleshooting)
- [Additional Resources](#additional-resources)

## Architecture Overview

Haven-App uses a **dual-crate architecture** that cleanly separates pure Rust business logic from FFI concerns:

```
Haven-App/
├── haven-core/              # Pure Rust library (NO FFI dependencies)
│   └── src/
│       ├── api.rs           # Core business logic
│       ├── location/        # Location module
│       └── lib.rs           # Crate entry point
│
└── haven/                   # Flutter app
    ├── rust_builder/        # FFI wrapper crate (uses flutter_rust_bridge)
    │   └── src/
    │       ├── api.rs       # FFI wrappers with #[frb] annotations
    │       ├── frb_generated.rs  # FRB-generated Rust bindings
    │       └── lib.rs       # Crate entry point
    │
    └── lib/
        └── src/
            └── rust/        # FRB-generated Dart bindings
                ├── api.dart
                ├── frb_generated.dart
                └── ...
```

**Data Flow:**
```
Flutter (Dart) ←→ FRB Dart Bindings ←→ FFI ←→ rust_lib_haven ←→ haven-core
```

## Dual-Crate Structure

Haven-App follows a clean separation of concerns with two Rust crates:

### haven-core (Pure Rust Library)

- **Location**: `Haven-App/haven-core/`
- **Purpose**: Core business logic with no FFI dependencies
- **Crate Type**: `lib` only (standard Rust library)
- **Dependencies**: No flutter_rust_bridge - pure Rust
- **Testable**: Can be tested independently without Flutter

```toml
# haven-core/Cargo.toml
[lib]
crate-type = ["lib"]

[dependencies]
# Pure Rust dependencies only - NO flutter_rust_bridge
serde = { version = "1.0", features = ["derive"] }
chrono = { version = "0.4", features = ["serde"] }
geohash = "0.13"
```

### rust_lib_haven (FFI Wrapper)

- **Location**: `Haven-App/haven/rust_builder/`
- **Purpose**: Thin FFI wrapper that exposes haven-core to Flutter
- **Crate Type**: `cdylib` (Android/desktop) + `staticlib` (iOS)
- **Dependencies**: flutter_rust_bridge + haven-core
- **Role**: Only handles FFI concerns (opaque types, sync/async markers)

```toml
# haven/rust_builder/Cargo.toml
[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
flutter_rust_bridge = "=2.11.1"
haven-core = { path = "../../haven-core" }
```

### Why This Architecture?

1. **No Duplicate Symbols**: Only `rust_lib_haven` generates FFI symbols
2. **Clean Separation**: Business logic in haven-core, FFI in rust_lib_haven
3. **Reusability**: haven-core can be used by other Rust projects
4. **Testability**: haven-core tests run without FFI complexity
5. **Maintainability**: Clear boundaries between concerns

## How FRB Integration Works

### 1. Build-Time Code Generation

FRB uses a **code generation approach**:

1. You write wrapper code in `rust_lib_haven/src/api.rs` with `#[frb]` annotations
2. Wrapper types delegate to haven-core implementations
3. `flutter_rust_bridge_codegen` generates:
   - **Rust bindings** (`frb_generated.rs`) - FFI layer on Rust side
   - **Dart bindings** (`lib/src/rust/*.dart`) - FFI layer on Dart side

### 2. Runtime FFI Communication

At runtime:
- Flutter calls Dart binding functions
- Dart bindings use `dart:ffi` to call native functions
- Native functions (via FRB Rust bindings) call rust_lib_haven wrappers
- Wrappers delegate to haven-core
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
rust_input: crate::api       # API entry point in rust_lib_haven
rust_root: rust_builder      # FFI wrapper crate root
dart_output: lib/src/rust    # Generated Dart files
```

**`Cargo.toml`** (in `haven/rust_builder/`):
```toml
[lib]
crate-type = ["staticlib", "cdylib"]
```
- `staticlib`: For iOS
- `cdylib`: For Android/desktop

**`Cargo.toml`** (in `haven-core/`):
```toml
[lib]
crate-type = ["lib"]
```
- Pure library type only (no FFI outputs)

### Generated Files

**Rust Side** (`haven/rust_builder/src/frb_generated.rs`):
- FFI function definitions
- Type conversions (Rust to C)
- Wire protocol serialization

**Dart Side** (`haven/lib/src/rust/`):
- `frb_generated.dart`: FFI declarations and core infrastructure
- `api.dart`: Dart API mirroring your Rust API
- Additional files for complex types

**Generated files are committed to git** (per FRB official recommendation) to:
- Ensure reproducible builds
- Support CI/CD without regeneration
- Make code review easier

## Adding New Rust APIs

Follow these steps to add new functionality:

### Step 1: Write Core Logic in haven-core

Add business logic to `haven-core/src/`:

```rust
// haven-core/src/api.rs
impl HavenCore {
    /// Core business logic - no FFI annotations
    pub fn greet(&self, name: &str) -> String {
        format!("Hello, {}!", name)
    }
}
```

### Step 2: Create FFI Wrapper in rust_lib_haven

Add wrapper in `haven/rust_builder/src/api.rs`:

```rust
// haven/rust_builder/src/api.rs
use flutter_rust_bridge::frb;

#[derive(Debug, Default)]
#[frb(opaque)]
pub struct HavenCore {
    inner: haven_core::HavenCore,
}

impl HavenCore {
    /// FFI wrapper with #[frb] annotations
    #[frb(sync)]
    pub fn greet(&self, name: String) -> String {
        self.inner.greet(&name)
    }
}
```

**Key Points:**
- Wrapper types are marked `#[frb(opaque)]`
- Methods marked `#[frb(sync)]` for synchronous FFI calls
- Wrappers delegate to haven-core implementations
- Convert between FFI-safe types as needed

### Step 3: Regenerate Bindings

```bash
# From repository root:
./scripts/regenerate_frb.sh

# Or manually from haven/:
cd haven
flutter_rust_bridge_codegen generate
```

This updates:
- `haven/rust_builder/src/frb_generated.rs`
- `haven/lib/src/rust/api.dart` and related files

### Step 4: Use in Flutter

```dart
import 'package:haven/src/rust/api.dart';

// Call your new function
final core = HavenCore();
final greeting = core.greet(name: "World");
print(greeting);  // "Hello, World!"
```

### Step 5: Verify

Run all checks (per `CLAUDE.md`):

```bash
# Rust checks for haven-core
cd haven-core
cargo fmt --check
cargo clippy
cargo build
cargo test

# Rust checks for rust_lib_haven
cd ../haven/rust_builder
cargo fmt --check
cargo clippy
cargo build

# Flutter checks
cd ..
dart format --set-exit-if-changed .
dart analyze
flutter build apk --debug
flutter test
```

## Regeneration Workflow

### When to Regenerate

Regenerate FRB bindings whenever you:
- Add/modify/remove `#[frb]` functions in `rust_lib_haven`
- Change function signatures (parameters, return types)
- Add/modify wrapper structs or enums
- Update FRB version

**Note**: Changes to haven-core do NOT require regeneration unless you also update the wrappers in rust_lib_haven.

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
   cd haven/rust_builder && cargo fmt
   cd .. && dart format .
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

### Issue: Duplicate symbol errors during build

**Symptom**: Linker errors about duplicate symbols like `frb_dart_fn_deliver_output`.

**Cause**: Multiple crates generating FRB bindings that get linked together.

**Solution**: Ensure only `rust_lib_haven` has FRB code generation:
- `haven-core` should NOT have `frb_generated` module
- `haven-core` should NOT depend on `flutter_rust_bridge`
- `haven-core` should have `crate-type = ["lib"]` only

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
1. Ensure type is annotated with `#[frb(opaque)]` in rust_lib_haven
2. Check if the type is supported by FRB (see [FRB supported types](https://cjycode.com/flutter_rust_bridge/guides/types/types.html))
3. For unsupported types, create a wrapper struct in rust_lib_haven

### Issue: Generated bindings out of sync

**Symptom**: Compilation errors after changing Rust API.

**Solution**:
```bash
./scripts/regenerate_frb.sh
cd haven/rust_builder && cargo fmt
cd .. && dart format .
```

### Issue: "Error: undefined symbol" at runtime

**Symptom**: Flutter app crashes with missing symbol error.

**Solutions**:
1. Ensure Rust library is built for the correct architecture
2. Clean and rebuild everything:
   ```bash
   cd haven-core && cargo clean
   cd ../haven/rust_builder && cargo clean
   cd .. && flutter clean && flutter pub get
   flutter build apk --debug
   ```
3. Check that `crate-type` in rust_lib_haven includes `cdylib` (Android/desktop) or `staticlib` (iOS)

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

# Update FRB Rust dependency in rust_lib_haven
cd haven/rust_builder
cargo update flutter_rust_bridge

# Update FRB Dart dependency
cd ..
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
