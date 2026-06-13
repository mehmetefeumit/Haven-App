import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.oblivioustech.haven"
    // compileSdk = which API surface is visible at compile time. Newer
    // androidx libraries pulled in by Flutter plugins (e.g. androidx.datastore
    // via shared_preferences_android) require compileSdk 36, and the Android
    // toolchain treats this as backward-compatible. Runtime behaviour is
    // governed by targetSdk below, not by this value — do NOT pin this lower
    // to control FGS-type or background-start behaviour.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.oblivioustech.haven"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion   // 23 — do not lower
        // targetSdk pins the runtime behaviour the app opts into. Keep at 35
        // (Android 15) so SDK upgrades never silently change FGS-type
        // enforcement or background-start behaviour. Bumping requires a
        // deliberate review of those Android behaviour changes.
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Load signing config from key.properties if available (for release builds).
    // For local development, falls back to debug signing.
    // CI builds should provide key.properties via secrets.
    val keyPropertiesFile = rootProject.file("key.properties")
    val useReleaseSigningConfig = keyPropertiesFile.exists()

    if (useReleaseSigningConfig) {
        val keyProperties = Properties()
        FileInputStream(keyPropertiesFile).use { keyProperties.load(it) }

        signingConfigs {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (useReleaseSigningConfig) {
                signingConfigs.getByName("release")
            } else {
                // Fallback to debug signing for local development
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // Workaround for https://github.com/flutter/flutter/issues/56591
    // The integration_test plugin is registered in GeneratedPluginRegistrant
    // even though it's a dev dependency, causing release builds to fail.
    // compileOnly makes the class available at compile time without shipping it.
    compileOnly(project(":integration_test"))
}

flutter {
    source = "../.."
}

// ---------------------------------------------------------------------------
// Release secret hygiene — runs automatically on every *release* build.
//
//  1. checkNoCommittedSecrets : fails the build if the Stadia key (or any
//     UUID-shaped secret) is committed, or if the compile-time key-injection
//     seam in tiles.dart regresses. Pure grep over `git ls-files`.
//  2. verifyReleaseBuildPath  : fails a bare `flutter build --release` that did
//     NOT go through scripts/build_release.sh. That wrapper injects the key via
//     --dart-define-from-file AND forces --obfuscate (the flutter CLI has no
//     project default for either), then exports HAVEN_RELEASE_WRAPPER=1. So a
//     release can never ship with the placeholder key or without obfuscation.
//
// Wired in afterEvaluate because the Flutter Gradle plugin registers its
// variant tasks (preReleaseBuild) during the :app afterEvaluate. Debug/profile
// builds never trigger preReleaseBuild, so they are unaffected.
// ---------------------------------------------------------------------------
val repoRoot = rootProject.file("../..") // haven/android -> repo root (File)

val checkNoCommittedSecrets by tasks.registering(Exec::class) {
    group = "verification"
    description = "Fail the release build if a Stadia key/secret is committed."
    workingDir = repoRoot
    commandLine("bash", "scripts/ci/check_no_committed_secrets.sh")
}

val verifyReleaseBuildPath by tasks.registering {
    group = "verification"
    description = "Require release builds to go through scripts/build_release.sh."
    doFirst {
        if (System.getenv("HAVEN_RELEASE_WRAPPER") != "1") {
            throw GradleException(
                "Release builds must be produced with scripts/build_release.sh — it " +
                    "injects the Stadia API key and forces obfuscation, which a bare " +
                    "`flutter build --release` cannot. See haven/DEVELOPMENT.md. " +
                    "(To run a release build deliberately without the wrapper, set " +
                    "HAVEN_RELEASE_WRAPPER=1.)",
            )
        }
    }
}

afterEvaluate {
    tasks.matching { it.name == "preReleaseBuild" }.configureEach {
        dependsOn(checkNoCommittedSecrets, verifyReleaseBuildPath)
    }
}
