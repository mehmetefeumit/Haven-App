package com.oblivioustech.haven.mesh

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import com.oblivioustech.haven.mesh.core.ChannelWords
import com.oblivioustech.haven.mesh.core.Notice
import com.oblivioustech.haven.mesh.core.NoticePlan

/**
 * The mesh's notification channel and its four notices
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.5, §B.7, §O.1.6). Which notice,
 * under which id, is `NoticePlan`'s to say; this builds and posts it.
 *
 * A notice tells that the mesh is on, paused, about to turn off or off, and
 * nothing else: its title is the app's name and its text one of the six
 * strings the Dart side handed over, never built here — no count, no peer,
 * no address. Hidden on the lock screen, as the location notice is.
 */
// The service is started on Android 11 and later (`StartPolicy`), and nothing posts a notice without it: a channel is Android 8's.
@TargetApi(Build.VERSION_CODES.R)
class MeshNotices(private val context: Context, private val prefs: MeshPrefs) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    /** Made before the first notice, and again at a `sync`: its name is one of the six strings. */
    fun channel() {
        val channel = NotificationChannel(CHANNEL, prefs.copy(NoticePlan.CHANNEL) ?: TITLE, NotificationManager.IMPORTANCE_LOW)
        channel.lockscreenVisibility = Notification.VISIBILITY_SECRET
        manager.createNotificationChannel(channel)
    }

    /** With no string stored — a start nobody handed the words to — the title alone. */
    fun notice(notice: Notice): Notification {
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(TITLE)
            .setContentText(prefs.copy(notice.copy))
            .setContentIntent(tap(ChannelWords.OPEN_STATS))
            .setOngoing(notice.id == NoticePlan.ONGOING)
            .setVisibility(Notification.VISIBILITY_SECRET)
        if (notice.keepOn) {
            val icon: Icon? = null
            builder.addAction(Notification.Action.Builder(icon, prefs.copy(NoticePlan.KEEP_ON), tap(ChannelWords.KEEP_ON)).build())
        }
        return builder.build()
    }

    fun post(notice: Notice) = manager.notify(notice.id, notice(notice))

    fun cancel(id: Int) = manager.cancel(id)

    /**
     * A tap opens Haven through the alias, which no other app can start, and
     * the channel reads [word] from nowhere else: sent to the exported
     * activity itself, a Keep on would be any app's to press. An activity
     * intent, never a broadcast that then opens one: the platform forbids
     * that trampoline. Immutable, so nobody it is handed to can change it.
     */
    private fun tap(word: String): PendingIntent {
        val intent = Intent()
            .setComponent(ComponentName(context, ChannelWords.TAP_ALIAS))
            .putExtra(ChannelWords.TAP_EXTRA, word)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // The two differ in their extra alone, which is not what tells two pending intents apart.
        val request = if (word == ChannelWords.KEEP_ON) 1 else 0
        return PendingIntent.getActivity(context, request, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private companion object {
        const val CHANNEL = "haven_mesh_v1"
        const val TITLE = "Haven"
    }
}
