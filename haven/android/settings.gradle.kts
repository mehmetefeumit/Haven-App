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
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    // Resolves toolchain JDK requests (including the Daemon JVM pin in
    // gradle/gradle-daemon-jvm.properties) by auto-downloading from Adoptium
    // via api.foojay.io. Keeps the build self-contained: developers and CI do
    // not need a matching system JDK pre-installed.
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}

include(":app")
