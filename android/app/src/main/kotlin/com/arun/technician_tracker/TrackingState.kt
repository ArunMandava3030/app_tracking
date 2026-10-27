package com.arun.technician_tracker

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Process memory only. Neither invitation tokens nor coordinates are written to disk. */
internal object TrackingState {
    private val main = Handler(Looper.getMainLooper())
    private var values: Map<String, Any?> = mapOf(
        "status" to "idle",
        "message" to "Paste the invitation link sent by your dispatcher.",
        "sharing" to false
    )
    var sink: EventChannel.EventSink? = null

    fun snapshot(): Map<String, Any?> = HashMap(values)

    fun replace(status: String, message: String, sharing: Boolean, extra: Map<String, Any?> = emptyMap()) {
        check(Looper.myLooper() == Looper.getMainLooper())
        values = mapOf("status" to status, "message" to message, "sharing" to sharing) + extra
        sink?.success(snapshot())
    }

    fun update(status: String, message: String, sharing: Boolean, extra: Map<String, Any?> = emptyMap()) {
        check(Looper.myLooper() == Looper.getMainLooper())
        values = values + extra + mapOf("status" to status, "message" to message, "sharing" to sharing)
        sink?.success(snapshot())
    }

    fun post(block: () -> Unit) = main.post(block)
}
