package com.parmscript.trickle

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.util.Rational
import androidx.annotation.RequiresApi
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var videoChannel: MethodChannel? = null
    private var pictureInPictureRequest: Int? = null
    private var pictureInPictureWasActive = false

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
        pictureInPictureRequest = null
        pictureInPictureWasActive = false
        videoChannel?.setMethodCallHandler(null)
        videoChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) pictureInPictureWasActive = true
        videoChannel?.invokeMethod(
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
            pictureInPictureWasActive = false
            pictureInPictureRequest = null
        }
    }

    override fun onStop() {
        if (pictureInPictureWasActive && !isPictureInPictureActive()) {
            closeDismissedPictureInPicture()
        }
        super.onStop()
    }

    private fun closeDismissedPictureInPicture() {
        if (!pictureInPictureWasActive) return
        videoChannel?.invokeMethod(
            "pictureInPictureClosed",
            pictureInPictureRequest,
        )
        pictureInPictureWasActive = false
        pictureInPictureRequest = null
    }

    private fun isPictureInPictureActive(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode

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
