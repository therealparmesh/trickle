package com.parmscript.trickle

import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.PowerManager
import android.util.Rational
import androidx.annotation.RequiresApi
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var videoChannel: MethodChannel? = null
    private var pictureInPictureRequest: Int? = null
    private var pictureInPictureWasActive = false
    private var pictureInPictureExitDeferredForScreenOff = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        videoChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.parmscript.trickle/video",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "enterPictureInPicture") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                val request = call.arguments as? Int
                if (request == null) {
                    result.error("invalid_request", "Missing video session.", null)
                    return@setMethodCallHandler
                }
                if (isPictureInPictureActive() || pictureInPictureRequest != null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                pictureInPictureRequest = request
                val entered = try {
                    enterPictureInPictureMode(pictureInPictureParams())
                } catch (_: RuntimeException) {
                    false
                }
                if (!entered) pictureInPictureRequest = null
                result.success(entered)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        clearPictureInPictureState()
        videoChannel?.setMethodCallHandler(null)
        videoChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            pictureInPictureWasActive = true
            pictureInPictureExitDeferredForScreenOff = false
        } else if (pictureInPictureWasActive && !isDeviceInteractive()) {
            // Locking the device can temporarily remove the PiP window. Keep
            // the video session alive so its audio continues on the lock screen.
            pictureInPictureExitDeferredForScreenOff = true
            return
        }
        notifyFlutter(
            "pictureInPictureChanged",
            mapOf(
                "active" to isInPictureInPictureMode,
                "request" to pictureInPictureRequest,
            ),
        )
    }

    override fun onResume() {
        super.onResume()
        if (!isPictureInPictureActive()) {
            if (
                pictureInPictureWasActive &&
                pictureInPictureExitDeferredForScreenOff
            ) {
                notifyFlutter(
                    "pictureInPictureChanged",
                    mapOf(
                        "active" to false,
                        "request" to pictureInPictureRequest,
                    ),
                )
            }
            clearPictureInPictureState()
        }
    }

    override fun onStop() {
        val pictureInPictureEnded =
            pictureInPictureWasActive && !isPictureInPictureActive()
        when {
            isFinishing || isChangingConfigurations ->
                clearPictureInPictureState()
            !pictureInPictureEnded -> Unit
            isDeviceInteractive() -> closeDismissedPictureInPicture()
            else -> pictureInPictureExitDeferredForScreenOff = true
        }
        super.onStop()
    }

    override fun onDestroy() {
        clearPictureInPictureState()
        super.onDestroy()
    }

    private fun closeDismissedPictureInPicture() {
        if (!pictureInPictureWasActive) return
        notifyFlutter(
            "pictureInPictureClosed",
            pictureInPictureRequest,
        )
        clearPictureInPictureState()
    }

    private fun clearPictureInPictureState() {
        pictureInPictureWasActive = false
        pictureInPictureRequest = null
        pictureInPictureExitDeferredForScreenOff = false
    }

    private fun isPictureInPictureActive(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode

    private fun isDeviceInteractive(): Boolean =
        (getSystemService(Context.POWER_SERVICE) as? PowerManager)
            ?.isInteractive != false

    private fun notifyFlutter(method: String, arguments: Any?) {
        try {
            videoChannel?.invokeMethod(method, arguments)
        } catch (_: RuntimeException) {
            // Engine teardown already stops and discards the platform view.
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pictureInPictureParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(false)
            builder.setSeamlessResizeEnabled(true)
            val sourceRect = Rect()
            if (window.decorView.getGlobalVisibleRect(sourceRect)) {
                builder.setSourceRectHint(sourceRect)
            }
        }
        return builder.build()
    }
}
