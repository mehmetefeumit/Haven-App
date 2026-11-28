pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        // Google's Maven Central mirror, asked only after Central answered
        // 404, and ahead of the Plugin Portal, whose redirect to Central has
        // answered 404 for files Central holds and killed this settings phase
        // on CI. This list also resolves the Flutter plugin's runtime
        // classpath; Flutter's included build gets the same order from
        // scripts/ci/maven-central-fallback.init.gradle.kts.
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    // Resolves toolchain JDK requests (including the Daemon JVM pin in
    // gradle/gradle-daemon-jvm.properties) by auto-downloading from Adoptium
    // via api.foojay.io. Keeps the build self-contained: developers and CI do
    // not need a matching system JDK pre-installed.
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}

include(":app")
