package com.oblivioustech.haven

import android.content.Context
import android.content.SharedPreferences

/** What a boot or an app update does about background sharing. */
enum class ResumeDecision { START, NOTIFY, NOTHING }

/**
 * The resume rule, owner-directed 2026-11-26 (OD-R2/OD-R3). The Dart twin is
 * `decideSystemResume` in `background_resume_gate.dart`; the foreground-service
 * isolate applies the same rule to every system start the plugin makes.
 *
 * - [uiVisible]: the visible activity starts the service itself, and a notice
 *   would land under the user's finger.
 * - [serviceRunning]: nothing to resume, and a second start would rebuild the
 *   running task.
 * - [serviceStopped]: the plugin's status reads `API_STOP` — Haven stopped the
 *   service on purpose (toggle off, identity deleted, a refused system start)
 *   or it never ran. Identity deletion leaves the sharing preference true, so
 *   consent alone would nag a logged-out user.
 * - Everything else is the resume predicate: consent to the CURRENT background
 *   disclosure, a foreground location grant, and on Android 11+ the
 *   background grant, without which a boot-started service is location-blind
 *   (11-13) or refused outright (14+).
 */
fun decideResume(
    uiVisible: Boolean,
    serviceRunning: Boolean,
    serviceStopped: Boolean,
    sharingOn: Boolean,
    disclosureCurrent: Boolean,
    locationGranted: Boolean,
    backgroundRequired: Boolean,
    backgroundGranted: Boolean,
): ResumeDecision = when {
    uiVisible || serviceRunning || serviceStopped || !sharingOn -> ResumeDecision.NOTHING
    !disclosureCurrent || !locationGranted || (backgroundRequired && !backgroundGranted) ->
        ResumeDecision.NOTIFY
    else -> ResumeDecision.START
}

/**
 * The Dart preference keys this side reads, as `shared_preferences` stores
 * them: in `FlutterSharedPreferences`, behind the `flutter.` prefix, an `int`
 * as a `Long`. Guard 14k pins each literal against its Dart constant.
 */
object HavenPrefs {
    const val FILE = "FlutterSharedPreferences"
    const val SHARING = "flutter.haven.background_sharing"
    const val DISCLOSURE_FOREGROUND = "flutter.haven.location.disclosure_accepted"
    const val DISCLOSURE_BACKGROUND = "flutter.haven.location.disclosure_background_accepted"
    const val DISCLOSURE_BACKGROUND_VERSION = "flutter.haven.location.disclosure_background_version"
    const val LOCALE = "flutter.haven.locale.tag"

    /** Twin of Dart's `kAndroidBackgroundDisclosureVersion`. */
    const val BACKGROUND_DISCLOSURE_VERSION = 2L

    fun open(context: Context): SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun sharingOn(prefs: SharedPreferences): Boolean = bool(prefs, SHARING)

    /**
     * Twin of Dart's `backgroundResumeDisclosureAccepted`. A missing key, or
     * one of another type, is a refusal.
     */
    fun resumeDisclosureAccepted(prefs: SharedPreferences): Boolean {
        val version = try {
            if (prefs.contains(DISCLOSURE_BACKGROUND_VERSION)) {
                prefs.getLong(DISCLOSURE_BACKGROUND_VERSION, 0L)
            } else {
                0L
            }
        } catch (_: ClassCastException) {
            0L
        }
        return bool(prefs, DISCLOSURE_FOREGROUND) &&
            bool(prefs, DISCLOSURE_BACKGROUND) &&
            version >= BACKGROUND_DISCLOSURE_VERSION
    }

    /** The in-app language override: a bare language code, or null. */
    fun localeTag(prefs: SharedPreferences): String? = try {
        prefs.getString(LOCALE, null)?.takeIf { it.isNotBlank() }
    } catch (_: ClassCastException) {
        null
    }

    private fun bool(prefs: SharedPreferences, key: String): Boolean = try {
        prefs.getBoolean(key, false)
    } catch (_: ClassCastException) {
        false
    }
}
