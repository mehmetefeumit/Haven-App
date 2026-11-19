# CI lane pass-rate baseline (`main`, pre-migration)

The record `docs/mdk-v0.16/stage0.md` Step 10 ("Lane pass-rate baseline") asks
for. Stage 1's exit compares each lane's runs against these counts. It is a
snapshot, never updated: a later baseline is a new file.

- Collected: 2026-11-19 (read-only, GitHub REST API `api.github.com/repos/mehmetefeumit/Haven-App`, same endpoints the MCP `actions_list`/`actions_get` tools wrap).
- Query: `GET /actions/workflows/ci.yml/runs?branch=main&event=push&status=completed` (newest first); jobs via `GET /actions/runs/{id}/jobs?filter=latest` paginated until `len == total_count` (verified for every run); failing steps via `GET /actions/jobs/{id}`.
- History: 338 completed `main` push runs of `ci.yml` exist; `soak-nightly.yml` has 48 completed runs.
- Last 20 completed: run ids 42456694728 .. 43868543765 (2026-11-08 .. 2026-11-16); 6 of them have run conclusion `cancelled`.
- Last 20 non-cancelled (extended back to 27 completed runs): run ids 41924298176 .. 43813324122 (2026-11-04 .. 2026-11-16).
- Non-cancelled window: 8 success / 12 failure run conclusions.

## Table A — `ci.yml` main push runs (newest first)

| # | run id | sha8 | created (UTC) | conclusion | attempt | jobs (total_count) | in last-20-completed | in last-20-non-cancelled |
|---|---|---|---|---|---|---|---|---|
| 1 | 43868543765 | 7496eb47 | 2026-11-16 12:39 | cancelled | 1 | 60 | yes | no |
| 2 | 43813324122 | 09986eb4 | 2026-11-16 05:55 | failure | 1 | 54 | yes | yes |
| 3 | 43813027007 | 143d4e1f | 2026-11-16 05:52 | cancelled | 1 | 52 | yes | no |
| 4 | 43705144915 | c7cf9ec8 | 2026-11-15 10:39 | success | 1 | 60 | yes | yes |
| 5 | 43679296707 | 81827f87 | 2026-11-15 05:01 | success | 1 | 60 | yes | yes |
| 6 | 43569623500 | d97b77ce | 2026-11-14 07:07 | success | 1 | 58 | yes | yes |
| 7 | 43504472962 | 6394cf4a | 2026-11-13 20:45 | failure | 1 | 58 | yes | yes |
| 8 | 43459825681 | 7c3ea751 | 2026-11-13 16:09 | failure | 1 | 58 | yes | yes |
| 9 | 43459785700 | 2c0e389d | 2026-11-13 16:09 | cancelled | 1 | 50 | yes | no |
| 10 | 43391026631 | af2fe5ab | 2026-11-13 08:09 | failure | 1 | 58 | yes | yes |
| 11 | 43380364256 | 8b338f88 | 2026-11-13 06:40 | cancelled | 1 | 58 | yes | no |
| 12 | 43363822463 | c4acb7b0 | 2026-11-13 04:10 | cancelled | 1 | 58 | yes | no |
| 13 | 43314988591 | 56071585 | 2026-11-12 21:55 | success | 1 | 58 | yes | yes |
| 14 | 43276482370 | fb782203 | 2026-11-12 18:07 | failure | 1 | 58 | yes | yes |
| 15 | 43010718284 | a45ab2d8 | 2026-11-11 11:17 | success | 1 | 58 | yes | yes |
| 16 | 43004030588 | b1b17cee | 2026-11-11 10:29 | cancelled | 1 | 58 | yes | no |
| 17 | 42802266653 | f1dd1460 | 2026-11-10 10:48 | failure | 1 | 58 | yes | yes |
| 18 | 42754106205 | 378b7394 | 2026-11-10 04:10 | failure | 1 | 58 | yes | yes |
| 19 | 42647620766 | 396b7717 | 2026-11-09 15:44 | success | 1 | 58 | yes | yes |
| 20 | 42456694728 | f50e21bc | 2026-11-08 06:55 | failure | 1 | 58 | yes | yes |
| 21 | 42392657873 | 0e12b60a | 2026-11-07 16:42 | failure | 1 | 58 | no | yes |
| 22 | 42380055887 | 5d61b899 | 2026-11-07 14:06 | failure | 1 | 58 | no | yes |
| 23 | 42134143952 | efc8fcfe | 2026-11-06 00:04 | cancelled | 1 | 58 | no | no |
| 24 | 42083193168 | a790228c | 2026-11-05 18:19 | success | 1 | 58 | no | yes |
| 25 | 41977768023 | 4d30a82d | 2026-11-05 06:02 | success | 1 | 58 | no | yes |
| 26 | 41944390485 | 37da8298 | 2026-11-05 00:51 | failure | 1 | 58 | no | yes |
| 27 | 41924298176 | afaec06d | 2026-11-04 22:19 | failure | 1 | 58 | no | yes |

## Table B — lanes of special interest

Counts over the **20 non-cancelled runs**. Right-hand column: what the same job did inside the cancelled runs among the last 20 completed (run-level concurrency cancellations, reported separately, not counted left).

| exact job name | runs present | success | failure | cancelled | skipped | other | failure run ids | cancelled run ids (non-cancelled runs) | in cancelled runs (last 20): failure / cancelled |
|---|---|---|---|---|---|---|---|---|---|
| `E2E Core Flow (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Core Flow (Android) / e2e_android` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `E2E Core Flow (Android, live-sync)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Core Flow (Android, live-sync) / e2e_android` | 19 | 18 | 1 | 0 | 0 | 0 | 42802266653 | - | F: - / C: - |
| `E2E Core Flow (iOS)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Core Flow (iOS) / e2e_ios` | 19 | 18 | 1 | 0 | 0 | 0 | 41944390485 | - | F: - / C: 43380364256, 43363822463, 43004030588 |
| `E2E Core Flow (iOS, live-sync)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Core Flow (iOS, live-sync) / e2e_ios` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43380364256, 43363822463, 43004030588 |
| `Soak Core (pr profile)` | 0 | 0 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `Soak Core (pr profile) / e2e_soak_core_nightly` | 20 | 0 | 0 | 0 | 20 | 0 | - | - | F: - / C: - |
| `Soak Core (pr profile) / e2e_soak_core_pr` | 20 | 20 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43004030588 |
| `Soak Core (pr profile) / e2e_soak_core_weekly` | 20 | 0 | 0 | 0 | 20 | 0 | - | - | F: - / C: - |
| `Debug Builds` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `Debug Builds / Android (arm)` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `Debug Builds / Android (arm64)` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43004030588 |
| `Debug Builds / Android (x64)` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `Debug Builds / iOS` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43380364256, 43363822463, 43004030588 |
| `Dependency Audit / cargo audit (RustSec advisories)` | 20 | 19 | 1 | 0 | 0 | 0 | 43459825681 | - | F: - / C: 43459785700 |
| `Rust Checks / e2e tooling (hermetic relay + wire proxy)` | 60 | 20 | 0 | 0 | 40 | 0 | - | - | F: - / C: 43459785700 |
| `Rust Checks / group input is known` | 60 | 0 | 0 | 0 | 60 | 0 | - | - | F: - / C: - |
| `Rust Checks / haven-core` | 60 | 20 | 0 | 0 | 40 | 0 | - | - | F: - / C: 43813027007, 43459785700 |
| `Rust Checks / haven-core suite (stable)` | 60 | 18 | 2 | 0 | 40 | 0 | 42802266653, 42380055887 | - | F: - / C: 43813027007, 43459785700 |
| `Rust Checks / logscan tooling (runtime log-privacy scanner)` | 60 | 20 | 0 | 0 | 40 | 0 | - | - | F: - / C: 43459785700 |
| `Rust Checks / rust_builder (FFI surface)` | 60 | 19 | 1 | 0 | 40 | 0 | 43813324122 | - | F: - / C: 43813027007, 43459785700 |
| `Rust Checks / soak tooling (Tier-1 soak rig)` | 60 | 20 | 0 | 0 | 40 | 0 | - | - | F: - / C: 43813027007, 43459785700 |
| `Cross-Platform Compile / Android (arm64)` | 20 | 19 | 1 | 0 | 0 | 0 | 43813324122 | - | F: - / C: 43459785700 |
| `Cross-Platform Compile / Apple (macOS + iOS)` | 20 | 19 | 1 | 0 | 0 | 0 | 43813324122 | - | F: - / C: 43813027007, 43459785700, 43363822463 |
| `Cross-Platform Compile / Windows (x64)` | 20 | 19 | 1 | 0 | 0 | 0 | 43813324122 | - | F: - / C: 43813027007, 43459785700 |
| `Coverage / Flutter Coverage` | 20 | 19 | 1 | 0 | 0 | 0 | 42380055887 | - | F: 43004030588 / C: 43813027007, 43459785700 |
| `Coverage / Rust Coverage` | 20 | 19 | 1 | 0 | 0 | 0 | 42380055887 | - | F: - / C: 43813027007, 43459785700 |
| `Repo Guards / Static checks` | 20 | 20 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43813027007, 43459785700 |

Notes on Table B:
- `Rust Checks / *` rows: `ci.yml` calls `rust-check.yml` three times (groups core / suite / tooling) and GitHub gives all three calls the identical caller name `Rust Checks`, so every `Rust Checks / X` name appears **3 times per run** (one instance runs, the other two are skipped by the `group` input; `group input is known` was skipped in all 60 instances in the window). Counts are per job instance (60 per 20 runs). Names alone cannot tell the three calls apart.
- Bare caller names without ` / ` (e.g. `Debug Builds`, `E2E Core Flow (iOS)`, `Soak Core (pr profile)`) are what GitHub shows when the whole reusable call was skipped at the caller level (runs where an upstream needed job failed or was cancelled). In those runs the ` / ` job rows are absent, which is why `runs present` is below 20 for them.
- `Soak Core (pr profile) / e2e_soak_core_nightly` and `/ e2e_soak_core_weekly` are always skipped in `ci.yml` (profile-gated); only `/ e2e_soak_core_pr` runs.

## Table C — all other jobs

Counts over the **20 non-cancelled runs**. Right-hand column: what the same job did inside the cancelled runs among the last 20 completed (run-level concurrency cancellations, reported separately, not counted left).

| exact job name | runs present | success | failure | cancelled | skipped | other | failure run ids | cancelled run ids (non-cancelled runs) | in cancelled runs (last 20): failure / cancelled |
|---|---|---|---|---|---|---|---|---|---|
| `E2E Background Catch-up (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Background Catch-up (Android) / e2e_background_catchup` | 19 | 18 | 1 | 0 | 0 | 0 | 41944390485 | - | F: 43363822463 / C: 43004030588 |
| `E2E Clock Skew (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Clock Skew (Android) / e2e_clock_skew` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `E2E FGS Publish (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E FGS Publish (Android) / e2e_fgs_publish` | 19 | 17 | 2 | 0 | 0 | 0 | 43504472962, 42802266653 | - | F: - / C: - |
| `E2E Integration Tests (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Integration Tests (Android) / e2e_integration` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43004030588 |
| `E2E KeyPackage Rotation (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E KeyPackage Rotation (Android) / e2e_kp_rotation` | 19 | 17 | 2 | 0 | 0 | 0 | 43391026631, 42392657873 | - | F: - / C: - |
| `E2E Location Provider Toggle (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Location Provider Toggle (Android) / e2e_location_provider_toggle` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43004030588 |
| `E2E Network Reconnect (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Network Reconnect (Android) / e2e_network_reconnect` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `E2E Permission Revocation (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Permission Revocation (Android) / e2e_permission_revocation` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43004030588 |
| `E2E Public Profile (Android + iOS)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Public Profile (Android + iOS) / e2e_profile_android` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `E2E Public Profile (Android + iOS) / e2e_profile_ios` | 19 | 18 | 1 | 0 | 0 | 0 | 41924298176 | - | F: - / C: 43380364256, 43004030588 |
| `E2E Real GPS (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Real GPS (Android) / e2e_real_gps` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `E2E Real GPS (iOS)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Real GPS (iOS) / e2e_ios_real_gps` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43380364256, 43363822463, 43004030588 |
| `E2E Relay Customization (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E Relay Customization (Android) / e2e_relay_customization` | 19 | 18 | 1 | 0 | 0 | 0 | 43276482370 | - | F: - / C: 43004030588 |
| `E2E iOS Auth Tier (When In Use vs Always)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E iOS Auth Tier (When In Use vs Always) / e2e_ios_auth_tier` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43363822463, 43004030588 |
| `E2E iOS Background Publish` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `E2E iOS Background Publish / e2e_ios_bg_publish (always-live-sync)` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43380364256, 43363822463, 43004030588 |
| `E2E iOS Background Publish / e2e_ios_bg_publish (when-in-use-live-sync)` | 19 | 17 | 2 | 0 | 0 | 0 | 42456694728, 41924298176 | - | F: - / C: 43380364256, 43363822463, 43004030588 |
| `E2E iOS Background Publish / e2e_ios_bg_publish (when-in-use-poll)` | 19 | 19 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43380364256, 43004030588 |
| `Flutter Checks / flutter analyze` | 20 | 19 | 1 | 0 | 0 | 0 | 42754106205 | - | F: - / C: 43459785700 |
| `Launch Gate (Android)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `Launch Gate (Android) / Release APK: launch, relaunch and upgrade` | 2 | 2 | 0 | 0 | 0 | 0 | - | - | F: - / C: - |
| `Launch Gate (iOS)` | 1 | 0 | 0 | 0 | 1 | 0 | - | - | F: - / C: - |
| `Launch Gate (iOS) / Simulator launch, relaunch and upgrade` | 2 | 2 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43868543765 |
| `Localization / ARB parity + gen-l10n` | 20 | 20 | 0 | 0 | 0 | 0 | - | - | F: - / C: 43459785700 |

## Table D — `soak-nightly.yml` (last 20 completed, any event)

| # | run id | sha8 | created (UTC) | event | branch | conclusion | attempt | non-skipped jobs: conclusion |
|---|---|---|---|---|---|---|---|---|
| 1 | 44431373162 | 7496eb47 | 2026-11-19 00:44 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 2 | 44210288480 | 7496eb47 | 2026-11-18 00:44 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 3 | 43989976911 | 7496eb47 | 2026-11-17 00:43 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 4 | 43782593066 | c7cf9ec8 | 2026-11-16 00:48 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 5 | 43535800843 | 6394cf4a | 2026-11-14 00:40 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 6 | 43339352112 | 56071585 | 2026-11-13 00:43 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 7 | 43129368527 | a45ab2d8 | 2026-11-12 00:43 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 8 | 42933397476 | f1dd1460 | 2026-11-11 00:42 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 9 | 42730176457 | 396b7717 | 2026-11-10 00:41 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 10 | 42541912371 | f50e21bc | 2026-11-09 00:45 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 11 | 42319653997 | efc8fcfe | 2026-11-07 00:40 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 12 | 42138663146 | efc8fcfe | 2026-11-06 00:41 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 13 | 41943215540 | afaec06d | 2026-11-05 00:41 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 14 | 41748658816 | 7def22b3 | 2026-11-04 00:41 | schedule | main | success | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 15 | 41554734137 | e740de96 | 2026-11-03 00:42 | schedule | main | failure | 2 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: failure; Soak Core (nightly, s2) / e2e_soak_core_nightly: failure; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: failure |
| 16 | 41368729073 | b78ded69 | 2026-11-02 00:44 | schedule | main | failure | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: success; Soak Core (nightly, s3) / e2e_soak_core_nightly: failure; Soak Core (nightly, s4) / e2e_soak_core_nightly: failure |
| 17 | 41151567030 | f85f9800 | 2026-10-31 00:41 | schedule | main | failure | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: failure; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |
| 18 | 40982158945 | a7a8ab20 | 2026-10-30 00:50 | schedule | main | failure | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: success; Soak Core (nightly, s2) / e2e_soak_core_nightly: failure; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: failure |
| 19 | 40796541561 | a7a8ab20 | 2026-10-29 00:49 | schedule | main | failure | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: failure; Soak Core (nightly, s2) / e2e_soak_core_nightly: failure; Soak Core (nightly, s3) / e2e_soak_core_nightly: failure; Soak Core (nightly, s4) / e2e_soak_core_nightly: failure |
| 20 | 40611236976 | a7a8ab20 | 2026-10-28 00:49 | schedule | main | failure | 1 | Derive the slot seeds: success; File the night's soak issue: success; Soak Core (nightly, s1) / e2e_soak_core_nightly: failure; Soak Core (nightly, s2) / e2e_soak_core_nightly: failure; Soak Core (nightly, s3) / e2e_soak_core_nightly: success; Soak Core (nightly, s4) / e2e_soak_core_nightly: success |

Per-job aggregate over these 20 runs:

| exact job name | success | failure | cancelled | skipped | other | failure run ids |
|---|---|---|---|---|---|---|
| `Derive the slot seeds` | 20 | 0 | 0 | 0 | 0 | - |
| `File the night's soak issue` | 20 | 0 | 0 | 0 | 0 | - |
| `Soak Core (nightly, s1) / e2e_soak_core_nightly` | 17 | 3 | 0 | 0 | 0 | 41554734137, 40796541561, 40611236976 |
| `Soak Core (nightly, s1) / e2e_soak_core_pr` | 0 | 0 | 0 | 20 | 0 | - |
| `Soak Core (nightly, s1) / e2e_soak_core_weekly` | 0 | 0 | 0 | 20 | 0 | - |
| `Soak Core (nightly, s2) / e2e_soak_core_nightly` | 15 | 5 | 0 | 0 | 0 | 41554734137, 41151567030, 40982158945, 40796541561, 40611236976 |
| `Soak Core (nightly, s2) / e2e_soak_core_pr` | 0 | 0 | 0 | 20 | 0 | - |
| `Soak Core (nightly, s2) / e2e_soak_core_weekly` | 0 | 0 | 0 | 20 | 0 | - |
| `Soak Core (nightly, s3) / e2e_soak_core_nightly` | 18 | 2 | 0 | 0 | 0 | 41368729073, 40796541561 |
| `Soak Core (nightly, s3) / e2e_soak_core_pr` | 0 | 0 | 0 | 20 | 0 | - |
| `Soak Core (nightly, s3) / e2e_soak_core_weekly` | 0 | 0 | 0 | 20 | 0 | - |
| `Soak Core (nightly, s4) / e2e_soak_core_nightly` | 16 | 4 | 0 | 0 | 0 | 41554734137, 41368729073, 40982158945, 40796541561 |
| `Soak Core (nightly, s4) / e2e_soak_core_pr` | 0 | 0 | 0 | 20 | 0 | - |
| `Soak Core (nightly, s4) / e2e_soak_core_weekly` | 0 | 0 | 0 | 20 | 0 | - |

- Every `e2e_soak_core_nightly` failure has first failing step `Run the soak (nightly profile)`.
- Run 41554734137 is attempt 2 (latest attempt: s1, s2, s4 failed). Its attempt 1 (read via `/runs/41554734137/attempts/1/jobs`): s1, s3, s4 failed, s2 passed. So a re-run of the same commit and same night did not pass; the failing slot set changed (s3 failed then passed; s2 passed then failed).
- The last 14 nightly runs (2026-11-04 .. 2026-11-19, 41748658816 .. 44431373162) are all green; the 6 failures are 2026-10-28 .. 2026-11-03.

## Section E — failure classification (failures in NON-cancelled `ci.yml` runs)

Method: first step with conclusion `failure` from `GET /actions/jobs/{id}`. Re-run check: every run in the window has `run_attempt = 1`, and `GET /actions/runs?head_sha=<sha>` found **no other `CI` run for any failing SHA** (other workflows on those SHAs exist but are not `ci.yml`). So no failure in the window has a same-commit re-run, and none can be labelled "passed on re-run of the same commit". The column "next newer main run" shows what the same job did in the next newer `main` push run (a different commit), for context only.

| run id | sha8 | exact job name | first failing step | next newer main run: same job | label |
|---|---|---|---|---|---|
| 43813324122 | 09986eb4 | `Cross-Platform Compile / Apple (macOS + iOS)` | Check macOS (aarch64-apple-darwin) | 43868543765 (cancelled run): success | failed and the next commit changed something (unknown) |
| 43813324122 | 09986eb4 | `Cross-Platform Compile / Windows (x64)` | Check Windows (x86_64-pc-windows-msvc) | 43868543765 (cancelled run): success | failed and the next commit changed something (unknown) |
| 43813324122 | 09986eb4 | `Rust Checks / rust_builder (FFI surface)` | Clippy | 43868543765 (cancelled run): success, skipped, skipped | failed and the next commit changed something (unknown) |
| 43813324122 | 09986eb4 | `Cross-Platform Compile / Android (arm64)` | Check Android (aarch64-linux-android) | 43868543765 (cancelled run): success | failed and the next commit changed something (unknown) |
| 43504472962 | 6394cf4a | `E2E FGS Publish (Android) / e2e_fgs_publish` | Run the FGS publish proof on the emulator | 43569623500 (success run): success | failed and the next commit changed something (unknown) |
| 43459825681 | 7c3ea751 | `Dependency Audit / cargo audit (RustSec advisories)` | Run cargo audit (haven-core) | 43504472962 (failure run): success | failed and the next commit changed something (unknown) |
| 43391026631 | af2fe5ab | `E2E KeyPackage Rotation (Android) / e2e_kp_rotation` | Run the KeyPackage-rotation proof on the emulator | 43459785700 (cancelled run): job absent | failed and the next commit changed something (unknown) |
| 43276482370 | fb782203 | `E2E Relay Customization (Android) / e2e_relay_customization` | Run relay-customization tests on the emulator | 43314988591 (success run): success | failed and the next commit changed something (unknown) |
| 42802266653 | f1dd1460 | `Rust Checks / haven-core suite (stable)` | Run tests | 43004030588 (cancelled run): success, skipped, skipped | failed and the next commit changed something (unknown) |
| 42802266653 | f1dd1460 | `E2E Core Flow (Android, live-sync) / e2e_android` | Run e2e_combined on the emulator | 43004030588 (cancelled run): success | failed and the next commit changed something (unknown) |
| 42802266653 | f1dd1460 | `E2E FGS Publish (Android) / e2e_fgs_publish` | Run the FGS publish proof on the emulator | 43004030588 (cancelled run): success | failed and the next commit changed something (unknown) |
| 42754106205 | 378b7394 | `Flutter Checks / flutter analyze` | Analyze (errors + warnings gate; infos advisory) | 42802266653 (failure run): success | failed and the next commit changed something (unknown) |
| 42456694728 | f50e21bc | `E2E iOS Background Publish / e2e_ios_bg_publish (when-in-use-live-sync)` | Run the iOS background-publish lane (when-in-use-live-sync) | 42647620766 (success run): success | failed and the next commit changed something (unknown) |
| 42392657873 | 0e12b60a | `E2E KeyPackage Rotation (Android) / e2e_kp_rotation` | Build KeyPackage-rotation test APK | 42456694728 (failure run): success | failed and the next commit changed something (unknown) |
| 42380055887 | 5d61b899 | `Coverage / Flutter Coverage` | Run tests with coverage | 42392657873 (failure run): success | failed and the next commit changed something (unknown) |
| 42380055887 | 5d61b899 | `Coverage / Rust Coverage` | Run tests with coverage | 42392657873 (failure run): success | failed and the next commit changed something (unknown) |
| 42380055887 | 5d61b899 | `Rust Checks / haven-core suite (stable)` | Run tests | 42392657873 (failure run): success, skipped, skipped | failed and the next commit changed something (unknown) |
| 41944390485 | 37da8298 | `E2E Core Flow (iOS) / e2e_ios` | Assert wire privacy invariants | 41977768023 (success run): success | failed and the next commit changed something (unknown) |
| 41944390485 | 37da8298 | `E2E Background Catch-up (Android) / e2e_background_catchup` | Run background catch-up phases on the emulator | 41977768023 (success run): success | failed and the next commit changed something (unknown) |
| 41924298176 | afaec06d | `E2E Public Profile (Android + iOS) / e2e_profile_ios` | Run e2e_profile_sharing on the simulator | 41944390485 (failure run): success | failed and the next commit changed something (unknown) |
| 41924298176 | afaec06d | `E2E iOS Background Publish / e2e_ios_bg_publish (when-in-use-live-sync)` | Run the iOS background-publish lane (when-in-use-live-sync) | 41944390485 (failure run): success | failed and the next commit changed something (unknown) |

Outside the non-cancelled window but relevant: run 41671663759 (sha 7def22b3, 2026-11-03) is the only `ci.yml` run in the 60 read with `run_attempt = 2`; its latest attempt is `success`. Its attempt-1 jobs were not read.

Failures inside cancelled runs (not counted as genuine above, listed for completeness): 43363822463 `E2E Background Catch-up (Android) / e2e_background_catchup`; 43004030588 `Coverage / Flutter Coverage`.

## Section F — exact job names in the newest successful main push run (43705144915, c7cf9ec8, 2026-11-15)

46 distinct names (60 job rows; `Rust Checks / *` names occur 3x each).

```
Coverage / Flutter Coverage
Coverage / Rust Coverage
Cross-Platform Compile / Android (arm64)
Cross-Platform Compile / Apple (macOS + iOS)
Cross-Platform Compile / Windows (x64)
Debug Builds / Android (arm)
Debug Builds / Android (arm64)
Debug Builds / Android (x64)
Debug Builds / iOS
Dependency Audit / cargo audit (RustSec advisories)
E2E Background Catch-up (Android) / e2e_background_catchup
E2E Clock Skew (Android) / e2e_clock_skew
E2E Core Flow (Android) / e2e_android
E2E Core Flow (Android, live-sync) / e2e_android
E2E Core Flow (iOS) / e2e_ios
E2E Core Flow (iOS, live-sync) / e2e_ios
E2E FGS Publish (Android) / e2e_fgs_publish
E2E Integration Tests (Android) / e2e_integration
E2E KeyPackage Rotation (Android) / e2e_kp_rotation
E2E Location Provider Toggle (Android) / e2e_location_provider_toggle
E2E Network Reconnect (Android) / e2e_network_reconnect
E2E Permission Revocation (Android) / e2e_permission_revocation
E2E Public Profile (Android + iOS) / e2e_profile_android
E2E Public Profile (Android + iOS) / e2e_profile_ios
E2E Real GPS (Android) / e2e_real_gps
E2E Real GPS (iOS) / e2e_ios_real_gps
E2E Relay Customization (Android) / e2e_relay_customization
E2E iOS Auth Tier (When In Use vs Always) / e2e_ios_auth_tier
E2E iOS Background Publish / e2e_ios_bg_publish (always-live-sync)
E2E iOS Background Publish / e2e_ios_bg_publish (when-in-use-live-sync)
E2E iOS Background Publish / e2e_ios_bg_publish (when-in-use-poll)
Flutter Checks / flutter analyze
Launch Gate (Android) / Release APK: launch, relaunch and upgrade
Launch Gate (iOS) / Simulator launch, relaunch and upgrade
Localization / ARB parity + gen-l10n
Repo Guards / Static checks
Rust Checks / e2e tooling (hermetic relay + wire proxy)
Rust Checks / group input is known
Rust Checks / haven-core
Rust Checks / haven-core suite (stable)
Rust Checks / logscan tooling (runtime log-privacy scanner)
Rust Checks / rust_builder (FFI surface)
Rust Checks / soak tooling (Tier-1 soak rig)
Soak Core (pr profile) / e2e_soak_core_nightly
Soak Core (pr profile) / e2e_soak_core_pr
Soak Core (pr profile) / e2e_soak_core_weekly
```

Per-name conclusion in that run: all `success` except these `skipped`: `Rust Checks / e2e tooling (hermetic relay + wire proxy)`, `Rust Checks / group input is known`, `Rust Checks / haven-core suite (stable)`, `Rust Checks / haven-core`, `Rust Checks / logscan tooling (runtime log-privacy scanner)`, `Rust Checks / rust_builder (FFI surface)`, `Rust Checks / soak tooling (Tier-1 soak rig)`, `Soak Core (pr profile) / e2e_soak_core_nightly`, `Soak Core (pr profile) / e2e_soak_core_weekly`.

## Section G — not read / not verified

- Logs were not downloaded for any job; classification uses step names only. No cause is asserted for any failure.
- Attempt-1 jobs of `ci.yml` run 41671663759 (the one `run_attempt = 2` run in range) were not read; it lies outside both windows.
- The three `Rust Checks` calls cannot be distinguished by job name; per-call attribution is inferred only from which job ran (group gating), not from an API field.
- Only the `latest` attempt of each `ci.yml` run was read (all runs in both windows have `run_attempt = 1`, so nothing is hidden by that filter).
- Data were fetched from the public REST API with the same endpoints and filters the query line names. The raw JSON is not committed; two runs (43705144915 success, 42802266653 failure) were re-read by run id against this table when it was recorded.
