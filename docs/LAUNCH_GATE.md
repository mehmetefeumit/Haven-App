# Release launch gate

v0.1.14 for Android crashed at every process start, fresh install and upgrade
alike: AGP 9 turned on R8's strict full mode for keep rules
(`android.r8.strictFullModeForKeepRules`), Room's member-less
`-keep class * extends androidx.room.RoomDatabase` stopped keeping
constructors, R8 stripped `androidx.work.impl.WorkDatabase_Impl.<init>()`, and
WorkManager's startup provider died in `newInstance()` before any Dart ran
(CI run 43588108447). The same change stripped ML Kit's `ComponentRegistrar`
constructors, which breaks QR scanning. The fix is
`android.r8.strictFullModeForKeepRules=false` in
`haven/android/gradle.properties`.

CI missed it because no lane had ever launched a release build: every Android
lane builds a debug APK of an `integration_test` target, so production
`main()` never ran on a device, nothing upgraded from a previous release, and
`release-build.yml` published without launching anything. The launch gate
closes that gap.

## Android

### What runs, and where

`.github/workflows/launch-gate-android.yml` is one job,
`Release APK: launch, relaunch and upgrade`, called from:

| Caller | Candidate | Signing | Previous release |
|---|---|---|---|
| `ci.yml` (pull requests, main) | built here with the unchanged `scripts/build_release.sh apk` (R8, obfuscation, three ABIs), `STADIA_API_KEY=ci-launch-gate-no-tile-key` | debug key of the job's runner | re-signed with that same debug key |
| `release-build.yml` | `candidate_artifact`: the exact signed APKs about to be published | release key | as published; certificates must be equal |
| a validation run | `candidate_release_tag`: a published release's APKs | release key | as published |

On success the job outputs `tested_sha256`: `sha256sum app-*-release.apk`
run inside the candidate directory (`<sha256>  <basename>` per line), sorted,
joined with `;`. `release-build.yml`'s publish job compares its own download
of the artifact against it, so the bytes published are the bytes tested.

### 1. The dex and native-library check — `scripts/ci/check_apk_loadable.sh`

Runs on all three APKs, after the launch and whatever it found, with `dexdump`,
`aapt2` and `zipalign` from the newest `$ANDROID_HOME/build-tools`, and
`unzip` and `readelf` from the runner. A class instantiated by name must exist, be
neither abstract nor an interface, and declare the constructor it is
instantiated through:

| Check | Classes | Constructor |
|---|---|---|
| E1 | every manifest component: application, appComponentFactory, activity, activity-alias target, service, receiver, provider | `<init>()V` |
| E2 | every `com.google.firebase.components:<class>` meta-data valued `ComponentRegistrar` (ML Kit) | `<init>()V` |
| E3 | every `androidx.startup` Initializer meta-data | `<init>()V` |
| E4 | every `X_Impl` whose direct superclass is `X` (Room's own lookup) | `<init>()V` |
| E5 | every concrete class below `androidx.work.Worker`'s superclass (the R8-renamed `ListenableWorker`) | `<init>(Context, WorkerParameters)V` |

R8 renames `RoomDatabase`, `ListenableWorker` and `Initializer`, so the checks
key on names R8 keeps. A manifest component that is both absent from the dex
and declared `android:enabled=false` is exempt (the platform never
instantiates a disabled component; GMS's `ModuleDependencies` marker is one).
Each check must find at least one subject, and E1 must find `MainActivity` and
`HavenApplication`, or the run is rc 2: a check with nothing to look at is
never a pass. Output that does not parse into class blocks is rc 2 too.

On the shipped APKs: v0.1.13 passes (E1 31 components, E2 3, E3 4, E4 1,
E5 3); v0.1.14 fails E4 on `WorkDatabase_Impl` and E2 on `BarcodeRegistrar`,
`VisionCommonRegistrar` and `CommonComponentRegistrar` — the crash and the QR
break, the second of which no launch can see. The self-test's fixtures are
real `dexdump`/`aapt2` excerpts of those two APKs (their headers say how each
was cut).

Only the x86_64 APK is launched, so the check also reads every APK's native
libraries, which the platform maps straight out of the APK
(`extractNativeLibs` is false):

| Check | What |
|---|---|
| N1 | every `lib/<abi>/*.so` is stored uncompressed (`unzip -Z`: `stor`) |
| N2 | its data starts on a 16 KB boundary in the zip (the offsets `zipalign -c -v -P 16 4` prints) |
| N3 | for arm64-v8a and x86_64, every `PT_LOAD` has `p_align` of at least `0x4000` (`readelf -lW`), as devices with 16 KB pages require |

An APK with no library or no `librust_lib_haven.so`, a library `zipalign` did
not list, a missing verdict line and a library with no `PT_LOAD` are rc 2. The
shipped v0.1.13 and v0.1.14 APKs (arm64-v8a and x86_64, build-tools 36.1 and
37) pass all three; the self-test's fixtures are real `unzip`/`zipalign`/
`readelf` output of v0.1.13's arm64-v8a libraries.

### 2. The launch — `tooling/e2e/ci/run-launch-gate-android.sh`

On an api-34 `google_apis` x86_64 emulator, under `run-with-deadline.sh` and
the host egress guard, the x86_64 APK is started the way a user starts it: the
launcher activity, cold (`am start -W`), production `main()`.

**Preconditions** (rc 3 when unmet): the device boots, its locale is en-US
(asserted, never set), airplane mode is on with no default network, and
system error dialogs are hidden.

**Legs:**

- **fresh** — install the candidate fresh, onboard, force-stop, launch cold.
- **upgrade** — install the previous release fresh, onboard it, install the
  candidate over it (a replace: data stays), launch cold.
- **baseline** — the same upgrade from v0.1.13, the last release that onboards
  to the map offline, so the candidate opens MapShell in release mode. Skipped
  when v0.1.13 *is* the previous release (true until a fixed release ships,
  since v0.1.14 is yanked).

**Offline, deliberately.** A release build trusts only its bundled roots and
production relays, so the alternative would be publishing to production from
CI. Offline, current onboarding stops at "Couldn't finish setting up"
(`onboardingFinishSetupError`, the reachability wait of owner decision OD-C):
the **SETUP_HELD** terminal, reached after the identity is created and the
display name is saved. A release from before OD-C goes on through the location
disclosures ("Not now") to the map: the **MAP** terminal. After a cold restart
or an upgrade the app must reopen at the same terminal class, never at the
intro, and show the very display name the first launch saved: on the create
screen at SETUP_HELD, and at MAP on Settings › Identity, where the gate drives
it (the map's Settings button alone proves only the onboarding flag in
SharedPreferences). That name is SharedPreferences keyed by the public key of
the identity the app loads from secure storage
(`nostr_identity_service.dart:111-117,175-177,367-368,444-449`), so an update
that loses the identity — a keystore or secure-storage regression — fails. Each
terminal screen a candidate reaches must then stay up, unattended, for 30 s
with no crash or ANR.

**Reading the screen.** `tooling/e2e/ci/ui-dump.py` reads one `uiautomator
dump` at a time (UiAutomator sees Flutter's semantics in release builds,
FLAG_SECURE included). Labels come from the APK's *own* `app_en.arb`: the
checked-out file for a candidate built here or released from this commit, the
tag's file (`git fetch --depth=1 origin "+refs/tags/<t>:refs/tags/<t>"`, then
`git show`) for a published release. A key a build's ARB lacks removes that
state; the welcome CTA, the create CTA and `commonSettings` are required.
A tap is judged by the screen, not the label: each dump carries a digest of
our window's text (never printed). A label is tapped once per screen, only on a
screen two dumps agree on, and never retried; a tap after which the screen
stays exactly as it was for the whole window (60 s, 120 s for the create tap)
is "did not progress", a product failure. The same label on a different screen
is a new screen: v0.1.13 declines the background location disclosure, then the
foreground one, two dialogs with one "Not now". A reopened map under that
dialog (an upgraded user who declined it) is declined the same way before
`commonSettings`, then `settingsIdentityTitle`, are tapped; on the Identity
page — its `identityTitle` app bar ("Identity", the Settings entry's own words,
so it is never tapped) over one name field, whose "Display Name" label is a
hint no dump shows — the field is read until it shows the name.

**Crash evidence comes first.** Before anything else is blamed, the runner
reads the crash buffer (`Process: com.oblivioustech.haven` or
`>>> com.oblivioustech.haven <<<`), the events buffer (`am_crash`/`am_anr`
for the package) and the process itself (gone or replaced while it should be
running). That is why a v0.1.14-shaped candidate's red names
`WorkDatabase_Impl`.

### Verdicts

| rc | Class | Meaning | What to do |
|---|---|---|---|
| 0 | pass | every leg passed | — |
| 1 | product | the candidate crashed, stalled, lost data, showed the intro after onboarding, kept a debug log plant, or did not replace the previous release | fix the app; never re-run to green |
| 2 | usage | a missing input (directory, ARB key) | fix the workflow |
| 3 | infrastructure | the device went away, never booted, is not en-US, or would not go offline | re-run the job |
| 4 | upgrade source unusable | the previous release itself failed before the candidate was installed | add it to `scripts/ci/launch_gate_yanked_releases.txt` with the reason |

The step prints one `::error::` line naming the leg, the state reached, the
last observation (visible label keys, foreground package, EditText count) and
the class, plus the root cause of a crash. The summary
(`launch-gate-summary.log`) and, only when there is crash evidence, the crash
summary (`crash-summary.log`: exception lines, `at` frames, native frames as
`#nn pc <offset> <library>`, random install paths removed) are the only files
uploaded.

### The previous release — `tooling/e2e/ci/launch-gate-previous-apk.sh`

`fetch` picks the newest published release (by version, not date) that is not
a draft, not a pre-release, not yanked for Android in
`scripts/ci/launch_gate_yanked_releases.txt` (`<tag> <android|ios|all>
<reason>` per line, shared with the iOS gate; any malformed line is rc 2) and
older than the candidate's own tag, downloads its
`app-x86_64-release.apk` and `.sha256`, verifies one against the other, and
fetches that tag's ARB. `prepare` then makes it installable under the
candidate: re-signed with the job's debug key for a candidate built in the same
job (and the result must carry exactly the candidate's certificate), or, for a
release candidate, both as published with equal certificates — anything else
means users could not upgrade, rc 1. The candidate's versionCode must be above
the previous release's.

**versionCode.** Flutter's `--split-per-abi` sets versionCode = ABI factor ×
1000 + build number, x86_64's factor being 4 (flutter_tools
`FlutterPluginConstants.ABI_VERSION`: armeabi-v7a 1, arm64-v8a 2, x86_64 4) —
v0.1.13's x86_64 APK is 4020 (build 20), v0.1.14's 4021. A pull-request
candidate is therefore built with `BUILD_NUMBER` = previous x86_64 versionCode
− 4000 + 1, never "previous versionCode + 1", which would stamp 8021 and break
every later release whose build number is a run number.

### Privacy

Nothing the app or the device prints is uploaded raw: no logcat, no UI dump,
no APK. Dumps live in a 0700 directory and are deleted after each read. The
display name onboarding generates is read from the screen into that directory,
compared there, declared to the log-privacy gate
(`--host-decl display_name=…`) so the scanner proves it absent from both
summaries, and never printed. The summaries pass the gate before the runner
echoes them, and again in the workflow before upload. The debug-only
`logscan-plant-*` tokens must be absent from logcat: a release build has no
debug logging.

### What it does not cover

- Runtime coverage is API 34, x86_64 only. The arm64-v8a and armeabi-v7a APKs
  get the dex and native-library checks; their AOT code and API levels 24–33
  are not run.
- SQLCipher. Every value a user can see offline that an encrypted database
  holds has a fallback that hides a failed open: the circle list reads empty on
  any failure (`circles_provider.dart:36-49`), and the Identity page's name
  falls back to the SharedPreferences copy (`display_name_card.dart:200-229`).
  A database the update cannot open is caught only if it crashes the app or
  shows an unexpected screen.
- MapShell on a fresh install (onboarding stops at SETUP_HELD offline); it is
  reached only through the baseline leg and the debug E2E lanes.
- Map tiles (the build carries a placeholder Stadia key) and anything that
  needs a relay.
- Reflection the five dex checks do not name (for example ML Kit's
  `backend:` meta-data).

### Bounds

Every wait polls a condition under a readonly bound in the runner (boot 60 s,
offline 30 s, `am start -W` 60 s, each screen 60 s, the finish wait 120 s, the
settle watch 30 s, a dump 15 s, a definite process read after a launch or a
stop 20 s, an adb read 10 s); nothing sleeps.
`scripts/ci/check_e2e_lane_budget.sh --explain` sums them with the install
barriers into the step's 66-minute deadline. A healthy run spends a few
minutes in the emulator step.

### Running the pieces locally

```bash
bash scripts/ci/check_apk_loadable.sh --self-test
bash scripts/ci/check_apk_loadable.sh path/to/app-*-release.apk   # needs ANDROID_HOME
python3 -I tooling/e2e/ci/ui-dump.py --self-test
bash tooling/e2e/ci/launch-gate-previous-apk.sh --self-test
bash tooling/e2e/ci/run-launch-gate-android.sh --self-test
```

### Proving the gate

Run it with `candidate_release_tag: v0.1.14`: it must be red twice over — the
launch's crash summary naming `WorkDatabase_Impl`, and the dex check (which
runs after the launch whatever it found) naming `WorkDatabase_Impl` and the
three registrars. Run it with no tag (it builds the branch) on a tree with the
fix: it must be green on every leg. The workflow takes both by hand
(`workflow_dispatch`), so this needs nothing but the Actions tab. Re-run a red
job only when its class is infrastructure (rc 3).

Not a green proof: `candidate_release_tag: v0.1.13`. Its own fresh leg passes,
but it must upgrade from v0.1.12, whose onboarding the gate cannot drive
offline, so it ends rc 4 (upgrade source unusable) — the class working as
intended. Every later candidate upgrades from v0.1.13 or newer.

Recorded on 2026-11-14, before the gate landed (one GitHub Actions run, three
jobs, run 43610601649): the shipped v0.1.14 red at launch with
`NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []` and
on the dex check (E4, and E2 for the three ML Kit registrars); the fixed
branch green — fresh to the setup screen and back across a cold restart, and
an onboarded v0.1.13 upgraded in place to the map with its name intact on the
Identity page, every APK passing E1–E5 and N1–N3; v0.1.13 rc 4 as above. The
iOS gate was green with the same fixes in run 43608781380 (fresh and relaunch
legs; no predecessor asset yet).

## iOS

### What runs, and where

| Where | What |
|---|---|
| `ci.yml` → `launch-gate-ios` (every PR and push to main) | `.github/workflows/launch-gate-ios.yml`, job `Simulator launch, relaunch and upgrade`: builds the candidate from the checked-out tree, launches it on a simulator, offline. A release gate job: `scripts/ci/check_ci_verdict.sh` requires it on the tagged commit. |
| `release-build.yml` → `ios-launch-gate` | The same workflow on the tag's tree. TestFlight waits for it; on a tag (only) it uploads the simulator app it launched as `haven-ios-simulator-app`, which `ios-simulator-asset` attaches to the GitHub Release. |
| `release-build.yml` → `ios` | `scripts/ci/check_ios_app_loadable.sh` on the signed archive's `Runner.app`, before the TestFlight upload. |

The gate must run green at least ten times on `ci.yml` before it is relied on as
a required release gate; it is wired as one now (owner decision OD2).

### The build

A simulator cannot run Release Dart: Flutter supports only debug mode there.
The gate therefore builds the **native** side in the Release configuration and
the Dart side in debug:

```
flutter build ios --simulator --debug --config-only
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -sdk iphonesimulator FLUTTER_BUILD_MODE=debug SUPPORTED_PLATFORMS="iphoneos iphonesimulator" ...
```

So the Rust core is built by cargokit's release profile, Swift with `-O`, and
the Release Info.plist and settings apply; the Dart is JIT. No `--dart-define`
is passed: the receive path is `live_sync_provider.dart`'s `defaultValue`, as in
what ships (`HAVEN_LIVE_SYNC-INTENT: production-default`).

Before anything starts, `check_ios_app_loadable.sh` and the SQLCipher logger
probe run on the candidate. On a tag it is also packaged as
`app-ios-simulator.zip` + `app-ios-simulator.zip.sha256` (sha256sum format)
for the release.

Flutter 3.50 builds iOS dev dependencies into every build mode, the shipped one
included (flutter/flutter#163874), so the app carries patrol, which weak-links
XCTest and is unused at run time; `check_ios_app_loadable.sh` allows exactly that
one absent weak load (`WEAK_ABSENT_ALLOWED`), and the entry must be removed when
#163874 lands.

### The legs

`tooling/e2e/ci/run-launch-gate-ios.sh` runs them; the XCUITest bundle in
`tooling/e2e/ios-launch-gate/` (a standalone, test-only Xcode project with no
host app) drives the installed `com.oblivioustech.haven` by bundle id, so what
runs is the candidate started by the OS through its production `main()`.

| Leg | Test method | Proves |
|---|---|---|
| fresh | `testFreshInstallThenColdRelaunch` | uninstall, simulator keychain reset, install; Intro → Create → a terminal screen; `terminate()` + `launch()` returns to the same terminal (never Intro) and, when setup is held, the create screen restores the display name the first run saved |
| upgrade source | `testOnboardUpgradeSource` | after another uninstall and keychain reset (so it creates its own identity), the previous release's simulator build onboards offline in its own words |
| upgrade | `testUpgradedCandidateRelaunch` | the candidate installed over it (the installed executable's sha256 equals the candidate's) opens on the same terminal screen with the same name |

The journey is a state machine over labels read from the ARB of the build being
driven (`TEST_RUNNER_GATE_*`): the candidate's from the checked-out
`app_en.arb`, the predecessor's from its tag. `onboardingWelcomeCta` and
`onboardingCreateIdentityCta` are tapped at most once each (and
`locationDisclosureNotNow` for builds that show it); `onboardingFinishSetupError`
ends it as SETUP_HELD and `commonSettings` as MAP;
`onboardingCreateIdentityError` or `onboardingDisplayNameError` fails it at once,
naming the key. Each step requires `app.state == .runningForeground`; each tap
requires `isHittable` (the privacy blur would cover the screen otherwise). All
waits are `waitForExistence`/predicate expectations under named bounds inside
XCTest's 600 s per-test allowance; the runner bounds each xcodebuild run at
900 s itself (macOS has no coreutils `timeout`). Locale is pinned with
`-AppleLanguages (en) -AppleLocale en_US`.

Offline, a current build ends every fresh install at SETUP_HELD: onboarding
waits for the reachability publish (commit 2ee27b08), which cannot succeed
without relays. That proves the process starts and the Rust core loads
(`RustLib.init`, `main.dart`), and that the identity survives a cold relaunch
and an upgrade: the restored name is read from SharedPreferences under the
pubkey of the identity loaded from the Keychain into the Rust identity manager
(`nostr_identity_service.dart` `_ensureInitialized` → `loadFromBytes`,
`getDisplayName`). It does not prove SQLCipher: the onboarding profile save to
the encrypted store swallows its failure (`create_identity_screen.dart`
`_saveOnboardingProfileLocally`), and nothing reachable before onboarding
completes (`app_router.dart` shows only `OnboardingShell` until then) reads that
store back. It does not reach the map.

### The predecessor

The newest by version of the non-draft, non-prerelease releases with a plain
`vMAJOR.MINOR.PATCH` tag below the candidate's (a pull request rules out
nothing by version), not yanked for `ios` or `all` in
`scripts/ci/launch_gate_yanked_releases.txt` (`<tag> <platform> <reason>`; a
missing list or a malformed line is rc 2), that carries both
`app-ios-simulator.zip` and its `.sha256`. A newer release without the pair is
passed over: its iOS gate failed, so it never reached TestFlight, and the
release before it is what iOS users upgrade from.

A download that does not match its checksum (release-build.yml verified the
pair before attaching it) and a simulator that refuses to install the build are
infrastructure (rc 3). An asset that does not unpack to one simulator
`Runner.app` of Haven's bundle id, a tag whose ARB lacks a journey label, or a
build that installs but does not onboard offline is rc 4 — upgrade source
unusable: yank it for `ios`. If no eligible release carries the pair, the run
ends rc 5 after the fresh legs passed and the job succeeds with a notice:
expected until the first release that publishes the asset.

### Offline

The simulator shares the runner's network, and a release-native build knows
only production relays, so the run must be offline:

`sudo pfctl -E` (token kept, released with `-X`), three rules in the anchor
`com.apple/haven-launch-gate` — `block return out quick` for new TCP 443 and 80
(`flags S/SA`) and UDP 443 — asserted present, pf asserted enabled, and the
main ruleset asserted to evaluate `com.apple/*`. The main ruleset is never
reloaded. A probe to github.com must be refused before the first leg and again
after the last leg that ran, whatever the verdict (a pass, rc 4 or rc 5 is
offline only if the block held), and the block is released on every exit the
runner sees and again by the workflow's `if: always()` step.

### Verdicts, retries, logs

| rc | Meaning | Job |
|---|---|---|
| 0 | every leg passed | green |
| 1 | the candidate failed (product); also a leak the log-privacy gate contained | red |
| 2 | misuse, or a missing or malformed yanked-release list | red |
| 3 | infrastructure | red, after at most one retry |
| 4 | the predecessor cannot be the upgrade source | red |
| 5 | fresh legs passed; no iOS predecessor build | green, with a notice |

A second attempt runs only on rc 3 and only when the first attempt's
transcripts show that no test case started; an assertion is never re-rolled.
A crash is read from new `~/Library/Logs/DiagnosticReports/Runner*.ips` reports
(bug_type 309): the exception, signal and crashed-thread frames (image name and
symbol only) go into the summary.

The one uploaded file is `/tmp/launch-gate-ios/launch-gate-summary.log`, written
by the runner (legs, verdicts, allowlisted transcript lines with paths cut to
their last component and UUIDs removed, crash frames) and passed through
`logscan-gate.sh` (host profile, `diag` sink) before it is echoed; when that
gate does not vouch for it, the runner deletes it. The workflow scans it again
(`scan-logs.sh` against the run's sealed manifest, `diag`) and uploads it only
when that scan passes, so a drive the retry action killed mid-gate uploads
nothing unscanned. Result
bundles, transcripts, crash reports and screenshots never leave the runner:
they hold the screen and the display name. The display name is never printed:
the tests compare it in memory, and across the upgrade it crosses only as a
SHA-256 digest salted with a value drawn per run and never printed.

### What iOS CI cannot prove

* **Release Dart.** AOT compilation, `--obfuscate`, `--split-debug-info` and
  tree shaking never run on a simulator. A defect only an AOT build has is
  invisible here.
* **The signed IPA.** The gate launches a simulator build from the same tree,
  not the bytes TestFlight receives. `check_ios_app_loadable.sh` reads the
  archive's dyld closure and the bridge's exports, but nothing starts it.
* **A device.** arm64 device code, provisioning profiles, entitlements on
  hardware, the Keychain's device access groups, the Secure Enclave, real
  background suspension and memory pressure.
* **The App Store upgrade path.** The upgrade leg installs a simulator build
  over a simulator build. An upgrade from an App Store or TestFlight install is
  not run.
* **SQLCipher.** Nothing reachable offline before onboarding completes reads
  the encrypted store back, and the onboarding profile save swallows its own
  failure, so a store that cannot be opened or keyed on iOS passes this gate.
  The SQLCipher logger probe is a static check of the binary, not a run.
* **The map on a fresh install.** Offline onboarding ends at SETUP_HELD; MapShell
  is reached only when a predecessor ends at MAP.
* **Network behaviour.** The run is offline by construction.
* **Other locales and devices.** One simulator model, the newest runtime, en_US.

Before external distribution, install the TestFlight build on a physical
iPhone: fresh install, onboarding, cold relaunch, and an upgrade over the
previous TestFlight build with its data kept.
