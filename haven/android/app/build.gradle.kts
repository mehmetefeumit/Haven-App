import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.haven.app"
    compileSdk = flutter.compileSdkVersion
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
        applicationId = "com.haven.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
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
