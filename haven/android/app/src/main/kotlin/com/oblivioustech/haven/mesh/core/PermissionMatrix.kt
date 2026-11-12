package com.oblivioustech.haven.mesh.core

/** What the mesh asks of the user per API level, and whether its scan finds anything. */
object PermissionMatrix {
    const val BLUETOOTH_SCAN = "android.permission.BLUETOOTH_SCAN"
    const val BLUETOOTH_ADVERTISE = "android.permission.BLUETOOTH_ADVERTISE"
    const val BLUETOOTH_CONNECT = "android.permission.BLUETOOTH_CONNECT"

    private const val ANDROID_12 = 31
    private const val ANDROID_10 = 29

    /**
     * The runtime permissions asked for, and needed to start: Android 12's
     * one "Nearby devices" dialog, and nothing before it. Never location.
     */
    fun asked(api: Int): List<String> =
        if (api >= ANDROID_12) listOf(BLUETOOTH_SCAN, BLUETOOTH_ADVERTISE, BLUETOOTH_CONNECT) else emptyList()

    /**
     * Whether a scan is given results. From Android 12 the scan is declared
     * never to derive location; before, it needs location access the mesh does
     * not ask for, and a phone without it is found and cannot search.
     */
    fun canSearch(
        api: Int,
        fineLocation: Boolean,
        coarseLocation: Boolean,
        backgroundLocation: Boolean,
        locationOn: Boolean,
    ): Boolean = when {
        api >= ANDROID_12 -> true
        api >= ANDROID_10 -> fineLocation && backgroundLocation && locationOn
        else -> (fineLocation || coarseLocation) && locationOn
    }
}
