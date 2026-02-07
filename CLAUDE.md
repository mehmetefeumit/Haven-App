# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Haven

Secure, privacy-first location sharing app using Marmot Protocol (MLS + Nostr) for E2E encrypted group messaging. Flutter frontend with Rust cryptographic core.

## Architecture

```
haven/                → Flutter app (UI, state management, platform bindings)
  lib/src/rust/       → Auto-generated FFI bindings (DO NOT EDIT)
  rust_builder/       → FFI wrapper crate exposing haven-core via flutter_rust_bridge
haven-core/           → Rust library (MLS operations, crypto, Nostr integration)
  src/circle/         → Circle management (groups, contacts, invitations)
  src/location/       → Location types, privacy, Nostr event encoding
  src/nostr/          → MLS manager, encryption, keys, event handling
scripts/              → Build and utility scripts
```

**FFI Flow**: `haven-core` exports types → `rust_builder/src/api.rs` wraps with `#[frb]` attributes → `flutter_rust_bridge_codegen` generates → `haven/lib/src/rust/` (Dart bindings)

**Why Dual-Crate**: Only `rust_builder` generates FFI symbols (avoids duplicate symbol errors). `haven-core` stays pure Rust for independent testing and reusability.

**FFI Wrapper Pattern**: Types exposed to Flutter use `*Ffi` suffix (e.g., `CircleFfi`, `ContactFfi`) wrapping core types. Opaque types use `#[frb(opaque)]`, sync methods use `#[frb(sync)]`.

**Flutter Service Layer**: Abstract service interfaces enable mocking for tests:
- `IdentityService` → `NostrIdentityService` (real) - wraps Rust identity manager
- `LocationService` → `GeolocatorLocationService` (real) - wraps platform location

**State Management**: Flutter app uses Riverpod for reactive state management:
- Service providers in `lib/src/providers/service_providers.dart` (singleton services)
- State providers in `lib/src/providers/identity_provider.dart` and `location_provider.dart`
- Pages use `ConsumerWidget` or `ConsumerStatefulWidget` to watch providers
- Test with `ProviderScope(overrides: [...])` to inject mocks

## Privacy Model

- **No public profiles**: User profiles (kind 0) are never published to relays
- **Local contacts**: Display names and avatars are stored only on the device
- **Pubkey-only identity**: Relays only see pubkeys, never usernames

This prevents relay-level correlation of usernames with invitation patterns.

## Commands

```bash
# Rust core
cd haven-core && cargo test                    # Run all tests
cd haven-core && cargo test test_name          # Run specific test
cd haven-core && cargo clippy -- -D warnings   # Lint (pedantic + nursery enabled)
cd haven-core && cargo fmt --check             # Check formatting
cd haven-core && cargo llvm-cov --open         # Coverage report (opens in browser)

# Flutter app
cd haven && flutter test                       # Run all tests
cd haven && flutter test test/path.dart        # Run specific test file
cd haven && flutter test integration_test/     # Integration tests (requires Rust bridge)
cd haven && flutter analyze                    # Analyze Dart code
cd haven && flutter run                        # Run app (debug)
cd haven && dart format .                      # Format code
cd haven && flutter build apk --release        # Build release APK

# FFI regeneration (after modifying rust_builder/src/api.rs)
./scripts/regenerate_frb.sh

# Combined coverage (both Rust + Flutter)
./scripts/coverage.sh
```

## Code Quality

- **Rust lints**: `clippy::pedantic` and `clippy::nursery` are enabled; `unsafe_code` is denied
- **Rust testing**: Uses `proptest` for property-based testing
- **Flutter lints**: Uses `very_good_analysis` for strict Dart linting
- **Coverage thresholds**: CI enforces 90% for Rust, 10% for Flutter (FRB-generated files excluded)

## Testing Requirements

**Before completing any code change:**

1. **All tests must pass**: Run `cargo test` (Rust) and `flutter test` (Flutter)
2. **Coverage must not regress**: New code requires corresponding tests
3. **Use test-writer agent**: For new features or bug fixes, invoke test-writer to ensure proper test coverage
4. **Security review for crypto**: Any code touching secrets, keys, or encryption must be reviewed by security-reviewer agent

**Widget tests with Rust FFI**: Flutter widgets that depend on Rust (e.g., IdentityPage) cannot be unit tested without the Rust bridge. Use integration tests in `integration_test/` for full widget testing, or refactor to accept services via constructor for mockability.

## Security Rules (CRITICAL)

Non-negotiable for this cryptographic application:

1. **Key Separation**: MLS signing keys MUST differ from Nostr identity keys
2. **Ephemeral Keys**: Generate NEW keypair for EACH group message (kind 445)
3. **Welcome Events**: Kind 444 MUST remain unsigned
4. **Group ID Privacy**: Only publish `nostr_group_id`, never real MLS group ID
5. **Secret Lifecycle**: Delete `exporter_secret` after ~2 epochs
6. **No Key Logging**: NEVER log, print, or expose key material
7. **Secure Memory**: Use `Zeroizing<T>` from the `zeroize` crate for secret bytes; structs holding secrets must derive `ZeroizeOnDrop`

**Database Encryption**: MLS state is stored in SQLCipher (encrypted SQLite). Keys are stored in system keyring (Keychain/GNOME Keyring/Credential Manager). See `haven-core/SECURITY.md` for details.

## Protocol Quick Reference

| Event Kind | Purpose | Notes |
|------------|---------|-------|
| 443 | KeyPackage | Published to relays |
| 444 | Welcome | Gift-wrapped, UNSIGNED |
| 445 | Group messages | Ephemeral pubkey per message |
| 10051 | KeyPackage relay list | User's inbox relays |
| 9 | Chat/location content | Inner application message |

## References

- **Protocol Specs**: https://github.com/marmot-protocol/marmot (MIP-00 through MIP-04)
- **MDK (Rust SDK)**: https://github.com/parres-hq/mdk
- **whitenoise-rs**: https://github.com/parres-hq/whitenoise (reference app)
- **Local Docs**: See `MARMOT_PROTOCOL_KNOWLEDGE.md` for consolidated protocol reference
- **Setup Guide**: See `haven/DEVELOPMENT.md` for environment setup

## Agents

Specialized agents auto-invoke for their domains. Do not skip security-reviewer for crypto code.

| Domain | Agent | Auto-triggers |
|--------|-------|---------------|
| Crypto, keys, MLS, auth | security-reviewer | Any code touching encryption or secrets |
| New features, bug fixes | test-writer | Write tests before implementation (TDD) |
| MIP specs, protocol compliance | marmot-expert | Marmot, MLS, Nostr integration questions |
| haven-core, Rust, FFI | rust-expert | Rust implementation tasks |
| haven app, Flutter, Dart | flutter-expert | Flutter implementation tasks |
| UI/UX, design, accessibility | ui-ux-reviewer | Flutter UI implementation, design reviews, accessibility checks, before releases |
| Vulnerabilities, outdated deps | dependency-auditor | Periodic audits, before releases |