#!/usr/bin/env bash
# Coverage testing script for local development
# Runs coverage for both Rust and Flutter packages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "📊 Running coverage tests for Haven project..."
echo ""

# Check if cargo-llvm-cov is installed
if ! command -v cargo-llvm-cov &> /dev/null; then
    echo "⚠️  cargo-llvm-cov not found. Installing..."
    cargo install cargo-llvm-cov
fi

# Check if lcov is installed (for Flutter)
if ! command -v genhtml &> /dev/null; then
    echo "⚠️  lcov tools not found. Please install lcov:"
    echo "   Ubuntu/Debian: sudo apt-get install lcov"
    echo "   macOS: brew install lcov"
    echo ""
fi

# Run Rust coverage
echo "🦀 Running Rust coverage (haven-core)..."
cd "$PROJECT_ROOT/haven-core"
cargo llvm-cov --all-features --html --ignore-filename-regex '(frb_generated\.rs|\.g\.rs)'
RUST_COVERAGE=$(cargo llvm-cov --all-features --ignore-filename-regex '(frb_generated\.rs|\.g\.rs)' --summary-only | grep 'TOTAL' | awk '{print $10}')
echo "   Coverage: $RUST_COVERAGE"
echo "   Report: haven-core/target/llvm-cov/html/index.html"
echo ""

# Run Flutter coverage
echo "🎯 Running Flutter coverage (haven)..."
cd "$PROJECT_ROOT/haven"
flutter test --coverage

if command -v genhtml &> /dev/null; then
    genhtml coverage/lcov.info -o coverage/html --quiet
    FLUTTER_COVERAGE=$(lcov --summary coverage/lcov.info 2>&1 | grep 'lines' | awk '{print $2}')
    echo "   Coverage: $FLUTTER_COVERAGE"
    echo "   Report: haven/coverage/html/index.html"
else
    echo "   lcov.info generated at: haven/coverage/lcov.info"
    echo "   (Install lcov to generate HTML report)"
fi
echo ""

echo "✅ Coverage tests complete!"
echo ""
echo "To view reports:"
echo "  Rust:    open $PROJECT_ROOT/haven-core/target/llvm-cov/html/index.html"
if command -v genhtml &> /dev/null; then
    echo "  Flutter: open $PROJECT_ROOT/haven/coverage/html/index.html"
fi
