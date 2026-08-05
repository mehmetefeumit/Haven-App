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

**FFI Wrapper Pattern**: Types exposed to Flutter use `*Ffi` suffix (e.g., `CircleFfi`, `ContactFfi`) wrapping core types. Opaque types use `#[frb(opaque)]`, sync methods use `#[frb(sync)]`. FFI does not expose Rust async streams; relay subscriptions use polling (manual refresh / app resume). Upgrading to `StreamSink` via `flutter_rust_bridge` is a known follow-up.

**nostr crate API**: `Filter::pubkey()` filters by `#p` tag (recipient), **not** event author. Use `Filter::author()` for the event author field.

**Flutter Service Layer**: Abstract service interfaces enable mocking for tests:
- `IdentityService` → `NostrIdentityService` (real) - wraps Rust identity manager
- `LocationService` → `GeolocatorLocationService` (real) - wraps platform location
- `CircleService` → `NostrCircleService` (real) - MLS group + circle metadata
- `RelayService` → `NostrRelayService` (real) - Nostr relay connections
- `LocationSharingService` - encrypt-publish-fetch-decrypt pipeline

**State Management**: Flutter app uses Riverpod for reactive state management:
- Service providers in `lib/src/providers/service_providers.dart` (singleton services)
- State providers in `lib/src/providers/identity_provider.dart` and `location_provider.dart`
- Pages use `ConsumerWidget` or `ConsumerStatefulWidget` to watch providers
- Test with `ProviderScope(overrides: [...])` to inject mocks
- After state mutations, call `ref.invalidate(provider)` to propagate updates

**Identity Loading Sequence**: On startup, `NostrIdentityService._ensureInitialized()` loads secret bytes from Flutter secure storage → calls Rust `NostrIdentityManager.load_from_bytes()` → stores in `InMemoryStorage` (RwLock<HashMap>, zeroizes displaced values). If storage read fails, app continues with no identity.

## Privacy Model

- **Public profiles by default**: Saving a display name or photo publishes a public kind-0 profile (name/picture) + a Blossom-hosted photo immediately — publishing is **unconditional** (no consent toggle). That a saved profile is public on the Nostr network is disclosed to the user in onboarding and on the Identity settings page.
- **Local contacts**: Petnames (local display-name overrides) are still stored only on the device
- **Anonymous pseudonym on account creation (owner-directed 2026-07-18)**: Onboarding pre-fills the display-name field with a random anonymous "Adjective Archetype" name (e.g. "Quiet Wanderer"; generator in `haven/lib/src/utils/anonymous_name_generator.dart`) and publishes it as a public kind-0 profile when the user taps "Create My Identity" — matching White Noise. There is **no "skip / stay pubkey-only" step in onboarding**; every new install publishes a *pseudonymous* profile (the anonymous name reveals no real-world identity, and the user can rename it in the same field or later on the Identity page). Relays therefore see an anonymous pseudonym, not a bare pubkey, from account creation. Do NOT reintroduce a skip/pubkey-only onboarding path treating this as a regression.

**Rule-10 exception (owner-directed, recorded 2026-07-12; made public-by-default 2026-07-16)**: the public Nostr profile module (kind 0 + Blossom — `haven-core/src/profile/`, plan in `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md`) deliberately reverses the no-public-profiles posture at the owner's explicit direction, matching the White Noise reference app. Do NOT treat it as a privacy regression to revert. Its remaining boundaries — anti-SSRF download filter, EXIF/GPS strip before upload, identity-key-only signing (key separation), no group IDs in profile paths, HTTPS-only Blossom, and the retraction no-op gate — are CI-enforced by `scripts/ci/check_profile_privacy_boundaries.sh`.

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
cd haven && flutter run                        # Run app (debug; map shows error tiles, no key)
cd haven && dart format .                      # Format code

# Release builds MUST use the wrapper (NOT bare `flutter build --release`, which
# the Gradle/Xcode release gate fails). It injects the Stadia Maps API key from
# the gitignored haven/dart_defines/secrets.json (--dart-define-from-file),
# forces --obfuscate --split-debug-info, and runs the no-committed-secrets guard.
# See haven/DEVELOPMENT.md ("Build APK"). The leak-guard
# (scripts/ci/check_no_committed_secrets.sh) runs automatically on every release
# build and in CI; it fails if a Stadia key (UUID) is ever committed.
scripts/build_release.sh apk                    # Release APK (also: appbundle | ios)

# FFI regeneration (after modifying rust_builder/src/api.rs)
# Regenerates frb_generated.rs (Rust) AND haven/lib/src/rust/*.dart (Dart)
# Then run: cargo fmt, dart format, and tests
./scripts/regenerate_frb.sh

# Coverage. ONE gate; the local script runs every check coverage.yml does
# (both aggregates, the per-path floors, the undeclared-skip gate and the
# rollback-path flag-off run), so green locally means green in CI.
scripts/ci/check_coverage.sh --static-only   # < 1 s: manifest pin rule + guard self-tests
scripts/ci/check_coverage.sh                 # full gate, both stacks in parallel (~6-11 min)
./scripts/coverage.sh                        # same gate + HTML reports
scripts/ci/install_git_hooks.sh              # once per clone: pre-commit (static) + pre-push (full)

# Per-path coverage floors: NEVER hand-edit scripts/ci/coverage_floors.txt.
# Every floor must equal floor(measured) - 2 (or exactly 100), enforced by --lint.
scripts/ci/check_coverage_floors.sh --lint [--fix]
scripts/ci/check_coverage_floors.sh --repin <rust|flutter> <lcov>   # raises only, never lowers
```

**Coverage toolchains are pinned** in `scripts/ci/coverage_toolchain.env` (rustc
+ Flutter), because a coverage percentage is a ratio whose denominator is
instrumented lines — a compiler property, not a test property. Every other
workflow keeps floating on `stable`. Bump the pin and re-pin the floors in ONE
commit.

## Code Quality

- **Rust lints**: `clippy::pedantic` and `clippy::nursery` are enabled; `unsafe_code` is denied
- **Rust testing**: Uses `proptest` for property-based testing
- **Flutter lints**: Uses `very_good_analysis` for strict Dart linting
- **Coverage thresholds**: CI enforces 80% for Rust, 50% for Flutter (FRB-generated files excluded)
- **FFI error handling**: Use `on Object catch (e)` at FFI call sites — catches both `Exception` and `Error` from the FFI boundary while satisfying `avoid_catches_without_on_clauses` lint
- **FFI error convention**: Rust FFI methods return `Result<T, String>` at the boundary; custom `Debug` impls on error types redact MLS group IDs and secret material
- **MDK pinning**: `haven-core` pins the five MDK "Dark Matter" crates (`cgka-session`, `cgka-engine`, `cgka-traits`, `storage-sqlite`, `transport-nostr-peeler`) to the v0.9.4 release rev; bump only to released tags, never `master`
- **SQLCipher on Android**: Uses `bundled-sqlcipher-vendored-openssl` because Android NDK lacks OpenSSL headers; `libsqlite3-sys` version must match `storage-sqlite`'s `rusqlite` version

## Coding Requirements
- Always use sub-agents and make sure to get the most recent information through the references online and MCPs which are avaiable to the agents.
- After the implementation of a feature is complete, start a separate set of agents to quality check and confirm the implementation before considering is complete.
- When doing a plan, ALWAYS use the sub-agents which are experts in the protocol and programming language to create the first draft of the plan. After the first draft is complete, start another, independent set of expert agents to confirm the plan based on their knowledge of the protocol and programming language, before finally presenting it to me.

## Testing Requirements

**Before completing any code change:**

1. **All tests must pass**: Run `cargo test` (Rust) and `flutter test` (Flutter)
2. **Coverage must not regress**: New code requires corresponding tests
3. **Use test-writer agent**: For new features or bug fixes, invoke test-writer to ensure proper test coverage
4. **Security review for crypto**: Any code touching secrets, keys, or encryption must be reviewed by security-reviewer agent
5. **Never lower the quality of a test**: If a change makes a previously succeeding test fail, never reduce the quality or coverage of the test to accomodate for the change, unless it is technically impossible for the current change and the failing test to co-exist.

**Widget tests with Rust FFI**: Flutter widgets that depend on Rust (e.g., IdentityPage) cannot be unit tested without the Rust bridge. Use integration tests in `integration_test/` for full widget testing, or refactor to accept services via constructor for mockability.

## Localization (l10n)

The Flutter app uses official `gen-l10n` + ARB (`haven/lib/l10n/`, template `app_en.arb`). See `haven/lib/l10n/README.md` for the workflow.

**Every language addition MUST be checked by BOTH:**

1. **AI agents** — multiple agents translate (one per language) and a **separate, independent reviewer agent** confirms each language for *correctness, readability, accessibility, and proper, natural use of the language* (idiomatic register, grammar/agreement, plural forms, RTL where applicable, screen-reader friendliness). A single machine pass is never sufficient.
2. **Programmatic tools** — run `scripts/ci/arb_parity_check.dart` (key/placeholder/empty/CLDR-plural-category parity) and `flutter gen-l10n` (must be warning-free). The CI gate is `.github/workflows/l10n-check.yml`; the advisory AI review is `l10n-ai-review.yml`.

**Readability and accessibility outrank word-for-word parity.** Exact parity with English must NEVER come at the cost of how the text reads in the native language. Where a language's features require it (gender agreement, plural categories, word order, script/RTL, honorifics, cognates that are legitimately identical to English), deviating from literal parity is expected and accepted. The parity tool reflects this: structural checks (keys, placeholders, plural categories) hard-fail; the "identical to English" check is only a non-failing warning, because cognates are valid.

## Security Rules (CRITICAL)

Non-negotiable for this cryptographic application:

1. **Key Separation**: MLS signing keys MUST differ from Nostr identity keys
2. **Ephemeral Keys**: Generate NEW keypair for EACH group message (kind 445)
3. **Welcome Events**: Kind 444 MUST remain unsigned
4. **Group ID Privacy**: Only publish `nostr_group_id`, never real MLS group ID
5. **Secret Lifecycle**: Old `exporter_secret`s age out of the engine's retention window (`DEFAULT_MAX_PAST_EPOCHS` = 5 past epochs; Haven does not override it) and are pruned automatically — never retain secrets beyond what's needed to decrypt in-flight messages
6. **No Key Logging**: NEVER log, print, or expose key material
7. **Secure Memory**: Use `Zeroizing<T>` from the `zeroize` crate for secret bytes; structs holding secrets must derive `ZeroizeOnDrop`
8. **No Raw Errors in UI**: Never display `$e` or `e.message` to users — could leak MLS group IDs or internal state. Use `debugPrint` for details, generic messages for UI
9. **Dart Secret Lifetime**: Dart has no `zeroize`; minimize exposure by re-fetching secret bytes per use rather than holding long-lived references
10. **User privacy comes first**: Never make changes which reduce the user privacy and security unless the prompt explicitly tells you to.
11. **Nonce Uniqueness / No Label Downgrade**: The kind-445 ChaCha20-Poly1305 nonce MUST be CSPRNG-random (12 bytes) and MUST NEVER repeat under a fixed epoch `group_event_key`; NEVER call the peeler's `with_exporter_label` override — it is the only local lever that can downgrade the kind-445 exporter derivation (CI-guarded by `scripts/ci/check_no_exporter_label_override.sh`)
12. **Convergence-Buffer Backpressure**: Rate-limit convergence-buffer ingest with backpressure; NEVER silently drop legitimate offline backlog (future-epoch catch-up is legitimate). Caveat: the engine's stored buffer has no per-group cap and no eviction API (upstream #757 OPEN), so a Haven-side intake cap throttles but does not bound engine storage
13. **Publish-Before-Apply**: NEVER call `confirm_published` before at least one relay has returned an OK-ack ("acked" means acked, never merely "sent"); call `publish_failed` on failure; treat `PendingCommitRecovered` as a mandatory resync
14. **Single Session**: Run exactly ONE live `AccountDeviceSession` per MLS DB file across all isolates/processes — a second session diverges in-memory epoch state and risks epoch/exporter-key reuse, i.e. a confidentiality loss, not just DB corruption

**Database Encryption**: MLS state is stored in SQLCipher (encrypted SQLite). Keys are stored in system keyring (Keychain/GNOME Keyring/Credential Manager). See `haven-core/SECURITY.md` for details.

**Platform Keyring Crates** (compiled per target OS):
- macOS/iOS: `apple-native-keyring-store`
- Linux: `zbus-secret-service-keyring-store` (requires D-Bus Secret Service provider: GNOME Keyring, KDE Wallet, or KeePassXC)
- Windows: `windows-native-keyring-store`
- Android: `android-native-keyring-store`

## Protocol Quick Reference

| Event Kind | Purpose | Notes |
|------------|---------|-------|
| 0 | Public profile metadata (NIP-01/24) | Public-by-default (published on save, no consent gate); signed by identity key |
| 30443 | KeyPackage (addressable) | `d` = stable slot; published to and fetched from the account's NIP-65 (kind 10002) relays |
| 444 | Welcome | Gift-wrapped, UNSIGNED |
| 445 | Group messages | Outer ChaCha20-Poly1305 layer keyed by MLS-Exporter `"marmot/group-event"`; ephemeral pubkey per message. Tags are `h` only for commits/proposals, `h` + NIP-40 `expiration` (= `created_at` + 228s, from group component 0x8005) for application messages — **no other tag is permitted** |
| 450 | Account identity proof | Canonical event embedded in the MLS leaf extension 0xF2F1; signed by identity key; NOT published to relays by Haven |
| 1059 | Gift Wrap (NIP-59) | 3-layer encrypted welcome delivery |
| 10002 | NIP-65 relay list | KeyPackage discovery (replaces the retired kind 10051) |
| 10050 | NIP-17 inbox relays | Gift-wrap (1059) delivery |
| 10063 | Blossom server list (BUD-03) | Not published in v1 |
| 24242 | Blossom authorization (BUD-01/02) | HTTP `Authorization` header only — NEVER published to a relay |
| 9 | Chat/location content | Inner application message |

## CI Pipeline

Reusable workflows in `.github/workflows/`; **ci.yml** is the PR/push orchestrator (one job per concern, five stages):
- **Stage 1 — code quality**: `rust-check.yml` (fmt + clippy + tests + release-mode build, both crates), `flutter-check.yml` (`flutter analyze --no-fatal-infos` — errors/warnings gate, pre-existing infos advisory), `cross-check.yml` (`cargo check --target` for macOS/iOS/Windows/Android; validates platform-gated `#[cfg]` code), `coverage.yml` (80% Rust / 50% Flutter thresholds), `audit.yml` (cargo-audit; also weekly)
- **Stage 2 — repo guards**: `repo-guards.yml` — ALL fast grep/bash invariants in ONE job (committed secrets, tile-provider policy, public-profile privacy boundaries, INTERNET permission, background-wake invariants, locale privacy, exporter-label override ban, MDK supply-chain shape, E2E publish-before-apply, E2E-harness self-tests). Every guard step runs even if an earlier one failed, so one red run reports all violations. Add new pure-grep guards HERE as steps, not as new workflows.
- **Stage 3 — localization**: `l10n-check.yml` (gen-l10n regeneration + cross-locale ARB parity)
- **Stage 4 — E2E lanes** (all parallel, each `needs: [rust]` only): core flow on Android + iOS, each in poll AND live-sync variants (`e2e-android.yml` / `e2e-ios.yml` via the `live_sync` input), `e2e-integration.yml` (component integration tests), `e2e-relay-customization.yml` (two-relay proof), `e2e-background-catchup.yml` (WorkManager runtime proof incl. guest reboot), `e2e-profile.yml` (kind-0 + Blossom, Android + iOS)
- **Stage 5 — build verification**: `build-check.yml` — Android debug APK per ABI (separate runners avoid disk exhaustion) + iOS no-codesign build; `needs: [rust, coverage, guards]`
- Standalone: `e2e-nightly.yml` + `e2e-flakiness-stress.yml` (nightly), `e2e-flakiness.yml` (weekly report), `e2e-live-sync.yml` (manual), `release-build.yml` (tags `v*`; gate = rust-check + cross-check + coverage + repo-guards), `ios-certificates.yml` (manual)
- Concurrency groups cancel in-progress runs on new pushes to the same branch

## References

- **Protocol Specs**: https://github.com/marmot-protocol/marmot (MIP-00 through MIP-04)
- **MDK (Rust SDK)**: https://github.com/marmot-protocol/mdk
- **whitenoise-rs**: https://github.com/parres-hq/whitenoise (reference app)
- **Local Docs**: See `MARMOT_PROTOCOL_KNOWLEDGE.md` for consolidated protocol reference
- **Setup Guide**: See `haven/DEVELOPMENT.md` for environment setup
- **FFI Architecture**: See `docs/FLUTTER_RUST_BRIDGE.md` for dual-crate design and FRB troubleshooting
- **Security Tracking**: See `haven-core/SECURITY.md` for known CVEs and keyring setup
- **DI Testing Patterns**: See `haven/test/services/DEPENDENCY_INJECTION_EXAMPLES.md`

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