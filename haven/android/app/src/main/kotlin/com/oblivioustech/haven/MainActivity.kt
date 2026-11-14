package com.oblivioustech.haven

import android.content.Intent
import android.os.Bundle
import com.oblivioustech.haven.mesh.MeshChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /** The Bluetooth mesh's channel; null in a build without `HAVEN_MESH`, where nothing of the mesh is made. */
    private var mesh: MeshChannel? = null

    /** The system is making this activity again, with the intent that first made it: a tap in it was taken then. */
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before `super`, which configures the engine.
        restored = savedInstanceState != null
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (BuildConfig.HAVEN_MESH) {
            mesh = MeshChannel(this, flutterEngine.dartExecutor.binaryMessenger).also { it.intent(intent, replayed = restored) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mesh?.close()
        mesh = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        mesh?.intent(intent, replayed = false)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        mesh?.permissionResult(requestCode)
    }
}
