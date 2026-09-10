#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Change to the Flutter project directory
cd "${ROOT}/haven"

echo "Regenerating Flutter Rust Bridge bindings..."
flutter_rust_bridge_codegen generate

# Re-pin the generated files' content hashes IMMEDIATELY, from the bytes the
# codegen just wrote. Nothing else compares the Rust and Dart halves of a codec
# — an inverted `SseEncode` discriminant is well-typed on both sides and silent
# at runtime — so `scripts/ci/check_generated_bridge_pinned.sh` gates them on
# these hashes, and this is the only path that writes them.
echo ""
bash "${ROOT}/scripts/ci/check_generated_bridge_pinned.sh" --repin

echo ""
echo "Done! Generated files updated:"
echo "  - Rust: haven/rust_builder/src/frb_generated.rs"
echo "  - Dart: haven/lib/src/rust/"
echo "  - Pins: scripts/ci/generated_bridge.sha256"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff"
echo "  2. Format code: cargo fmt (Rust) and dart format . (Dart)"
echo "  3. Run tests to verify nothing broke"
echo "  4. Stage the generated files AND the pin file together"
