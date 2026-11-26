package com.oblivioustech.haven

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import androidx.core.app.NotificationCompat
import java.util.Locale

/**
 * The one "Tap to resume sharing" notification, posted when sharing was on but
 * a system start is not allowed (owner-directed 2026-11-26, OD-R2).
 *
 * Fixed text from string resources and nothing else: no name, count, circle or
 * time (Security Rule 15). The resources ship in the APK, so the very first
 * boot or update after an install has them before any new UI has run.
 */
object ResumeNotice {
    /** One id, so a repost replaces it: one notice by construction. */
    const val NOTIFICATION_ID = 4832
    const val CHANNEL_ID = "haven_resume_v1"

    fun post(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (!manager.areNotificationsEnabled()) return
        val text = localized(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Importance is locked at creation; a change needs a new id.
            val channel = NotificationChannel(
                CHANNEL_ID,
                text.getString(R.string.android_resume_notice_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { lockscreenVisibility = Notification.VISIBILITY_SECRET }
            manager.createNotificationChannel(channel)
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ?: return
        val tap = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            // A status-bar icon is drawn from its alpha alone: the launcher
            // icon's opaque square would show as a blank blob.
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(text.getString(R.string.android_resume_notice_title))
            .setContentText(text.getString(R.string.android_resume_notice_body))
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(text.getString(R.string.android_resume_notice_body)),
            )
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS revoked between the check and the post.
        }
    }

    /** Opening Haven restarts sharing from the visible activity. */
    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    /**
     * [context] in the in-app language when the user chose one, otherwise the
     * system language. Only the language code is read.
     */
    fun localized(context: Context): Context {
        val tag = HavenPrefs.localeTag(HavenPrefs.open(context)) ?: return context
        val config = Configuration(context.resources.configuration)
        config.setLocale(Locale.forLanguageTag(tag))
        return context.createConfigurationContext(config)
    }
}
