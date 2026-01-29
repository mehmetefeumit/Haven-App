#!/bin/bash
set -e

# Change to the Flutter project directory
cd "$(dirname "$0")/../haven"

echo "Regenerating Flutter Rust Bridge bindings..."
flutter_rust_bridge_codegen generate

echo ""
echo "Done! Generated files updated:"
echo "  - Rust: ../haven-core/src/frb_generated/mod.rs"
echo "  - Dart: lib/src/rust/"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff"
echo "  2. Format code: cargo fmt (Rust) and dart format . (Dart)"
echo "  3. Run tests to verify nothing broke"
