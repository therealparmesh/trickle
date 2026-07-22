package com.parmscript.trickle

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var videoChannel: MethodChannel? = null
    private var videoActive = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        videoChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.parmscript.trickle/video",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "setVideoActive") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                videoActive = call.arguments == true
                updatePictureInPictureParams()
                result.success(null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        videoChannel?.setMethodCallHandler(null)
        videoChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (
            videoActive &&
            Build.VERSION.SDK_INT in Build.VERSION_CODES.O..Build.VERSION_CODES.R
        ) {
            enterPictureInPictureMode(pictureInPictureParams())
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        videoChannel?.invokeMethod(
            "pictureInPictureChanged",
            isInPictureInPictureMode,
        )
    }

    private fun updatePictureInPictureParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        setPictureInPictureParams(pictureInPictureParams())
    }

    private fun pictureInPictureParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(videoActive)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }
}
