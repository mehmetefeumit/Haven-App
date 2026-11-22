package com.oblivioustech.haven

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.TorchState
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LiveData
import androidx.lifecycle.Observer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import zxingcpp.BarcodeReader

/**
 * Haven's QR scanner: a CameraX preview in a Flutter platform view, with every
 * frame decoded on the device by zxing-cpp. Frames never leave the analyzer and
 * nothing is captured or written; Dart receives only decoded text, and nothing
 * here logs.
 *
 * Channel `haven.app/qr_scanner` (Dart, `QrScannerChannel`):
 *   Dart -> native: `requestAccess` / `checkAccess` -> "granted" | "denied" |
 *     "unavailable"; `setTorch {token, on}`; `switchCamera {token}`;
 *     `stop {token}`.
 *   native -> Dart: `detected {token, text}`, each distinct text once per
 *     view; `torch {token, on}`; `unavailable {token}` when no camera could
 *     be bound.
 * The token is the page's, given to the view at creation: a page closing
 * while the next one scans must not stop, steer or hear the newer camera.
 */
class QrScanner(private val activity: FlutterActivity) : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var pendingAccess: MethodChannel.Result? = null
    private var view: QrScannerView? = null

    fun register(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        engine.platformViewsController.registry.registerViewFactory(VIEW_TYPE, Factory())
    }

    fun unregister() {
        view?.dispose()
        view = null
        channel?.setMethodCallHandler(null)
        channel = null
        pendingAccess = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val target = view?.takeIf { it.token == call.argument<Int>("token") }
        when (call.method) {
            "checkAccess" -> result.success(access())
            "requestAccess" -> requestAccess(result)
            "setTorch" -> {
                target?.setTorch(call.argument<Boolean>("on") == true)
                result.success(null)
            }
            "switchCamera" -> {
                target?.switchCamera()
                result.success(null)
            }
            "stop" -> {
                target?.dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun access(): String = when {
        !activity.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) -> "unavailable"
        ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED -> "granted"
        else -> "denied"
    }

    private fun requestAccess(result: MethodChannel.Result) {
        val now = access()
        if (now != "denied") {
            result.success(now)
            return
        }
        // A second ask while the prompt is up answers the first "denied";
        // the page re-checks on its next resume.
        pendingAccess?.success("denied")
        pendingAccess = result
        ActivityCompat.requestPermissions(
            activity, arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST,
        )
    }

    /** Forwarded from MainActivity; true when the request was this scanner's. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        pendingAccess?.success(access())
        pendingAccess = null
        return true
    }

    private fun emit(method: String, arguments: Map<String, Any>) {
        channel?.invokeMethod(method, arguments)
    }

    private inner class Factory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            // One camera at a time: a newer page's view takes it from the last.
            view?.dispose()
            val token = (args as? Map<*, *>)?.get("token") as? Int ?: -1
            return QrScannerView(context, activity, token, ::emit) { closed ->
                if (view === closed) view = null
            }.also { view = it }
        }
    }

    companion object {
        const val CHANNEL = "haven.app/qr_scanner"
        const val VIEW_TYPE = "haven.app/qr_scanner_view"

        // Distinct from geolocator's permission request codes.
        private const val PERMISSION_REQUEST = 0x5143
    }
}

/**
 * One bound camera. Bound to the activity's lifecycle, so the camera stops while
 * Haven is in the background, and unbound at [dispose] — the page closing — so it
 * never outlives the scanner.
 */
class QrScannerView(
    context: Context,
    private val activity: FlutterActivity,
    val token: Int,
    private val emit: (String, Map<String, Any>) -> Unit,
    private val onDisposed: (QrScannerView) -> Unit,
) : PlatformView {
    private val previewView = PreviewView(context).apply {
        // A TextureView: a SurfaceView cannot be composed inside Flutter's view.
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }
    private val main = Handler(Looper.getMainLooper())
    private val analyzerThread: ExecutorService = Executors.newSingleThreadExecutor()
    private val reader = BarcodeReader(
        BarcodeReader.Options(
            formats = setOf(BarcodeReader.Format.QR_CODE),
            tryHarder = true,
            tryRotate = true,
            tryInvert = true,
            tryDownscale = true,
        ),
    )
    private var provider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null
    private var torch: LiveData<Int>? = null
    private val torchObserver = Observer<Int> {
        emit("torch", mapOf("token" to token, "on" to (it == TorchState.ON)))
    }
    private var camera: Camera? = null
    private var lens = CameraSelector.LENS_FACING_BACK
    private var lastText: String? = null
    private var disposed = false

    init {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            // The page may have closed before CameraX was ready.
            if (disposed) return@addListener
            provider = runCatching { future.get() }.getOrNull()
            if (provider == null) emit("unavailable", mapOf("token" to token)) else bind()
        }, ContextCompat.getMainExecutor(context))
    }

    override fun getView(): View = previewView

    fun setTorch(on: Boolean) {
        val bound = camera ?: return
        if (bound.cameraInfo.hasFlashUnit()) bound.cameraControl.enableTorch(on)
    }

    fun switchCamera() {
        val other = if (lens == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        val available = provider?.let { runCatching { it.hasCamera(selector(other)) }.getOrDefault(false) }
        if (available != true) return
        lens = other
        bind()
    }

    private fun selector(facing: Int) = CameraSelector.Builder().requireLensFacing(facing).build()

    private fun bind() {
        val cameras = provider ?: return
        unbind()
        // A device with only a front camera still scans.
        if (!runCatching { cameras.hasCamera(selector(lens)) }.getOrDefault(false)) {
            lens = if (lens == CameraSelector.LENS_FACING_BACK) {
                CameraSelector.LENS_FACING_FRONT
            } else {
                CameraSelector.LENS_FACING_BACK
            }
        }
        val newPreview = Preview.Builder().build().also {
            it.surfaceProvider = previewView.surfaceProvider
        }
        val newAnalysis = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder().setResolutionStrategy(
                    ResolutionStrategy(
                        ANALYSIS_SIZE,
                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                    ),
                ).build(),
            )
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        newAnalysis.setAnalyzer(analyzerThread) { image ->
            // Closing the frame is what lets CameraX deliver the next one.
            val text = image.use { frame ->
                runCatching { reader.read(frame) }.getOrNull()
                    ?.firstNotNullOfOrNull { result -> result.text?.takeIf { it.isNotEmpty() } }
            }
            if (text != null) main.post { deliver(text) }
        }
        val bound = runCatching {
            cameras.bindToLifecycle(activity, selector(lens), newPreview, newAnalysis)
        }.getOrNull()
        if (bound == null) {
            emit("unavailable", mapOf("token" to token))
            return
        }
        preview = newPreview
        analysis = newAnalysis
        camera = bound
        torch = bound.cameraInfo.torchState.also { it.observe(activity, torchObserver) }
    }

    private fun deliver(text: String) {
        if (disposed || text == lastText) return
        lastText = text
        emit("detected", mapOf("token" to token, "text" to text))
    }

    private fun unbind() {
        torch?.removeObserver(torchObserver)
        torch = null
        analysis?.clearAnalyzer()
        val useCases = listOfNotNull(preview, analysis)
        if (useCases.isNotEmpty()) provider?.unbind(*useCases.toTypedArray())
        preview = null
        analysis = null
        camera = null
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        unbind()
        analyzerThread.shutdown()
        main.removeCallbacksAndMessages(null)
        onDisposed(this)
    }

    private companion object {
        // Enough pixels for a QR code across the frame, few enough to decode
        // every frame; CameraX picks the closest size the camera offers.
        val ANALYSIS_SIZE = Size(1280, 720)
    }
}
