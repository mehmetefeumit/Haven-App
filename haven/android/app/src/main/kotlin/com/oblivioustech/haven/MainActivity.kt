package com.oblivioustech.haven

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Privacy: FLAG_SECURE keeps on-screen content (member locations and
        // avatars) out of the OS app-switcher/recents thumbnail and blocks
        // screenshots + screen recording. Haven is a privacy-first location
        // app, so this app-wide protection is intentional. NOTE: this also
        // prevents the user from taking screenshots — to allow screenshots,
        // remove this single `setFlags` call.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        io.crates.keyring.Keyring.initializeNdkContext(applicationContext)
    }
}
