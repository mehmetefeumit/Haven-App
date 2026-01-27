# CLAUDE.md

## Core Principles

1. **Use Sub-Agents** — Delegate tasks to specialized sub-agents whenever possible. Break complex work into focused, parallelizable units.

2. **Follow Coding Standards** — Adhere strictly to project coding standards:
   - Rust: See `RUST_CODING_STANDARDS.md`
   - Flutter/Dart: See `FLUTTER_DART_BEST_PRACTICES.md`

3. **Verify Every Change** — After any code modification, all checks must pass before considering the change complete.

   **Rust:**
   ```bash
   cargo fmt --check    # Format check
   cargo clippy         # Lint
   cargo build          # Build
   cargo test           # Tests
   ```

   **Flutter/Dart:**
   ```bash
   dart format --set-exit-if-changed .   # Format check
   dart analyze                          # Lint
   flutter build                         # Build
   flutter test                          # Tests
   ```

4. **Run Quality Checkers** — At the end of every change, invoke all available quality checker agents to validate:
   - Code style compliance
   - Test coverage
   - Documentation completeness
   - Security considerations

## Workflow

```
Change Request
     │
     ▼
Delegate to Sub-Agents (when applicable)
     │
     ▼
Implement Changes (follow standards)
     │
     ▼
Build & Test (must pass)
     │
     ▼
Quality Checker Agents (must pass)
     │
     ▼
Complete
```
