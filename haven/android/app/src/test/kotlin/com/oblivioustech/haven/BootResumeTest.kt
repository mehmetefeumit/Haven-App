package com.oblivioustech.haven

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The boot/update resume rule (owner-directed 2026-11-26, OD-R2/OD-R3). Named
 * cases only: each is a promise to the user, and each fails when it breaks.
 */
class BootResumeTest {
    /** Everything allowed: the one input set that starts sharing. */
    private fun decide(
        uiVisible: Boolean = false,
        serviceRunning: Boolean = false,
        serviceStopped: Boolean = false,
        sharingOn: Boolean = true,
        disclosureCurrent: Boolean = true,
        locationGranted: Boolean = true,
        backgroundRequired: Boolean = true,
        backgroundGranted: Boolean = true,
    ) = decideResume(
        uiVisible = uiVisible,
        serviceRunning = serviceRunning,
        serviceStopped = serviceStopped,
        sharingOn = sharingOn,
        disclosureCurrent = disclosureCurrent,
        locationGranted = locationGranted,
        backgroundRequired = backgroundRequired,
        backgroundGranted = backgroundGranted,
    )

    @Test
    fun everyConditionHeldResumesSharing() {
        assertEquals(ResumeDecision.START, decide())
    }

    @Test
    fun sharingTurnedOffNeverStartsOrNotifies() {
        assertEquals(ResumeDecision.NOTHING, decide(sharingOn = false))
        assertEquals(
            ResumeDecision.NOTHING,
            decide(sharingOn = false, disclosureCurrent = false, backgroundGranted = false),
        )
    }

    @Test
    fun aServiceHavenStoppedStaysStoppedEvenWithSharingStillOn() {
        // Identity deletion stops the service but keeps the sharing preference.
        assertEquals(ResumeDecision.NOTHING, decide(serviceStopped = true))
        assertEquals(
            ResumeDecision.NOTHING,
            decide(serviceStopped = true, backgroundGranted = false),
        )
    }

    @Test
    fun aVisibleUiStartsSharingItselfSoTheReceiverDoesNothing() {
        assertEquals(ResumeDecision.NOTHING, decide(uiVisible = true))
        assertEquals(ResumeDecision.NOTHING, decide(uiVisible = true, disclosureCurrent = false))
    }

    @Test
    fun aRunningServiceIsNotStartedAgain() {
        assertEquals(ResumeDecision.NOTHING, decide(serviceRunning = true))
    }

    @Test
    fun anOutdatedDisclosureNotifiesInsteadOfStarting() {
        // The first update that ships OD-R3: nobody has accepted version 2.
        assertEquals(ResumeDecision.NOTIFY, decide(disclosureCurrent = false))
    }

    @Test
    fun noForegroundLocationGrantNotifies() {
        assertEquals(ResumeDecision.NOTIFY, decide(locationGranted = false))
    }

    @Test
    fun android11PlusWithoutAllTheTimeNotifies() {
        assertEquals(ResumeDecision.NOTIFY, decide(backgroundGranted = false))
    }

    @Test
    fun android10NeedsNoBackgroundGrant() {
        assertEquals(
            ResumeDecision.START,
            decide(backgroundRequired = false, backgroundGranted = false),
        )
    }

    // --- The preferences, read as shared_preferences writes them. ---

    private val consented = mapOf(
        "flutter.haven.location.disclosure_accepted" to true,
        "flutter.haven.location.disclosure_background_accepted" to true,
        "flutter.haven.location.disclosure_background_version" to 2L,
    )

    @Test
    fun theVersionTwoDisclosureWithBothFlagsIsAccepted() {
        assertTrue(HavenPrefs.resumeDisclosureAccepted(FakePrefs(consented)))
        assertTrue(
            HavenPrefs.resumeDisclosureAccepted(
                FakePrefs(consented + ("flutter.haven.location.disclosure_background_version" to 3L)),
            ),
        )
    }

    @Test
    fun aVersionOneAcceptanceIsNotConsentToResume() {
        assertFalse(
            HavenPrefs.resumeDisclosureAccepted(
                FakePrefs(consented - "flutter.haven.location.disclosure_background_version"),
            ),
        )
        assertFalse(
            HavenPrefs.resumeDisclosureAccepted(
                FakePrefs(consented + ("flutter.haven.location.disclosure_background_version" to 1L)),
            ),
        )
    }

    @Test
    fun eachDisclosureFlagIsRequired() {
        for (key in listOf(
            "flutter.haven.location.disclosure_accepted",
            "flutter.haven.location.disclosure_background_accepted",
        )) {
            assertFalse(key, HavenPrefs.resumeDisclosureAccepted(FakePrefs(consented - key)))
            assertFalse(key, HavenPrefs.resumeDisclosureAccepted(FakePrefs(consented + (key to false))))
        }
    }

    @Test
    fun aValueOfTheWrongTypeIsARefusalNotACrash() {
        assertFalse(
            HavenPrefs.resumeDisclosureAccepted(
                FakePrefs(consented + ("flutter.haven.location.disclosure_background_version" to "2")),
            ),
        )
        assertFalse(
            HavenPrefs.resumeDisclosureAccepted(
                FakePrefs(consented + ("flutter.haven.location.disclosure_accepted" to "true")),
            ),
        )
        assertFalse(HavenPrefs.sharingOn(FakePrefs(mapOf("flutter.haven.background_sharing" to 1L))))
    }

    @Test
    fun theSharingPreferenceIsReadUnderItsFlutterKey() {
        assertTrue(HavenPrefs.sharingOn(FakePrefs(mapOf("flutter.haven.background_sharing" to true))))
        assertFalse(HavenPrefs.sharingOn(FakePrefs(mapOf("haven.background_sharing" to true))))
        assertFalse(HavenPrefs.sharingOn(FakePrefs(emptyMap())))
    }

    @Test
    fun theLanguageOverrideIsReadOnlyWhenSet() {
        assertEquals("de", HavenPrefs.localeTag(FakePrefs(mapOf("flutter.haven.locale.tag" to "de"))))
        assertNull(HavenPrefs.localeTag(FakePrefs(mapOf("flutter.haven.locale.tag" to " "))))
        assertNull(HavenPrefs.localeTag(FakePrefs(emptyMap())))
    }
}

/** Typed reads throw on a type mismatch, as Android's implementation does. */
private class FakePrefs(private val values: Map<String, Any>) : SharedPreferences {
    override fun getAll(): Map<String, *> = values

    override fun getString(key: String, defValue: String?): String? =
        values[key]?.let { it as String } ?: defValue

    override fun getStringSet(key: String, defValues: Set<String>?): Set<String>? = defValues

    override fun getInt(key: String, defValue: Int): Int = values[key]?.let { it as Int } ?: defValue

    override fun getLong(key: String, defValue: Long): Long = values[key]?.let { it as Long } ?: defValue

    override fun getFloat(key: String, defValue: Float): Float =
        values[key]?.let { it as Float } ?: defValue

    override fun getBoolean(key: String, defValue: Boolean): Boolean =
        values[key]?.let { it as Boolean } ?: defValue

    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = throw UnsupportedOperationException()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener,
    ) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener,
    ) = Unit
}
