package com.manymath.microphone_flutter

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Checks and requests the RECORD_AUDIO runtime permission for the Dart side.
 *
 * Capture itself goes through the native library over FFI; this only exists
 * because runtime permissions need an Activity.
 */
class MicrophoneFlutterPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activityBinding: ActivityPluginBinding? = null

    // Callers waiting on the permission dialog.
    private val pending = mutableListOf<MethodChannel.Result>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "microphone_flutter/permission")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        when (call.method) {
            "hasPermission" -> result.success(isGranted())
            "requestPermission" -> request(result)
            else -> result.notImplemented()
        }
    }

    private fun isGranted(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun request(result: MethodChannel.Result) {
        if (isGranted()) {
            result.success(true)
            return
        }
        // A dialog is already up; its answer completes this caller too.
        if (pending.isNotEmpty()) {
            pending.add(result)
            return
        }
        // Without an Activity there is nothing to show the dialog on.
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        pending.add(result)
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQUEST_CODE
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        // grantResults is empty when the request was interrupted, so ask the
        // system for the outcome instead.
        completePending(isGranted())
        return true
    }

    private fun completePending(granted: Boolean) {
        val waiters = pending.toList()
        pending.clear()
        waiters.forEach { it.success(granted) }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // Keep the waiters: the recreated Activity receives the dialog's
        // result and is handed back in onReattachedToActivityForConfigChanges.
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        // The result would go to an Activity that is gone, so answer with
        // whatever the user has decided so far.
        completePending(isGranted())
    }

    private companion object {
        const val REQUEST_CODE = 4817
    }
}
