package com.haven.haven

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        io.crates.keyring.Keyring.initializeNdkContext(applicationContext)
    }
}
