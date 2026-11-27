// Gradle init script: `havenResolveAll` resolves every resolvable
// configuration of every project — buildscript classpaths included — in this
// build and in every build it includes (Flutter's flutter_tools plugin build
// among them), NON-leniently, so the dependency cache it fills holds whatever
// an Android lane's build can ask for. Any configuration that does not
// resolve fails the task, every failure named.
//
// External modules only: a project dependency is built, not downloaded, and
// asking for its artifacts would compile the plugins instead of resolving them.
// No configuration is allowed to fail: the spike that introduced this found
// none that cannot resolve, so there is no allowlist to rot.
//
// One download is invisible to the enumeration, AGP's aapt2, which
// scripts/ci/build_apk_with_retry.sh --resolve-only has AGP resolve itself.
//
// Run by scripts/ci/gradle_deps.sh (the android-gradle-deps.yml job) through
// that --resolve-only mode, and by its strictness canary; never by a lane.

allprojects {
    val buildscriptConfigurations = buildscript.configurations
    val projectConfigurations = configurations
    val where = "${gradle.rootProject.name}${if (path == ":") "" else path}"
    tasks.register("havenResolveAll") {
        doLast {
            val failed = mutableListOf<String>()
            for ((kind, container) in listOf("buildscript" to buildscriptConfigurations, "project" to projectConfigurations)) {
                for (configuration in container.toList().filter { it.isCanBeResolved }) {
                    try {
                        configuration.incoming.artifactView {
                            lenient(false)
                            componentFilter { it is org.gradle.api.artifacts.component.ModuleComponentIdentifier }
                        }.files.files
                    } catch (e: Exception) {
                        failed += "$where $kind '${configuration.name}': ${e.message}"
                    }
                }
            }
            if (failed.isNotEmpty()) {
                throw GradleException("havenResolveAll: ${failed.size} configuration(s) did not resolve:\n" + failed.joinToString("\n"))
            }
        }
    }
}

// The top build's task also runs every included build's, so one invocation
// covers the composite; an included build has a parent and is wired by none.
if (gradle.parent == null) {
    gradle.rootProject {
        tasks.named("havenResolveAll") {
            dependsOn(gradle.includedBuilds.map { it.task(":havenResolveAll") })
        }
    }
}
