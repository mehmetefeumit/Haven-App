import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    // The version ../settings.gradle.kts pins for the app's Kotlin.
    kotlin("jvm") version "2.4.20"
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
}

// The fixtures the Rust tests read: the same files, never a copy.
val fixtures = layout.projectDirectory.dir("../../rust_builder/fixtures")

kotlin {
    // The app's own sources. With no android.jar on the classpath, an Android
    // import in this package is a compile error here.
    sourceSets["main"].kotlin.setSrcDirs(
        listOf("../app/src/main/kotlin/com/oblivioustech/haven/mesh/core"),
    )
    compilerOptions {
        // As ../app/build.gradle.kts; `-Xjdk-release` also keeps a newer JDK's
        // API out, whichever JDK runs the build.
        jvmTarget = JvmTarget.JVM_17
        freeCompilerArgs.add("-Xjdk-release=17")
        allWarningsAsErrors = true
        extraWarnings = true
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.test {
    useJUnit()
    inputs.dir(fixtures)
    systemProperty("mesh.fixtures", fixtures.asFile.path)
}
