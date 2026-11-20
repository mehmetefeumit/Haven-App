package com.oblivioustech.haven

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // The UI engine's only: the foreground-service engine never re-dials.
    private var networkChange: NetworkChangeStream? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        networkChange = NetworkChangeStream(applicationContext).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        networkChange?.unregister()
        networkChange = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
