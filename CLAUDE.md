# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: Haven

Secure, privacy-first location sharing app using Marmot Protocol (MLS + Nostr) for E2E encrypted group messaging. Flutter frontend with Rust cryptographic core.

## Non-Negotiables (READ FIRST)

These pillars are never traded off, never "temporarily" degraded, and never
deferred to a follow-up:

**privacy · security · log anonymity · performance · user experience ·
documentation accuracy (user-visible AND internal) · accessibility · code
quality · simplicity · test coverage · test reliability**

### Log anonymity (owner-directed 2026-09-10)

Nothing that could identify a user, or tell one user, circle or device apart
from another, may ever reach a log, a panic message, a `Debug`/`Display`
rendering or an FFI error string — in any build, at any log level, in any
encoding, at any truncation. That means: no keys (Rule 6), no pubkeys or npubs,
no MLS or Nostr group ids, no event ids or KeyPackage slots, no subscription
ids, **no relay URLs (the default pool included)**, no hosts or IP addresses, no
circle/display names or petnames, no coordinates or geohashes, no absolute epoch
numbers, no exact counts of circles/members/relays/events, no absolute
timestamps on publish/receive paths, and no remote-authored prose. "Redacted"
means **absent**, never a visible prefix. Where a line must say "the same
circle/peer/relay as that other line" it uses a per-process salted handle from
`haven-core/src/log_alias.rs` (`circle#a91f3c`), which cannot be computed or
reversed without the process salt; magnitudes are bucketed, instants are
relative. This is enforced on independent CI dimensions (source guards in all
four languages, the `Debug`/`Display` enumeration test, in-process log capture
in unit tests, the runtime canary scanner over every lane's sinks before upload,
mutation tests of the scanner, the privacy manifest) and is **Security Rule 15**
below. A test that plants an identifier and asserts it is absent from captured
logs is the required proof for any new log line.

A change that improves one pillar by weakening another is not finished. If you
believe a pillar genuinely must give, STOP and ask — do not decide it silently.

### Simple and correct, not clever and verbose

- Write the **smallest correct implementation**. No speculative abstraction, no
  configuration nobody asked for, no defensive branches for states that cannot
  occur. Precision beats breadth: doing less, exactly right, beats doing more,
  subtly wrong.
- **Comment WHY, never what.** A comment restating the code is noise — delete
  it. Reserve prose for a non-obvious invariant, a spec/protocol constraint, or
  a trap that will otherwise be re-introduced. One tight sentence beats a
  paragraph.
- Match the surrounding file's density, naming and idiom. Do not raise or lower
  the local comment level.
- Prefer deleting code to adding it. Fewer moving parts is a correctness
  argument, not a style preference.

### Finish the work — no stubs, ever

**NEVER** leave a `TODO`, a placeholder, an empty function body, a skipped test,
or a test whose outer interface exists with the assertions "to be filled in".
Writing a test scaffold and deferring its body is prohibited — a test that
asserts nothing is worse than no test, because it reports coverage it does not
have. Every change lands complete, to the highest quality achievable. If some
part genuinely cannot be completed, say so explicitly in your response; never
hide it in the code.

### Everything promised is tested

Every promise the app makes must have a test that FAILS when the promise breaks:
user-facing privacy and security guarantees, what does and does not leave the
device, what appears in logs and diagnostics, every functional scenario,
performance/battery characteristics, accessibility affordances, and the accuracy
of user-visible copy. An untested guarantee is an aspiration, not a guarantee.

### Tests must be reliable, and are never weakened

- Assert **behaviour**, not implementation details or incidental strings.
- No sleeps, no timing races, no dependence on test ordering or on wall-clock
  chance. Injectable clocks and deterministic ordering over "usually fast
  enough".
- A flaky test is a broken test: fix the race the test found, never loosen the
  assertion, shorten the scope, or add a retry to hide it.
- If a change makes a passing test fail, the change is suspect first. Never
  lower a test's quality or coverage to accommodate it (see Testing
  Requirements).

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
tooling/soak/         → `haven-soak`: hermetic core soak rig (N real engines + in-process relays behind a fault layer; test-utils only, never shipped)
tooling/logscan/      → `haven-logscan`: the runtime log-privacy scanner every CI log sink passes through before upload
```

**FFI Flow**: `haven-core` exports types → `rust_builder/src/api.rs` wraps with `#[frb]` attributes → `flutter_rust_bridge_codegen` generates → `haven/lib/src/rust/` (Dart bindings)

**Why Dual-Crate**: Only `rust_builder` generates FFI symbols (avoids duplicate symbol errors). `haven-core` stays pure Rust for independent testing and reusability.

**FFI Wrapper Pattern**: Types exposed to Flutter use `*Ffi` suffix (e.g., `CircleFfi`, `ContactFfi`) wrapping core types. Opaque types use `#[frb(opaque)]`, sync methods use `#[frb(sync)]`. FFI does not expose Rust async streams; relay subscriptions use polling (manual refresh / app resume). Upgrading to `StreamSink` via `flutter_rust_bridge` is a known follow-up.

**nostr crate API**: `Filter::pubkey()` filters by `#p` tag (recipient), **not** event author. Use `Filter::author()` for the event author field.

**Relay clients**: `RelayManager::new()` and the live-sync engine client are both built by `relay::verified::verified_client`; nothing else in shipped code builds one. MDK's relay client (`NostrSdkRelayClient`) builds no client: `RelayManager::fanout_transport` hands it the publish client, once per manager, and nothing else may. NIP-77 runs only as Haven's own dry-run NEG on a publish pool (`RelayManager::neg_remote_ids`, `check_publish_client_no_subscription.sh` check 5): it advertises no id the device holds (the opening message is the empty set), fetches by id, with the circle's `#h`, only from the relay that reported each id, and runs inside a burst, a live foreground entry or a catch-up sweep, at most four routes per ten seconds; MDK's `reconcile_subscription` is never called.

**Relay URLs**: one scheme policy on the PARSED URL, `relay::url_norm::may_dial` (`wss` to any host; a debug build's loopback `ws` opt-in, compiled out of a release, is the one exception) — the publish/fetch validator, the live-sync engine gate, both normalisers and the kind-10002/10050 builders call it. Every relay another client chose, and every relay Haven names to other members, also needs a public host: the foreign-list filter, the derivation of a circle's own relay list, the fanout's frozen targets and the routing-component write (`circle_relays`, `routing_of`) call `relay::manager::foreign_relay_dialable`, which decides the scheme by `may_dial` and then refuses a loopback name or a non-public IP literal (MDK's `is_loopback_host` / `is_public_ip`; a domain is taken unresolved, so one resolving to a private address is the residual, tracker `T-GROUP-RELAY-HOSTS`). Never test a raw relay string's prefix. A routing entry another client wrote that fails it is dropped from the circle's list — the entry, never the list or the component (`circle::manager::usable_relays`); when every entry fails, the list is empty. Haven never writes one: a relay list the user named that holds one is refused, in fixed text that names no relay; a create whose caller named no relays draws `min(3, n)` at random (`OsRng`) from the location pool (`circle::location_pool::pick_circle_relays`), leaves out such an entry and every relay on the account's own identity lists, and is refused (`CircleError::NoLocationRelay`) only when none is left.

**Flutter Service Layer**: Abstract service interfaces enable mocking for tests:
- `IdentityService` → `NostrIdentityService` (real) - wraps Rust identity manager
- `LocationService` → `GeolocatorLocationService` (real) - wraps platform location; one stream owner per platform (Android: geolocator; iOS: the native `HavenLocationStreamHandler` behind `IosLocationSource`. One-shots stay on geolocator on both)
- `CircleService` → `NostrCircleService` (real) - MLS group + circle metadata; every change (invite, removal, relay change, hand-over, repair, leave) is one Rust-owned driven call (`CircleChangeDriver` → `RelayManagerFfi::*_driven`) that stages, sends and confirms in Rust and returns a typed outcome — Dart never holds a staged commit; what holds a circle is read, never re-derived, through `circleRecovery` (`RelayManagerFfi::circle_recovery`, 13 typed causes, worst first), which Circle details shows as the circle's one sharing card, and a halted circle is MDK's persisted `CircleEngineState.unrecoverable`, with no session latch in Dart
- `RelayService` → `NostrRelayService` (real) - Nostr relay connections
- `LocationSharingService` - seal-publish-fetch-decrypt pipeline through the driver's `seal_location_driven` / `publish_location_driven`; a deferral is a typed `SendHeldFfi`

**State Management**: Flutter app uses Riverpod for reactive state management:
- Service providers in `lib/src/providers/service_providers.dart` (singleton services)
- State providers in `lib/src/providers/identity_provider.dart` and `location_provider.dart`
- Pages use `ConsumerWidget` or `ConsumerStatefulWidget` to watch providers
- Test with `ProviderScope(overrides: [...])` to inject mocks
- After state mutations, call `ref.invalidate(provider)` to propagate updates

**Identity Loading Sequence**: On startup, `NostrIdentityService._ensureInitialized()` loads secret bytes from Flutter secure storage → calls Rust `NostrIdentityManager.load_from_bytes()` → stores in `InMemoryStorage` (RwLock<HashMap>, zeroizes displaced values). If storage read fails, app continues with no identity.

## Privacy Model

- **Public profiles by default**: Saving a display name or photo publishes a public kind-0 profile (name/picture) + a Blossom-hosted photo immediately — publishing is **unconditional** (no consent toggle). That a saved profile is public on the Nostr network is disclosed to the user in onboarding and on the Identity settings page. Saving or removing a name or photo is local and instant. Rust publishes it from the durable outbox to every profile-pool relay in the background, and re-sends the same signed event only to a relay that does not yet serve it (`docs/PROFILE_LOCAL_FIRST_SYNC.md`).
- **Local contacts**: Petnames (local display-name overrides) are still stored only on the device
- **Four relay planes, four lists** (`haven-core/SECURITY.md` "Relay planes"): account (the user's Inbox/KeyPackage lists, seeded from `PRODUCTION_DEFAULT_RELAYS`), read-only discovery (`PRODUCTION_DISCOVERY_RELAYS`), profile (`PRODUCTION_PROFILE_RELAYS`, kind 0) and location (`PRODUCTION_LOCATION_RELAYS`, the kind 445 of circles Haven creates: up to 3 at random per circle, never a relay on the creator's own lists); the profile and location pools share no host with any other built-in list, and circles created before 2026-10-31 or by other clients keep their relays
- **Anonymous pseudonym on account creation (owner-directed 2026-07-18)**: Onboarding pre-fills the display-name field with a random anonymous "Adjective Archetype" name (e.g. "Quiet Wanderer"; generator in `haven/lib/src/utils/anonymous_name_generator.dart`) and publishes it as a public kind-0 profile when the user taps "Create My Identity" — matching White Noise. There is **no "skip / stay pubkey-only" step in onboarding**; every new install publishes a *pseudonymous* profile (the anonymous name reveals no real-world identity, and the user can rename it in the same field or later on the Identity page). Relays therefore see an anonymous pseudonym, not a bare pubkey, from account creation. Do NOT reintroduce a skip/pubkey-only onboarding path treating this as a regression.

**Rule-10 exception (owner-directed, recorded 2026-07-12; made public-by-default 2026-07-16)**: the public Nostr profile module (kind 0 + Blossom — `haven-core/src/profile/`, plan in `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md`) deliberately reverses the no-public-profiles posture at the owner's explicit direction, matching the White Noise reference app. Do NOT treat it as a privacy regression to revert. Its remaining boundaries — anti-SSRF download filter, EXIF/GPS strip before upload, identity-key-only signing (key separation), no group IDs in profile paths, HTTPS-only Blossom, and the retraction no-op gate — are CI-enforced by `scripts/ci/check_profile_privacy_boundaries.sh`.

## Commands

```bash
# Rust core
cd haven-core && cargo test                    # Run all tests
cd haven-core && cargo test test_name          # Run specific test
cd haven-core && cargo clippy --all-targets -- -D warnings   # Lint (pedantic + nursery). --all-targets as CI does; bare clippy skips tests
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
scripts/ci/check_coverage.sh                 # full gate, both stacks in parallel (≈ 31 min, measured 2026-11-02 with --sequential)
./scripts/coverage.sh                        # same gate + HTML reports
scripts/ci/install_git_hooks.sh              # once per clone: pre-commit (static). No push hook — run the full gate on demand.

# Per-path coverage floors: NEVER hand-edit scripts/ci/coverage_floors.txt.
# Every floor must equal floor(measured) - 2 (or exactly 100), enforced by --lint.
scripts/ci/check_coverage_floors.sh --lint [--fix]
scripts/ci/check_coverage_floors.sh --repin <rust|flutter> <lcov>   # raises only, never lowers
# Floor rows for deleted paths are removed only with --drop-stale, never by hand.
scripts/ci/check_coverage_floors.sh --drop-stale                    # refuses while any floor is below HEAD's
```

**Coverage toolchains are pinned** in `scripts/ci/coverage_toolchain.env` (rustc
+ Flutter + cargo-llvm-cov), because a coverage percentage is a ratio whose
denominator is instrumented lines — a compiler property, not a test property —
and cargo-llvm-cov decides which files are counted and how the ratio is
rendered. Every other workflow keeps floating on `stable`. Bump the pin and
re-pin the floors in ONE commit.

## Code Quality

See **Non-Negotiables** above — simplicity and correctness outrank every other
consideration here, and comment volume is a cost, not a virtue.

- **Rust lints**: `clippy::pedantic` and `clippy::nursery` are enabled; `unsafe_code` is denied
- **Rust testing**: Uses `proptest` for property-based testing
- **Flutter lints**: Uses `very_good_analysis` for strict Dart linting
- **Coverage thresholds**: CI enforces 80% for Rust, 50% for Flutter (FRB-generated files excluded)
- **FFI error handling**: Use `on Object catch (e)` at FFI call sites — catches both `Exception` and `Error` from the FFI boundary while satisfying `avoid_catches_without_on_clauses` lint
- **FFI error convention**: Rust FFI methods return `Result<T, String>` at the boundary; custom `Debug` impls on error types redact MLS group IDs and secret material. Outcomes the UI must distinguish cross as typed outcome structs, never as an `Err(String)` the caller inspects
- **MDK pinning**: `haven-core` pins the MDK crates `cgka-session`, `cgka-engine`, `cgka-traits`, `storage-sqlite`, `transport-nostr-peeler` and `transport-nostr-adapter` (feature `sdk` and no other — `check_mdk_supply_chain.sh` holds its lockfile dependency set in all three roots and, with `--adapter-features` in `rust-check.yml`, its feature set per root; it supplies the KeyPackage event template and `NostrSdkRelayClient`, MDK's relay client, which `RelayManager::fanout_transport` builds once per manager over Haven's own publish client for a classified one-relay publish; its subscription plane is never called, `check_publish_client_no_subscription.sh`) to the v0.10.4 release rev `fcc85edd…`; bump only to released tags, never `master`. That rev, the OpenMLS fork rev MDK requires (`erskingardner/openmls@59e7d3b…`) and the SQLCipher source (`rusqlite@5ae7fdf…`, SQLCipher 4.17, tracked exception) live in `scripts/ci/mdk_pins.env`; `check_mdk_supply_chain.sh` and `check_lockfile_universe.sh` hold `haven-core`, `haven/rust_builder` and `tooling/soak` to exactly those sources, and CI resolves every root `--locked`. `marmot-account`, `marmot-app` and `marmot-uniffi` are forbidden; `marmot-forensics` is a required dependency of `cgka-session` and `cgka-engine`, and its recorder is never installed (`check_no_forensic_recorder.sh`)
- **`test-utils`** also builds `relay::scripted_relay`, the loopback relay the forged-event tests script, and pulls `tokio-tungstenite` for it; `relay::recording_front`, a loopback address that records every frame a client sends to the in-process relay behind it, and `relay::dial_witness`, which the Rule-16 admission policy notes every relay dial into while a test watches — admitting it exactly as the trait's default does — for the relay-plane proof; and `relay::fanout::RelayMappedFanout`, the product fanout transport behind an address map, for the soak rig; a build with the feature and without debug assertions is a compile error
- **SQLite first use**: every direct SQLite open — `rusqlite::Connection::open*`, `open*` / `in_memory*` on `SqliteAccountStorage`, `SqliteStorage` or `SqliteSharedStorage`, and `AccountDeviceSession::open*`, called or merely named, tests included — sits in a function that calls `haven_core::sqlcipher_init::ensure()` earlier in that function. SQLCipher finishes its start-up after SQLite has told other threads the library is ready, so a store keyed on another thread at process start can fail to open (`docs/MDK_UPSTREAM_TRACKER.md` T-SQLCIPHER-FIRST-USE). Call-site presence is held lexically by `scripts/ci/check_sqlcipher_first_use_gate.sh`; `haven-core/tests/sqlcipher_first_use_gate.rs` runs each store opener it lists in a process of its own and fails if the gate has not run by the time the open returns — `CircleStorage::migrate_to_encrypted`'s own call, and any opener missing from that list, are held by the guard alone; no test reproduces the race itself
- **SQLCipher on Android**: Uses `bundled-sqlcipher-vendored-openssl` because the Android NDK lacks OpenSSL headers. `haven-core` pins `rusqlite = "=0.40.1"` and `libsqlite3-sys = "=0.38.1"`, and every Cargo root that builds haven-core (`haven-core`, `haven/rust_builder`, `tooling/soak`) carries `[patch.crates-io] libsqlite3-sys = { git = rusqlite, rev = 5ae7fdf }`: the patch is not inherited through a path or git dependency and is silently ignored without the exact pins. Local builds need rustc ≥ 1.97.1 (`cfg_select!`), declared as `rust-version` in the five Cargo roots CI lints so Clippy never suggests an API the coverage pin cannot build

## Coding Requirements
- Always use sub-agents and make sure to get the most recent information through the references online and MCPs which are avaiable to the agents.
- After the implementation of a feature is complete, start a separate set of agents to quality check and confirm the implementation before considering is complete.
- When doing a plan, ALWAYS use the sub-agents which are experts in the protocol and programming language to create the first draft of the plan. After the first draft is complete, start another, independent set of expert agents to confirm the plan based on their knowledge of the protocol and programming language, before finally presenting it to me.

### Reviewing: critical, never nitpicking (owner-directed 2026-10-18)

A review exists to catch what breaks, not to polish. Every reviewer and plan
confirmer follows this:

- **Never miss a breaking issue.** Read the changed paths in full and follow them
  to their callers; a missed break of a Non-Negotiable, a Security Rule, a
  user-facing promise, data integrity or protocol correctness is the review's
  failure.
- **Blocker / HIGH only for a concrete, reachable defect**: name the scenario
  (inputs, state, who triggers it) and the harm. If you cannot name one, it is
  not a blocker. Chance-rare is not adversary-rare: anything a malicious relay,
  peer or crafted event can trigger is reachable by definition.
- **Not blockers**: style, naming, comment or doc wording that is not false,
  equivalent rewrites, states the code cannot reach, edge cases needing an
  improbable chain of independent failures, and "could also test X" where the
  promise is already proved. List them as one-line LOW/advisory items, or omit
  them; they never justify another review round on their own.
- **Confirm before raising**: re-read the code and cite `file:line`; an
  unconfirmed suspicion is not a finding.
- **One pass, ranked**: report everything at once, most severe first. A
  re-review checks the fixes and what they touch, not the whole change again.
- **No review spiral** (owner-directed 2026-10-22): raise only truly important
  issues. Never re-raise an item already triaged or decided. A defect that
  predates the change, and that the change does not make reachable or worse, is
  reported once as pre-existing and never blocks it. A re-review raises only a
  fix that does not fix, or a blocker the fix itself introduced.

## Testing Requirements

**Before completing any code change:**

1. **All tests must pass**: Run `cargo test` (Rust) and `flutter test` (Flutter)
2. **Coverage must not regress**: New code requires corresponding tests
3. **Use test-writer agent**: For new features or bug fixes, invoke test-writer to ensure proper test coverage
4. **Security review for crypto**: Any code touching secrets, keys, or encryption must be reviewed by security-reviewer agent
5. **Never lower the quality of a test**: If a change makes a previously succeeding test fail, never reduce the quality or coverage of the test to accomodate for the change, unless it is technically impossible for the current change and the failing test to co-exist.
6. **No stubbed tests**: never commit a test whose body is a `TODO`, whose assertions are deferred, or which is skipped. A test that asserts nothing reports coverage it does not have.
7. **Test the promise, not the code path**: every privacy, security, log-privacy, performance, accessibility and functional guarantee gets a test that fails when the guarantee breaks.
8. **No flaky tests**: no sleeps, no timing races, no order dependence. Fix the race the test caught; never add a retry or loosen an assertion to make it pass.

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
4. **Group ID Privacy**: Only publish `nostr_group_id`, never the real MLS group ID; every (re)created circle gets a fresh random `nostr_group_id`
5. **Secret Lifecycle**: Old `exporter_secret`s age out of the engine's retention window (`DEFAULT_MAX_PAST_EPOCHS` = `V1_APP_MESSAGE_PAST_EPOCH_LIMIT` = 5 past epochs, pinned by convergence policy v1; Haven does not override it) and are pruned automatically; fork-recovery snapshots and own-commit checkpoints are bounded by convergence policy v1 `max_rewind_commits` = 5; a superseded KeyPackage's private material is deleted when a relay acknowledges its replacement, or at the first maintenance tick at or after its `not_after`, whichever comes first; a consumed one is owed a replacement from the next tick, except that while an invitation is held unanswered the tick leaves it in place until the device clock reads 72 hours or more past the first tick that waited, or reads earlier than that tick (a hold that has ended stays ended until the replacement is acknowledged); a database retired by a migration has its keyring key destroyed; a left circle's MLS state is deleted with MDK's `forget_group_local` when its leave ends, except a disbanded circle (its live MLS state the engine deleted at the disband, and its tombstone is kept), one the engine cannot read (quarantined, not hydrated, or a store that does not answer), and one from whose last roster an invitation is held unanswered — counting, after a restart, every invitation held before it until as many are held again or a replaced key package ends the wait for them — these last two kept on a durable list and asked about again at every foreground drive and every open; the first receive plane of each session also forgets every group held at its open that no circle row names and no consented join is owed for — never retain secrets beyond what's needed to decrypt in-flight messages
6. **No Key Logging**: NEVER log, print, or expose key material
7. **Secure Memory**: Use `Zeroizing<T>` from the `zeroize` crate for secret bytes; structs holding secrets must derive `ZeroizeOnDrop`
8. **No Raw Errors in UI**: Never display `$e` or `e.message` to users — could leak MLS group IDs or internal state. Use `debugPrint` for details, generic messages for UI. Classify FFI failures only by typed outcome fields (fieldless enums / `Option` arms matched by variant in Rust, using `EngineError::privacy_safe_kind()` where a kind suffices) and map each to fixed l10n copy; never inspect an error string
9. **Dart Secret Lifetime**: Dart has no `zeroize`; minimize exposure by re-fetching secret bytes per use rather than holding long-lived references
10. **User privacy comes first**: Never make changes which reduce the user privacy and security unless the prompt explicitly tells you to.
11. **Nonce Uniqueness / No Label Downgrade**: The kind-445 ChaCha20-Poly1305 nonce MUST be CSPRNG-random (12 bytes) and MUST NEVER repeat under a fixed epoch `group_event_key`; NEVER call the peeler's `with_exporter_label` override — it is the only local lever that can downgrade the kind-445 exporter derivation (CI-guarded by `scripts/ci/check_no_exporter_label_override.sh`)
12. **Convergence-Buffer Backpressure**: Rate-limit convergence-buffer ingest with backpressure; NEVER silently drop legitimate offline backlog (future-epoch catch-up is legitimate). `TransportDeferred` input is retained and retried by the engine, so the cursor may pass it; input answered `ResourceRefused`, announced as `TransportObjectResourceRefused`, or left unpersisted is never recorded as seen — the cursor holds or the event is refetched by id. Caveat: the engine's stored convergence buffer — and the raw `Retryable` persist taken while a group is `PendingPublish` (OQ-B) — has no per-group cap and no eviction API (upstream #757 closed as not planned, with no fix), so a Haven-side intake cap throttles but does not bound engine storage. A relay left out of a circle's end-of-stored-events coverage — refused, not connected when it took the REQ, or silent past `EOSE_WAIT` (released at a burst's wait end, the foreground release, or a health tick) — owes the circle its history from the `since` it was asked (`relay_floors`); every later live-plane REQ to it asks from there until it ends with an EOSE to a REQ asked from the floor or earlier; a single relay's re-issue leaves the REQ's other relays owing what they owed; a REQ the pool refused for a relay that is down is re-issued alone when the relay reconnects (a circle's REQ from the floor; the inbox REQ only when the last open issued it); a pause forgets what every REQ still owed, so nothing a closed REQ owed is released after it; and a routing id's floors are dropped with it — deleted with the circle, and dropped for the id a rotation moves onto, whose sync state starts over. Every receive plane hands the engine a stored kind-445 batch ordered so a proposal at the circle's current epoch goes before any commit (`SessionManager::order_for_ingest`, failing open to the order given; MDK drops for good a commit taken in before its proposal, tracker `T-COMMIT-BEFORE-PROPOSAL`): the live plane holds each REQ's stored replay — what an endpoint sends before its `EOSE` — and takes it in at any endpoint's `EOSE` or `CLOSED`, at a pause, at a silent relay's release (and again just after it), at a narrowing that completes a REQ's coverage, at the worker's exit and at `WORKER_QUEUE_CAP` events or `STORED_REPLAY_BYTE_CAP` bytes held, always before the cursor anchor, the settle a burst waits on and the pause ack; the pager holds a page's current-epoch commits while its chase goes on and records them deferred at every halt, so the cursor holds; and while a circle holds such a fetched commit — by event id, from its page until an ingest on any plane takes it in or the group is joined anew — or such stored replay, not yet taken in, no location is sealed for it (`SessionManager::holds_unread_input`, the typed `SendHeld::StoredInput`; Security Rule 10); a relay left out of its REQ's coverage sends no stored replay. A catch-up window the pager cannot finish completes when every relay of the routing answered a NIP-77 pass covering it whole — not refused, failed or saturated — and every id that relay reported missing was taken in, is owed a refetch by the refused ledger, or was judged final for that route: rejected before authentication, asked of the relay that reported it and absent from its `EOSE`-ended answer, or dropped by the pool's expiry screen; a routing with a relay without NIP-77 keeps the pager's rule (`T-NIP77-FALLBACK`).
13. **Publish-Before-Apply** — six invariants, each pinned; `haven-core/SECURITY.md` carries the rest (the frozen targets, the `min(2,n)` acknowledgements after a confirm and the two 24 h bounds, a location's single attempt per relay, the Welcome obligations):
    1. **One way out.** Every commit is staged under a durable MDK fanout record in the session hold that staged it, before any byte can leave the device, and only the fanout driver (`haven-core/src/relay/fanout.rs`) sends it; a proposal too, except one no record could be written for, which the driver publishes once, in the full mode, through its publisher of unrecorded events, and never confirms or rolls back. The relay layer refuses any event that has a record, and the FFI's plain publish entry refuses every kind 445 and every kind 1059 (`security_rule_gates::a_fanout_is_the_only_way_a_commit_leaves_the_device`; `the_plain_publish_refuses_a_gift_wrap`; `fanout_driver_e2e::nothing_but_the_driver_sends_an_event_that_has_a_fanout_row`).
    2. **Acked means acked.** A commit is confirmed (`confirm_published_fanout`) on the first relay OK-ack, and on nothing less (`publish_before_apply_send_e2e`: `add_members_confirms_only_on_an_ack`, `remove_members_confirms_only_on_an_ack`, `update_circle_relays_confirms_only_on_an_ack`).
    3. **Rolled back only on proof.** A commit is rolled back (`publish_failed_fanout`) only when every frozen target answered with a proven non-acceptance and none was ever possibly exposed. A timeout, a lost `OK` or an outcome no target classified is possibly exposed: the commit stays pending and the byte-identical event is sent again (`fanout_driver_e2e::a_rollback_never_retires_a_commit_a_relay_may_hold`, `fanout_driver_e2e::an_outcome_with_no_per_target_classification_is_possibly_exposed`).
    4. **A pending commit holds its circle, both ways.** While a commit is pending, its circle's location sends are deferred as *awaiting relays* and its inbound traffic is held unread, so one no relay ever acknowledges freezes that circle's peer locations and grows Rule 12's unbounded buffer; either resolution releases both (`live_plane_drive_e2e::a_location_send_for_a_circle_awaiting_its_relay_is_deferred_typed_and_touches_nothing`, `fanout_driver_e2e::traffic_buffered_behind_a_pending_commit_is_delivered_by_either_resolution`).
    5. **A commit cleared at open never left the device.** `PendingCommitRecovered` is a mandatory resync, and the cleared commit's row is retired before the session's first engine call, so no convergence pass applies it on this device alone (`fanout_restart_e2e::a_commit_cleared_at_open_is_retired_and_never_merged`).
    6. **A failed confirm is not a failed publish.** An `Err` from `confirm_published_fanout` is never a rollback; only a transient one is asked again in the same call, four attempts in all (MDK's host's rule); the stored row decides: still `Pending`, a later drive confirms it; `Confirmed`, the commit is applied — what it delivered is drained and folded, and the original error returned (`fanout_driver_e2e::a_failed_confirm_is_never_a_rollback_and_the_next_drive_confirms_it`; `fanout_end_e2e::only_a_busy_store_is_asked_to_confirm_again`).

    Publish-before-apply lives entirely in Rust: the bridge exposes no `PendingStateRefFfi` and no confirm or rollback, so no Dart code can hold or resolve a staged commit (`scripts/ci/check_e2e_publish_before_apply.sh` check 1 bans the deleted symbols from `integration_test/`).
14. **Single Session**: Run exactly ONE live `AccountDeviceSession` per MLS DB file across all isolates/processes — a second session diverges in-memory epoch state and risks epoch/exporter-key reuse, i.e. a confidentiality loss, not just DB corruption
15. **Log Anonymity**: No identifier of any shape — key, pubkey/npub, group id (MLS or Nostr), event id, KeyPackage slot, subscription id, relay URL or host, IP, name/petname, coordinate/geohash, absolute epoch, exact count, absolute publish/receive instant, remote-authored text — may reach any log, panic, `Debug`/`Display` rendering or FFI error string, in any build or encoding, full or truncated (see the Log anonymity pillar above). Use `log_alias` handles, buckets and relative offsets instead. SQLCipher's native logger and its `cipher_profile` statement tracer are compiled out, never merely filtered: SQLCipher is built with `-DSQLCIPHER_OMIT_LOG -DSQLITE_OMIT_TRACE` (root `.cargo/config.toml` `[env]`, repeated in `haven/rust_builder/cargokit.yaml` because cargokit runs cargo outside the repository; MDK enables rusqlite's `trace` wrappers, which call the omitted tracer, and the Apple pods `-force_load` the Rust staticlib, so both podspecs build it with thin LTO, which drops them — `check_sqlcipher_logger_omitted.sh` holds that line), proved in-process and on stderr (`haven-core/tests/sqlcipher_logger_omitted.rs`, which also holds that no Haven or MDK source issues `PRAGMA cipher_profile`), on every built artifact (`check_sqlcipher_logger_omitted.sh`) and on every lane capture (logscan `S-SQLC`). No lockfile may contain a `tracing` subscriber or a `tracing`→`log` bridge, and no MDK forensic recorder is ever installed (`check_no_tracing_sink.sh`, `check_no_forensic_recorder.sh`). Guarded by `scripts/ci/check_no_identifier_logging.sh`, `check_debug_impls_covered.sh`, `check_release_log_silencer.sh`, `check_native_log_allowlist.sh` and the runtime log scanner; a suppression `// log-scan-ok: <reason>` needs a reason and a reviewer. No MDK value is ever formatted (`{:?}` or `{}`) except through a Haven redacting wrapper — MDK id types print full hex and endpoints are relay URLs (examples: `GroupId`, `MessageId`, `MemberId`, `TransportEndpoint`, `KeyPackageMetadata`, `IngestEffects`, `OutboundFanout`, `PublishWork`; non-exhaustive) — and relay-authored text (`TransportEndpointFailure.reason`, OK/CLOSED messages) never reaches a log or an FFI string
16. **Relay Events Are Verified By Haven**: every relay client in shipped code is built by `haven-core/src/relay/verified.rs` `verified_client`, whose admission policy calls `Event::verify()` — id AND signature — on every relay `EVENT` the pool would otherwise hand on, before the pool stores it, de-duplicates it by id or notifies anything; `nostr-relay-pool` 0.44.3 skips its own check for an event whose claimed id it has already verified, so a relay holding no key can forge under one. NEVER construct a `Client` or `RelayPool` anywhere else (inside `haven-core/src`, `haven/rust_builder/src` and `tooling/soak/src` a test's own client carries a trailing `// test witness`, in the files check 11 lists), NEVER give that client a gossip store — the SDK feeds each event to it before the policy runs — or a second admission policy, NEVER hand MDK's `NostrSdkRelayClient` any client but the publish client (it verifies nothing itself; one site, `RelayManager::fanout_transport`, check 11), NEVER call its subscription half (`scripts/ci/check_publish_client_no_subscription.sh`, which scans the `subscribe`/`unsubscribe` spellings, the plane's named entry points and the one NIP-77 session shape only), NEVER install a signer on a relay client or tell one to authenticate (check 11: the words `set_signer` / `unset_signer`, a `.signer(` / `::signer(` call, turbofish included (`signer::<…>(`), a path that ends in `::signer` (a path THROUGH a module named `signer` passes), and an assignment to any value's `signer` field (`.signer = …`; a `==` comparison passes) appear nowhere in the three source trees, and every `automatic_authentication(` is `automatic_authentication(false)` and `verified_client` sets it to `false` itself on whatever options it is handed — both can be changed on a built client; a text scan that does not read `tests/` and sees the assignment spelling only: a `signer` field set through a struct literal, a `&mut` borrow or an `Option` method is not caught) — with a signer the pool answers a relay's NIP-42 challenge, binding the identity key to group traffic, and MDK's client signs an unsigned non-445 event it is handed; and at every MDK bump `transport-nostr-adapter/src/sdk_client.rs` is re-read for a client construction, a gossip store, an admission policy or a signer (`mdks_relay_client_builds_no_client_and_installs_nothing_on_the_one_it_is_handed`) and for its in-call attempt count (`mdks_in_call_attempt_count_is_the_one_the_transport_counts_against` — a count higher than the transport's would let an unanswered attempt pass as refused) — NEVER replace `verify()` with `verify_signature()` or `verify_id()`, NEVER move the check to after an id-keyed de-duplication, and NEVER pass a kind-444 Welcome rumor to it (Rule 3). A NIP-77 session carries no event; every event a pass leads to is fetched by id on the publish client and passes `verify()` like any other. Judging an id the screen refused before authentication as final for its route (Rule 12) rests on `verify()` binding the id to the bytes — never weaken the check without revisiting that judgement (`T-NIP77-DRIVER`). The policy logs nothing and gives no reason (Rule 15); a forged event is dropped as if withheld, and the relay that sent it is not banned. Verification proves authorship, not freshness: among the copies of a kind-0, 10002 or 10050 event the asked relays serve, Haven takes the newest `created_at` and the LOWER id on a tie (NIP-01), and an edit to the user's own profile is not merged onto a relay copy older than the dated own-profile row this device holds — written when a profile fetch caches the copy, when a relay acknowledges a publish, and as the blank's record when the profile is deleted (`profile::outbox::merge_base`); a device holding no such row builds on whatever the answering relays serve. Guarded by `scripts/ci/check_engine_client_options.sh` check 11 — a text scan that does not read `tests/` and cannot see a `Default` the compiler infers; tracker `T-POOL-VERIFY-CACHE`, `T-FORGED-COPY-SEEN`

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
| 30443 | KeyPackage (addressable) | `d` = stable random slot, reused on replacement. Content = base64 `MLSMessage(mls_key_package)`, Current profile. Tags `d`, `mls_protocol_version` = 1.0, `i`, `mls_ciphersuite`, `mls_extensions`, `mls_proposals`, `app_components`, each exactly once; id-lists come from the package's decoded metadata through MDK's `NostrKeyPackagePublication`, never hard-coded; `mls_extensions` never lists 0x0003, 0x000a or 0xf2f1; `app_components` lists ids ≥ 0x8000 including 0x8009 and 0x800c. Each publication of a package into a slot is signed once by the identity key, and a heal and every retry republish those bytes; the one-time malformed-slot repoint signs a second event for the same package. No `client` / `encoding` / `relays` tag. Published to the account's own NIP-65 relays — the stored list Haven's kind 10002 is built from, with unmarked `r` tags, so every one of them is write-capable — and fetched from an invitee's 10002 write-capable set with the read-only discovery plane as fallback; an inviter filters candidates by the target circle's requirements before ranking them, and prefers a package no app has labelled |
| 444 | Welcome | Gift-wrapped, UNSIGNED; every Welcome — an invite's and each a circle is founded with — is sent only by the fanout driver from a durable delivery record, to its invitee's inbox relays; a founding one's record is written before the create returns (`create_circle_driven`), and the FFI's plain publish entry refuses kind 1059 |
| 445 | Group messages | Outer ChaCha20-Poly1305 layer keyed by MLS-Exporter `"marmot/group-event"`; ephemeral pubkey per message. Tags are `h` only for commits/proposals, `h` + NIP-40 `expiration` (= `created_at` + 228s, from group component 0x8005) for application messages; in a circle whose 0x8005 another client set, a shorter non-zero value is honoured as declared, and an absent, zero or longer one is stamped 228 s by Haven itself (`RetentionBoundPeeler`, a recorded deviation: tracker `T-RETENTION-DEVIATION`) — **no other tag is permitted**. Sent only by the fanout driver (Rule 13): a commit, or a proposal with a durable MDK fanout record, until a relay acknowledges it (a proposal no record could be written for, once), a location once per relay and never past its `expiration`; the FFI's plain publish entry refuses a kind 445. |
| 450 | Account identity proof | Local signing template for LeafNode component 0x8009 (Current profile). `created_at` = signing time. Tags exactly `d, component, ciphersuite, signature_scheme, mls_signature_key`, in this order; fixed content string. Signed by the identity key. NEVER published |
| 1059 | Gift Wrap (NIP-59) | 3-layer encrypted welcome delivery |
| 10002 | NIP-65 relay list | KeyPackage discovery (replaces the retired kind 10051) |
| 10050 | NIP-17 inbox relays | Gift-wrap (1059) delivery |
| 10063 | Blossom server list (BUD-03) | Not published in v1 |
| 24242 | Blossom authorization (BUD-01/02) | HTTP `Authorization` header only — NEVER published to a relay |
| 25442 | Location content | Inner application message (`KIND_LOCATION_UPDATE`): unsigned, **no tags** — the kind alone is the discriminator — and only ever visible after MLS decryption |

**Group components**: every circle requires 0x8001, 0x8003, 0x8004, 0x8005, 0x8009 (leaf) and 0x800c (an admin may disband the circle, after which Haven, reading MDK's tombstone, seals nothing for it, asks no relay for it, and never calls MDK's forget for it). Haven never advertises 0x8006, 0xF2D1 or 0x800b, and never enrols a circle in periodic self-update; a joiner makes the post-join self-update MDK owes it, in a full drive after catch-up, made again if branch selection withdraws it and, after a refusal, only after the doubling wait; any member may make the epoch-rotation repair, a self-update rate-limited to one per circle per 24 h.

## CI Pipeline

Reusable workflows in `.github/workflows/`; **ci.yml** is the PR/push orchestrator (one job per concern, five stages):
- **Stage 1 — code quality**: `rust-check.yml` (`cargo metadata --locked` per root, then fmt + clippy + release-mode build for the two shipped crates — rust_builder's tests, and haven-core's doctests plus `cargo test --no-run` — plus the `e2e-tooling`, `logscan-tooling` and `soak-tooling` jobs for the three tooling crates and `haven-core-suite`; called three times from `ci.yml` by its `group` input: `rust` = `core` (the shipped crates, e2e and logscan tooling — the only group the E2E lanes wait for), `rust-suite` = `suite`, `rust-tooling` = `tooling` (soak); haven-core's suite runs twice per push on purpose, gating no E2E lane — in `haven-core-suite` on floating `stable`, uninstrumented and unscaled, and in `coverage.yml` on the pin, instrumented), `flutter-check.yml` (`flutter analyze --no-fatal-infos` — errors/warnings gate, pre-existing infos advisory), `cross-check.yml` (`cargo check --target` for macOS/iOS/Windows/Android; validates platform-gated `#[cfg]` code), `coverage.yml` (80% Rust / 50% Flutter thresholds), `audit.yml` (cargo-audit; also weekly; every `audit.toml` ignore must still match a live advisory)
- **Stage 2 — repo guards**: `repo-guards.yml` — ALL fast grep/bash invariants in ONE job (committed secrets, tile-provider policy, public-profile privacy boundaries, INTERNET permission, background-wake invariants, locale privacy, exporter-label override ban, MDK supply-chain shape and lockfile universe across the three Cargo roots, tracing-sink and forensic-recorder bans, the one verifying relay-client constructor, no subscription on the publish client, the SQLCipher first-use gate, E2E publish-before-apply, E2E-harness self-tests). Every guard step runs even if an earlier one failed, so one red run reports all violations. Add new pure-grep guards HERE as steps, not as new workflows.
- **Stage 3 — localization**: `l10n-check.yml` (gen-l10n regeneration + cross-locale ARB parity)
- **Stage 4 — E2E lanes** (all parallel, each `needs: [rust]` only; the soak lane `needs: [rust-tooling]`, whose soak-tooling job writes its cache): core flow on Android + iOS, each in poll AND live-sync variants (`e2e-android.yml` / `e2e-ios.yml` via the `live_sync` input), `e2e-integration.yml` (component integration tests), `e2e-relay-customization.yml` (two-relay proof; its second relay speaks NIP-77 and the first does not, so it is the one lane running a mixed routing), `e2e-background-catchup.yml` (WorkManager runtime proof incl. guest reboot), `e2e-ios-background-publish.yml` (real OS background transition on the iOS sim: Haven's native CoreLocation session armed with a tier-dependent indicator/session oracle + publishes continue under the 100 m stationary profile + a burst RECEIVES a peer's kind-445 and, between bursts, the engine pool holds NO subscription and the session's drive pool — where every NIP-77 session of a burst runs — NO connected relay (P2c, since P4; the socket read since R4) + toggle-off silence proved from BOTH sides — the drive's event-id diff from inside the app, and a host-side relay probe (`tooling/e2e/ci/bgp-wire-probe.dart`) that outlives it, because iOS is entitled to reclaim a process the disable has just stripped of its background claim and did (35622556197: `runningboardd`, an expired FinishTask assertion, `OS_REASON_RUNNINGBOARD` — no jetsam, crash or watchdog), so such a run ends on one of four PROVEN verdicts (`holds`/`leak`/`relaunched`/`unproven`, guard check 19) instead of an unconditional red that called P3 "neither proved nor disproved"; THREE legs over two axes since OD4-d, `leg` being the per-job identity — `when-in-use-live-sync`, `always-live-sync`, `when-in-use-poll`, and deliberately no `(always, poll)` — so the shipped receive path is measured by two legs that compile the engine in (`HAVEN_LIVE_SYNC: "true"`; a burst has no receive engine without it) and the flag-off rollback path by one, which asserts **P2d** in P2c's place: MapShell's 90 s background receive timer completing a `runCatchup(isBackgroundWake: true)` sweep, and a peer's fix landing in the PERSISTED last-known store (written by that sweep or a burst's receive-before-seal, not told apart). That leg CLOSES owner decision OD4-d (`docs/POWER_EFFICIENCY_PLAN.md` §4) at one extra ~62-minute macOS job; `check_ios_background_publish.sh` check 6 still does NOT stand in for it (mutation-tested) — check 16 and P2d are what do; cannot prove device suspension — physical checklist in `docs/M7_BACKGROUND_SHARING.md` §6 remains final and is currently DEFERRED for lack of an iPhone), `e2e-profile.yml` (kind-0 + Blossom, Android + iOS), `soak-core.yml` (the `haven-soak` PR profile: four durability scenarios over real MLS engines and in-process relays under a fault layer, graded by derived liveness bounds and expectation floors — rc 3 if the faults did not fire; `docs/SOAK_LANE.md`), plus further scenario lanes fanned out in `ci.yml` (GPS/auth-tier/FGS/clock-skew/KP-rotation/reconnect and friends)
- **Stage 5 — build verification**: `build-check.yml` — Android debug APK per ABI (separate runners avoid disk exhaustion) + iOS no-codesign build; `needs: [rust, guards]`
- Standalone: `e2e-nightly.yml` (nightly), `soak-nightly.yml` (the Tier-1 soak `nightly` profile, four seeded slots, cron `23 0 * * 1-6`; files one `soak`-labelled issue per red key), `e2e-live-sync.yml` (manual), `release-build.yml` (tags `v*`; gate = ci.yml's push run on main having passed rust-check + cross-check + coverage + repo-guards on the tagged commit, read by `check_ci_verdict.sh`, never re-run), `ios-certificates.yml` (manual)
- Concurrency groups cancel in-progress runs on new pushes to the same branch

## References

- **Protocol Specs**: https://github.com/marmot-protocol/marmot (`foundation/`, `protocol-core/`, `transports/`, `app-components/`; `mip-coverage.md` maps the deprecated MIP-00 through MIP-04 onto them)
- **MDK (Rust SDK)**: https://github.com/marmot-protocol/mdk
- **White Noise (reference apps)**: https://github.com/marmot-protocol/whitenoise-ios and https://github.com/marmot-protocol/whitenoise-android (whitenoise-rs is archived)
- **Local Docs**: See `MARMOT_PROTOCOL_KNOWLEDGE.md` for consolidated protocol reference
- **Background-sharing failure analysis + fix plan**: `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` (canonical for the "sharing stops after hours" incident; work units A–F with status, plus Unit H mapping the power phases P1–P5 back onto the five wedges)
- **Power efficiency (P0–P6)**: `docs/POWER_EFFICIENCY_PLAN.md` (canonical plan + decision ledger for the battery epic; §2.5 is the no-hardware constraint and §6.5a is estimation model E — every battery figure in this tree is ESTIMATED, never measured)
- **Power measurement protocol**: `docs/POWER_MEASUREMENT.md` (the device protocol, DEFERRED. Its `## Baseline` table is deliberately EMPTY, and there is **no `## Acceptance` section at all** — that absence is the record, not an omission, so an `## Acceptance` heading appearing without a dated row under it means somebody added a heading ahead of the measurement. Never fill either from an estimate; the estimates live in `docs/POWER_EFFICIENCY_PLAN.md` §6.5a, tagged)
- **Setup Guide**: See `haven/DEVELOPMENT.md` for environment setup
- **FFI Architecture**: the dual-crate design and the `*Ffi` wrapper pattern are the **Architecture** section above (there is no separate FFI document); regeneration is `./scripts/regenerate_frb.sh`, and the generated Rust/Dart halves are pinned against each other by `scripts/ci/check_generated_bridge_pinned.sh` (whose header is the troubleshooting reference)
- **MDK upstream tracker**: `docs/MDK_UPSTREAM_TRACKER.md` — one row per Haven-side mitigation of an MDK gap, with its upstream issue/PR, removal condition and pinning test (MDK's implementation wins wherever it exists)
- **Security Tracking**: See `haven-core/SECURITY.md` for known CVEs and keyring setup
- **DI Testing Patterns**: See `haven/test/services/DEPENDENCY_INJECTION_EXAMPLES.md`

## Agents

Specialized agents auto-invoke for their domains. Do not skip security-reviewer for crypto code.

| Domain | Agent | Auto-triggers |
|--------|-------|---------------|
| Crypto, keys, MLS, auth | security-reviewer | Any code touching encryption or secrets |
| New features, bug fixes | test-writer | Write tests before implementation (TDD) |
| MIP specs, protocol compliance | marmot-expert | Marmot, MLS, Nostr integration questions |
| NIP compliance, event shape, relays | nostr-expert | Nostr protocol questions, event validation, relay debugging |
| haven-core, Rust, FFI | rust-expert | Rust implementation tasks |
| haven app, Flutter, Dart | flutter-expert | Flutter implementation tasks |
| UI/UX, design, accessibility | ui-ux-reviewer | Flutter UI implementation, design reviews, accessibility checks, before releases |
| Vulnerabilities, outdated deps | dependency-auditor | Periodic audits, before releases |