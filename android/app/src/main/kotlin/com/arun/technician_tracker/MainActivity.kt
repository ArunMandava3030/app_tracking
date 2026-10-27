package com.arun.technician_tracker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var control: MethodChannel? = null
    private var events: EventChannel? = null
    private var visible = false
    private var pendingStart: MethodChannel.Result? = null
    private var pendingToken: String? = null
    private var validation: PublisherApi.Request? = null
    private var validationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        control = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "technician_tracker/control")
        control?.setMethodCallHandler(::onControl)
        events = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "technician_tracker/state")
        events?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                TrackingState.sink = sink
                sink.success(TrackingState.snapshot())
            }
            override fun onCancel(arguments: Any?) { TrackingState.sink = null }
        })
    }

    private fun onControl(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> result.success(TrackingState.snapshot())
            "validateInvitation" -> validate(call.argument<String>("token"), result)
            "startSharing" -> start(call.argument<String>("token"), result)
            "stopSharing" -> stop(result)
            else -> result.notImplemented()
        }
    }

    private fun validate(token: String?, result: MethodChannel.Result) {
        if (TrackingState.snapshot()["sharing"] == true || pendingStart != null) {
            result.success(TrackingState.snapshot())
            return
        }
        cancelValidation()
        if (!PublisherApi.isToken(token)) {
            TrackingState.replace("error", "Paste a valid phone invitation link from your dispatcher.", false)
            result.success(TrackingState.snapshot())
            return
        }
        TrackingState.replace("starting", "Checking your invitation with Salesforce…", false)
        validationResult = result
        validation = PublisherApi.call("validate", token!!) { reply ->
            validation = null
            validationResult = null
            if (reply.ok && reply.active && reply.expiresAtMs != null) {
                TrackingState.replace("ready", "Invitation connected. Tap Start sharing when you are ready.", false,
                    mapOf("expiresAtMs" to reply.expiresAtMs))
            } else if (reply.code == "INVALID_INVITATION" || (reply.ok && !reply.active)) {
                TrackingState.replace("expired", "This invitation is invalid, expired, or revoked. Ask your dispatcher for a new link.", false)
            } else {
                TrackingState.replace("error", "Could not check the invitation. Check your connection and try again.", false)
            }
            result.success(TrackingState.snapshot())
        }
    }

    private fun start(token: String?, result: MethodChannel.Result) {
        if (TrackingState.snapshot()["sharing"] == true || pendingStart != null) {
            result.success(TrackingState.snapshot())
            return
        }
        cancelValidation()
        if (!PublisherApi.isToken(token)) {
            TrackingState.replace("error", "Connect a valid phone invitation before starting.", false)
            result.success(TrackingState.snapshot())
            return
        }
        if (!visible) {
            TrackingState.replace("error", "Open the app before starting location sharing.", false)
            result.success(TrackingState.snapshot())
            return
        }
        pendingStart = result
        pendingToken = token
        val permissions = mutableListOf<String>()
        // Request both together so Android offers the Precise/Approximate choice.
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION)
            permissions.add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (permissions.isNotEmpty()) requestPermissions(permissions.toTypedArray(), LOCATION_REQUEST)
        else finishStart()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == LOCATION_REQUEST && pendingStart != null) finishStart()
    }

    private fun finishStart() {
        val result = pendingStart ?: return
        val token = pendingToken
        pendingStart = null
        pendingToken = null
        val allowed = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!allowed) {
            TrackingState.replace("error", "Location permission was not granted. In Android Settings, allow Location for Technician Tracker, then try again.", false)
        } else if (!visible || token == null) {
            TrackingState.replace("error", "Keep the app open while starting location sharing, then try again.", false)
        } else {
            TrackingState.replace("starting", "Starting location sharing…", true)
            try {
                val intent = Intent(this, TrackingService::class.java)
                    .setAction(TrackingService.ACTION_START).putExtra(TrackingService.EXTRA_TOKEN, token)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                else startService(intent)
            } catch (_: Exception) {
                TrackingState.replace("error", "Android could not start sharing. Keep the app open and try again.", false)
            }
        }
        result.success(TrackingState.snapshot())
    }

    private fun stop(result: MethodChannel.Result) {
        cancelValidation()
        val pending = pendingStart
        pendingStart = null
        pendingToken = null
        if (TrackingService.instance != null) {
            TrackingService.instance?.stopByUser()
        } else {
            // A start intent may still be queued; a matching stop runs after it in the service.
            if (TrackingState.snapshot()["sharing"] == true && visible) {
                startService(Intent(this, TrackingService::class.java).setAction(TrackingService.ACTION_STOP))
            }
            TrackingState.replace("stopped", "Location sharing stopped on this phone.", false)
        }
        pending?.success(TrackingState.snapshot())
        result.success(TrackingState.snapshot())
    }

    private fun cancelValidation() {
        validation?.cancel()
        validation = null
        validationResult?.success(TrackingState.snapshot())
        validationResult = null
    }

    override fun onStart() {
        super.onStart()
        visible = true
    }

    override fun onStop() {
        visible = false
        super.onStop()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cancelValidation()
        pendingStart?.success(TrackingState.snapshot())
        pendingStart = null
        pendingToken = null
        control?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        TrackingState.sink = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object { private const val LOCATION_REQUEST = 4101 }
}
