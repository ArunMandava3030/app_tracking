package com.arun.technician_tracker

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import kotlin.math.abs

/** Owns both GPS and uploads. Flutter may be suspended while this foreground service runs. */
class TrackingService : Service(), LocationListener {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var locations: LocationManager
    private lateinit var uploadWakeLock: PowerManager.WakeLock
    private var token: String? = null
    private var request: PublisherApi.Request? = null
    private var latest: Location? = null
    private var lastPublishedCapturedAt = 0L
    private var lastRequestElapsed = 0L
    private var lastValidatedElapsed = 0L
    private var expiryElapsed = Long.MAX_VALUE
    private var expiresAt: Long? = null
    private var active = false
    private var collecting = false
    private var generation = 0
    private var failures = 0
    private var lastNotificationText = ""

    private val tick = object : Runnable {
        override fun run() {
            if (!active) return
            if (SystemClock.elapsedRealtime() >= expiryElapsed) {
                finish("expired", "This invitation has expired. Ask your dispatcher for a new link.")
                return
            }
            if (collecting && !hasLocationPermission()) {
                finish("error", "Location permission was removed. Allow location access and start again.")
                return
            }
            if (collecting) {
                val fix = latest
                if (fix != null && System.currentTimeMillis() - fix.time > 30_000L) {
                    TrackingState.update("retrying", "No fresh GPS fix is available. Your map shows the last saved location.", true)
                    updateNotification("Waiting for a fresh location fix")
                }
                publishLatest()
                // Detect revocation even when no new location fix is available indoors.
                if (request == null && SystemClock.elapsedRealtime() - lastValidatedElapsed >= 30_000L &&
                    (fix == null || fix.time <= lastPublishedCapturedAt || System.currentTimeMillis() - fix.time > 110_000L)) {
                    checkInvitationWhileWaiting()
                }
            }
            main.postDelayed(this, 5000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        locations = getSystemService(LOCATION_SERVICE) as LocationManager
        uploadWakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TechnicianTracker:upload")
        uploadWakeLock.setReferenceCounted(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL, "Active location sharing", NotificationManager.IMPORTANCE_LOW)
            channel.description = "Shows when this phone is sharing location and provides a Stop button."
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopByUser()
            return START_NOT_STICKY
        }
        val invitation = intent?.getStringExtra(EXTRA_TOKEN)
        if (active) return START_NOT_STICKY
        if (!PublisherApi.isToken(invitation) || !hasLocationPermission()) {
            finish("error", "A valid invitation and location permission are required to start sharing.")
            return START_NOT_STICKY
        }
        token = invitation!!.lowercase()
        active = true
        generation++
        latest = null
        lastPublishedCapturedAt = 0L
        lastRequestElapsed = 0L
        lastValidatedElapsed = 0L
        expiryElapsed = Long.MAX_VALUE
        expiresAt = null
        failures = 0
        TrackingState.replace("starting", "Connecting to your tracking session…", true)
        try {
            val notification = notification("Connecting to your tracking session")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            finish("error", "Android could not start location sharing. Keep the app open and try again.")
            return START_NOT_STICKY
        }
        val currentGeneration = generation
        acquireUploadLock()
        request = PublisherApi.call("validate", token!!) { reply ->
            releaseUploadLock()
            if (!active || generation != currentGeneration) return@call
            request = null
            if (!reply.ok || !reply.active || reply.expiresAtMs == null || reply.serverTimeMs == null) {
                val invalid = reply.code == "INVALID_INVITATION" || (reply.ok && !reply.active)
                finish(if (invalid) "expired" else "error", if (invalid)
                    "This invitation is invalid, expired, or revoked. Ask your dispatcher for a new link."
                    else "Could not connect to Salesforce. Check your connection and start again.")
                return@call
            }
            if (abs(System.currentTimeMillis() - reply.serverTimeMs) > 60_000L) {
                finish("error", "Your phone clock differs from Salesforce. Enable automatic date and time, then try again.")
                return@call
            }
            expiresAt = reply.expiresAtMs
            lastValidatedElapsed = SystemClock.elapsedRealtime()
            expiryElapsed = SystemClock.elapsedRealtime() + (reply.expiresAtMs - reply.serverTimeMs).coerceAtLeast(0L)
            if (SystemClock.elapsedRealtime() >= expiryElapsed) {
                finish("expired", "This invitation has expired. Ask your dispatcher for a new link.")
                return@call
            }
            startLocations()
        }
        return START_NOT_STICKY
    }

    private fun hasLocationPermission(): Boolean =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun startLocations() {
        try {
            val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            val providers = mutableListOf<String>()
            val available = locations.allProviders
            if (fine && available.contains(LocationManager.GPS_PROVIDER)) providers.add(LocationManager.GPS_PROVIDER)
            if (available.contains(LocationManager.NETWORK_PROVIDER)) providers.add(LocationManager.NETWORK_PROVIDER)
            if (providers.none { locations.isProviderEnabled(it) }) {
                finish("error", "Turn on your phone’s Location setting, then start sharing again.")
                return
            }
            providers.forEach { provider ->
                locations.requestLocationUpdates(provider, 5000L, 0f, this, Looper.getMainLooper())
            }
            collecting = true
            val message = if (fine) "Waiting for a fresh GPS fix. You can lock your screen."
                else "Waiting for an approximate location. Enable Precise location for a more accurate map."
            TrackingState.update("starting", message, true, mapOf("expiresAtMs" to expiresAt))
            updateNotification("Waiting for a location fix")
            main.post(tick)
        } catch (_: SecurityException) {
            finish("error", "Location permission is required. Allow location access and start again.")
        } catch (_: Exception) {
            finish("error", "Location services could not start. Check your phone’s Location setting and try again.")
        }
    }

    override fun onLocationChanged(location: Location) {
        if (!active || !collecting) return
        val ageMs = (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000L
        if (ageMs !in 0L..120_000L || !location.hasAccuracy() || location.accuracy < 0 ||
            !location.latitude.isFinite() || !location.longitude.isFinite() || !location.accuracy.isFinite()) return
        if (location.time < System.currentTimeMillis() - 120_000L || location.time > System.currentTimeMillis() + 60_000L) return
        val previous = latest
        // Do not replace a recent precise GPS fix with a much less accurate network estimate.
        if (previous != null && previous.provider == LocationManager.GPS_PROVIDER &&
            location.provider != LocationManager.GPS_PROVIDER &&
            location.time - previous.time < 10_000L && location.accuracy > previous.accuracy * 2) return
        if (previous != null && location.time <= previous.time) return
        latest = Location(location)
        TrackingState.update(
            TrackingState.snapshot()["status"] as? String ?: "starting",
            TrackingState.snapshot()["message"] as? String ?: "Receiving phone location…",
            true,
            mapOf("latitude" to location.latitude, "longitude" to location.longitude,
                "accuracy" to location.accuracy.toDouble(), "capturedAtMs" to location.time)
        )
        publishLatest()
    }

    private fun publishLatest() {
        if (!active || !collecting || request != null) return
        if (SystemClock.elapsedRealtime() >= expiryElapsed) {
            finish("expired", "This invitation has expired. Ask your dispatcher for a new link.")
            return
        }
        val location = latest ?: return
        if (location.time <= lastPublishedCapturedAt || location.time < System.currentTimeMillis() - 110_000L) return
        val retryDelay = if (failures == 0) 5000L else (5000L * (1L shl failures.coerceAtMost(3))).coerceAtMost(30_000L)
        if (lastRequestElapsed != 0L && SystemClock.elapsedRealtime() - lastRequestElapsed < retryDelay) return
        val invitation = token ?: return
        val currentGeneration = generation
        lastRequestElapsed = SystemClock.elapsedRealtime()
        acquireUploadLock()
        request = PublisherApi.call("publish", invitation, mapOf(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "accuracy" to location.accuracy.toDouble(),
            "capturedAtMs" to location.time
        )) { reply ->
            releaseUploadLock()
            if (!active || generation != currentGeneration) return@call
            request = null
            when {
                reply.ok && reply.active && reply.receivedAtMs != null &&
                    reply.acceptedCapturedAtMs != null && reply.acceptedCapturedAtMs >= location.time -> {
                    failures = 0
                    lastValidatedElapsed = SystemClock.elapsedRealtime()
                    lastPublishedCapturedAt = maxOf(location.time, reply.acceptedCapturedAtMs)
                    val acceptedThisFix = reply.acceptedCapturedAtMs == location.time
                    TrackingState.update(if (acceptedThisFix) "sharing" else "retrying",
                        if (acceptedThisFix) "Sharing GPS with Salesforce. You can lock your screen."
                        else "Salesforce already has a newer GPS fix. Waiting for this phone’s next fix.", true,
                        mapOf("receivedAtMs" to reply.receivedAtMs, "expiresAtMs" to expiresAt))
                    updateNotification(if (acceptedThisFix) "Sharing location with your tracking session" else "Waiting for the next location fix")
                }
                reply.ok && reply.active ->
                    finish("error", "Salesforce did not return a GPS save receipt. Contact your dispatcher before restarting.")
                reply.code == "INVALID_INVITATION" || (reply.ok && !reply.active) ->
                    finish("expired", "This invitation is invalid, expired, or revoked. Ask your dispatcher for a new link.")
                reply.code == "INVALID_SAMPLE" -> {
                    // Drop this fix; never alter a captured timestamp to make an old fix look current.
                    lastPublishedCapturedAt = location.time
                    TrackingState.update("retrying", "Salesforce rejected this GPS fix. Waiting for a fresh fix; check automatic date and time.", true)
                    updateNotification("Waiting for a valid location fix")
                }
                reply.code == "INVALID_REQUEST" ->
                    finish("error", "The mobile publisher is not configured correctly. Contact your dispatcher.")
                else -> {
                    failures++
                    TrackingState.update("retrying", "GPS is active, but Salesforce has not saved this update. Retrying when connected…", true)
                    updateNotification("Connection lost — retrying location upload")
                }
            }
        }
    }

    private fun checkInvitationWhileWaiting() {
        val invitation = token ?: return
        val currentGeneration = generation
        lastValidatedElapsed = SystemClock.elapsedRealtime()
        acquireUploadLock()
        request = PublisherApi.call("validate", invitation) { reply ->
            releaseUploadLock()
            if (!active || generation != currentGeneration) return@call
            request = null
            if (reply.code == "INVALID_INVITATION" || (reply.ok && !reply.active)) {
                finish("expired", "This invitation is invalid, expired, or revoked. Ask your dispatcher for a new link.")
            } else if (!reply.ok) {
                TrackingState.update("retrying", "Could not reach Salesforce. Waiting for a fresh fix and a connection…", true)
            }
        }
    }

    override fun onProviderDisabled(provider: String) {
        if (active) TrackingState.update("retrying", "Location was switched off or lost. Turn on Location to resume fresh updates.", true)
    }

    override fun onProviderEnabled(provider: String) = Unit
    @Deprecated("Legacy LocationListener callback")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit

    fun stopByUser() {
        val invitation = token
        finish("stopped", "Location sharing stopped on this phone.")
        if (invitation != null) {
            val stoppedGeneration = generation
            PublisherApi.call("stop", invitation) { reply ->
                // Do not replace the state of a newly started invitation.
                if (instance?.active == true || generation != stoppedGeneration ||
                    TrackingState.snapshot()["sharing"] == true || TrackingState.snapshot()["status"] != "stopped") return@call
                if (reply.ok || reply.code == "INVALID_INVITATION") {
                    TrackingState.update("stopped", "Location sharing stopped. This invitation can no longer publish.", false)
                } else {
                    TrackingState.update("stopped", "Stopped on this phone. Salesforce could not revoke the link; ask your dispatcher to revoke it before forwarding it.", false)
                }
            }
        }
    }

    private fun finish(status: String, message: String) {
        active = false
        collecting = false
        generation++
        token = null
        latest = null
        request?.cancel()
        request = null
        main.removeCallbacksAndMessages(null)
        try { locations.removeUpdates(this) } catch (_: Exception) { }
        releaseUploadLock()
        TrackingState.update(status, message, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    private fun acquireUploadLock() { uploadWakeLock.acquire(40_000L) }
    private fun releaseUploadLock() { if (uploadWakeLock.isHeld) uploadWakeLock.release() }

    private fun notification(message: String): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), flags)
        val stop = PendingIntent.getService(this, 2, Intent(this, TrackingService::class.java).setAction(ACTION_STOP), flags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder.setSmallIcon(R.drawable.ic_tracking)
            .setContentTitle("Technician location sharing")
            .setContentText(message)
            .setStyle(Notification.BigTextStyle().bigText(message))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Stop sharing", stop).build())
            .build()
    }

    private fun updateNotification(message: String) {
        if (lastNotificationText == message) return
        lastNotificationText = message
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification(message))
    }

    override fun onDestroy() {
        if (active) {
            active = false
            collecting = false
            generation++
            token = null
            latest = null
            request?.cancel()
            request = null
            main.removeCallbacksAndMessages(null)
            try { locations.removeUpdates(this) } catch (_: Exception) { }
            releaseUploadLock()
            TrackingState.update("stopped", "Android stopped location sharing. Open the app and start again.", false)
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_START = "com.arun.technician_tracker.START"
        const val ACTION_STOP = "com.arun.technician_tracker.STOP"
        const val EXTRA_TOKEN = "invitation"
        private const val CHANNEL = "technician_location_sharing"
        private const val NOTIFICATION_ID = 1001
        var instance: TrackingService? = null
            private set
    }
}
