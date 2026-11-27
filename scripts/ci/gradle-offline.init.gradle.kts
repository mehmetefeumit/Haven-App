// Gradle init script: this build, and every build it includes (Flutter's
// flutter_tools plugin build among them), resolves from the local dependency
// cache only. A coordinate the cache lacks fails as "No cached version of
// <coordinate> available for offline mode"; nothing is fetched.
//
// Why: an Android lane builds from the cache android-gradle-deps.yml resolved
// and verified once for the whole run, so a Plugin Portal or Maven Central blip
// can no longer fail a lane at "Build E2E test APK" (CI runs 45142774793 and
// 45012283370), and a gap is the deps job's, named, never a network retry.
//
// At the top level, not in `settingsEvaluated`: the settings script's own
// `plugins {}` (flutter-plugin-loader, foojay) resolve while settings are being
// evaluated, before that hook fires, and a settings plugin missing from the
// cache was then fetched over HTTP (measured with Gradle 9.5.0 while this was
// written). Gradle runs init scripts for included builds too, so this line
// reaches them; scripts/ci/gradle_deps.sh proves it on every deps job with a
// composite canary whose included build asks for a coordinate nobody has.
//
// Offline, a missing PLUGIN MARKER does not say "offline mode": Gradle reads it
// through a lenient view and prints only "could not resolve plugin artifact".
// So build_apk_with_retry.sh retries no resolution failure while offline.
//
// Installed into $GRADLE_USER_HOME/init.d by scripts/ci/build_apk_with_retry.sh
// and scripts/build_release.sh only when HAVEN_GRADLE_OFFLINE=1, and removed
// when they exit, so no later Gradle call in the job runs offline unasked.
gradle.startParameter.isOffline = true
