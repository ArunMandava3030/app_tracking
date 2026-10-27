package com.arun.technician_tracker

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

internal data class PublisherReply(
    val ok: Boolean,
    val code: String = "RETRY_LATER",
    val active: Boolean = false,
    val expiresAtMs: Long? = null,
    val receivedAtMs: Long? = null,
    val acceptedCapturedAtMs: Long? = null,
    val serverTimeMs: Long? = null
)

/** A fixed HTTPS endpoint. Never follow a pasted link or a Salesforce login redirect. */
internal object PublisherApi {
    private const val ENDPOINT = "https://ddm00000pb3etuay-dev-ed.develop.my.site.com/LiveTracking/services/apexrest/technician-tracking/v1/publisher"
    private val workers = Executors.newCachedThreadPool()
    private val tokenPattern = Regex("^[0-9a-fA-F]{64}$")

    fun isToken(value: String?) = value != null && tokenPattern.matches(value)

    class Request {
        internal val cancelled = AtomicBoolean(false)
        @Volatile internal var connection: HttpURLConnection? = null
        fun cancel() {
            cancelled.set(true)
            connection?.disconnect()
        }
    }

    fun call(action: String, token: String, sample: Map<String, Any> = emptyMap(), callback: (PublisherReply) -> Unit): Request {
        val request = Request()
        workers.execute {
            val reply = execute(request, action, token, sample)
            TrackingState.post { if (!request.cancelled.get()) callback(reply) }
        }
        return request
    }

    private fun execute(request: Request, action: String, token: String, sample: Map<String, Any>): PublisherReply {
        if (!isToken(token)) return PublisherReply(false, "INVALID_INVITATION")
        var connection: HttpsURLConnection? = null
        return try {
            if (request.cancelled.get()) return PublisherReply(false)
            val payload = JSONObject().put("action", action).put("token", token.lowercase())
            sample.forEach { (key, value) -> payload.put(key, value) }
            connection = URL(ENDPOINT).openConnection() as HttpsURLConnection
            request.connection = connection
            if (request.cancelled.get()) return PublisherReply(false)
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.useCaches = false
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Cache-Control", "no-store")
            val bytes = payload.toString().toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            val status = connection.responseCode
            val contentType = connection.contentType.orEmpty().lowercase()
            // Redirects and HTML are configuration/network failures, not permission to change host.
            if (status in 300..399 || !contentType.contains("application/json")) return PublisherReply(false)
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val responseBytes = stream?.use { it.readBytesLimited(8192) } ?: return PublisherReply(false)
            val response = JSONObject(String(responseBytes, Charsets.UTF_8))
            if (status in 200..299 && response.optBoolean("ok", false)) {
                PublisherReply(
                    true,
                    active = response.optBoolean("active", false),
                    expiresAtMs = response.optionalLong("expiresAtMs"),
                    receivedAtMs = response.optionalLong("receivedAtMs"),
                    acceptedCapturedAtMs = response.optionalLong("acceptedCapturedAtMs"),
                    serverTimeMs = response.optionalLong("serverTimeMs")
                )
            } else {
                val allowed = setOf("INVALID_INVITATION", "INVALID_REQUEST", "INVALID_SAMPLE", "RETRY_LATER")
                val code = response.optString("code", "RETRY_LATER")
                PublisherReply(false, if (code in allowed) code else "RETRY_LATER")
            }
        } catch (_: Exception) {
            // Never log response bodies, invitation tokens, or location samples.
            PublisherReply(false)
        } finally {
            request.connection = null
            connection?.disconnect()
        }
    }

    private fun JSONObject.optionalLong(name: String): Long? =
        if (has(name) && !isNull(name)) optLong(name).takeIf { it > 0L } else null

    private fun java.io.InputStream.readBytesLimited(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(1024)
        while (true) {
            val read = read(buffer)
            if (read < 0) break
            if (output.size() + read > limit) throw java.io.IOException("Response too large")
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }
}
