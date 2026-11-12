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
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
    // Resolves a project's toolchain JDK request by auto-downloading from
    // Adoptium via api.foojay.io, so developers and CI do not need a matching
    // system JDK pre-installed. The Daemon JVM is not its work: Gradle takes
    // that download from the URLs in gradle/gradle-daemon-jvm.properties.
    // Not 0.10.0 again: it reads JvmVendorSpec.IBM_SEMERU, which Gradle 9.0
    // removed.
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

include(":app")
