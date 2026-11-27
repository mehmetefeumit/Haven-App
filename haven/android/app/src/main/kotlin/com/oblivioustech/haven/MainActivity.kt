package com.oblivioustech.haven

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // The UI engine's only: the foreground-service engine never re-dials.
    private var networkChange: NetworkChangeStream? = null
    private var qrScanner: QrScanner? = null
    private var backgroundLocation: BackgroundLocation? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        networkChange = NetworkChangeStream(applicationContext).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
        qrScanner = QrScanner(this).also { it.register(flutterEngine) }
        backgroundLocation = BackgroundLocation(this).also { it.register(flutterEngine) }
    }

    override fun onResume() {
        super.onResume()
        // The visible activity restarts sharing itself, so the notice is moot.
        ResumeNotice.cancel(this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        networkChange?.unregister()
        networkChange = null
        qrScanner?.unregister()
        qrScanner = null
        backgroundLocation?.unregister()
        backgroundLocation = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        qrScanner?.onRequestPermissionsResult(requestCode)
        backgroundLocation?.onRequestPermissionsResult(requestCode, grantResults)
    }
}
