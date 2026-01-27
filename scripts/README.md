# Scripts

Utility scripts for Haven project development and CI.

## Coverage Testing

### `coverage.sh`

Runs unit tests with coverage for both Rust and Flutter packages.

**Usage:**
```bash
./scripts/coverage.sh
```

**Requirements:**
- `cargo-llvm-cov` (installed automatically if missing)
- `lcov` tools for HTML report generation (optional)
  - Ubuntu/Debian: `sudo apt-get install lcov`
  - macOS: `brew install lcov`

**Output:**
- Rust: `haven-core/target/llvm-cov/html/index.html`
- Flutter: `haven/coverage/html/index.html`
- lcov files for both packages

### Manual Coverage Commands

**Rust (haven-core):**
```bash
cd haven-core
cargo llvm-cov --open  # Run tests + open HTML report in browser
```

**Flutter (haven):**
```bash
cd haven
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html  # macOS
xdg-open coverage/html/index.html  # Linux
```

### CI Coverage

Coverage is automatically run on all PRs and commits to main branch:
- **Threshold:** 70% minimum line coverage
- **Reports:** Uploaded as GitHub Actions artifacts
- **CI fails** if coverage is below threshold

View coverage reports:
1. Go to Actions tab in GitHub
2. Click on the workflow run
3. Download artifacts: `rust-coverage-report` or `flutter-coverage-report`
