package com.oblivioustech.haven

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Resumes background sharing after a reboot or an app update, or posts the
 * resume notice when a system start is not allowed ([decideResume]).
 *
 * Replaces the plugin's `RebootReceiver` (removed in the manifest): that one
 * starts on its stored options, which the OLD build wrote, so the first update
 * that ships a fix could not take part, and it cannot see a permission revoked
 * while Haven was not running. Not exported: only the system sends these two
 * broadcasts. Logs nothing (Security Rule 15).
 */
class BootResumeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                BootResume.run(context.applicationContext)
        }
    }
}
