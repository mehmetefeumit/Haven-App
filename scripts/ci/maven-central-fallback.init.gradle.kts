// Gradle init script: no build in the tree depends on the Gradle Plugin Portal
// for an artifact Maven Central holds.
//
// Why: Flutter's own Gradle plugin build ($FLUTTER_ROOT/packages/flutter_tools/
// gradle, pulled in by haven/android/settings.gradle.kts `includeBuild`)
// declares no plugin repository, so Gradle resolves its build classpath
// (kotlin-dsl, the Kotlin JVM plugin, kotlin-stdlib, ...) from the Plugin
// Portal alone, which answers every artifact it does not host with a 303 to
// repo.maven.apache.org. Included builds never inherit the including build's
// `pluginManagement` repositories, so when that path answers 404 for a file
// Central has, the build dies in settings evaluation with "Could not find
// org.jetbrains.kotlin:kotlin-stdlib:<v>", the Portal the only place searched
// (CI run 44503460373 job 135506633262; run 44532048143 jobs 135614752253 and
// 135614753425). Gradle then caches the miss, so a retry in the same job fails
// in under a second. An init script is the one hook that reaches Flutter's
// build; Haven's own repository lists name the mirror themselves.
//
// For a build that declares no plugin repository this declares Central, then
// Google's Central mirror (asked only after a 404), then the Portal for the
// plugins only it hosts. A build that declares its own gets the mirror
// appended. CI installs this into $GRADLE_USER_HOME/init.d from
// scripts/ci/build_apk_with_retry.sh and scripts/build_release.sh; a developer
// may copy it there too.

val centralMirror = uri("https://maven-central.storage-download.googleapis.com/maven2/")

fun RepositoryHandler.appendCentralMirror() {
    if (none { it is MavenArtifactRepository && it.url == centralMirror }) {
        maven { url = centralMirror }
    }
}

settingsEvaluated {
    pluginManagement.repositories {
        if (isEmpty()) {
            mavenCentral()
            appendCentralMirror()
            // Gradle's implicit default, which any declaration above drops.
            gradlePluginPortal()
        } else {
            appendCentralMirror()
        }
    }
    dependencyResolutionManagement.repositories {
        if (isNotEmpty()) appendCentralMirror()
    }
}
