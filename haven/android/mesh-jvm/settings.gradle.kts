// The mesh radio's pure Kotlin, built for the JVM with no Android SDK
// (docs/BLUETOOTH_MESH_M3_DESIGN.md §B.1, §B.10). Its own build: not included
// in ../settings.gradle.kts, so the app's build does not change.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

rootProject.name = "mesh-jvm"
