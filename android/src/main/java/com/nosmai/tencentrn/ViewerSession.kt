package com.nosmai.tencentrn

import android.os.Bundle
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import android.view.View
import com.tencent.rtmp.ui.TXCloudVideoView
import com.tencent.trtc.TRTCCloud
import com.tencent.trtc.TRTCCloudDef
import com.tencent.trtc.TRTCCloudListener
import com.tencent.trtc.TRTCStatistics

/** Native Tencent audience receiver. Never opens Nosmai camera or publishes video. */
internal class ViewerSession(
    private val main: Handler,
    private val emit: (String, String, Map<String, Any>) -> Unit,
) {
    private var rtc: TRTCCloud? = null
    private var remote: TXCloudVideoView? = null
    private var watched = ""
    private var subscribed = false
    private var joined = false
    private var firstVideoReceived = false
    private var retryDone = false
    private var joinedAtMs = 0L
    private val tag = "NosmaiTencentViewer"
    @Volatile var running: Boolean = false
        private set

    private fun event(type: String, msg: String, extra: Map<String, Any> = emptyMap()) = emit(type, msg, extra)

    private val listener = object : TRTCCloudListener() {
        override fun onEnterRoom(result: Long) = main.post {
            if (result > 0) {
                joined = true
                joinedAtMs = SystemClock.elapsedRealtime()
                firstVideoReceived = false
                retryDone = false
                event("joined", "Viewer entered room", mapOf("elapsedMs" to result.toDouble()))
                subscribeIfPossible()
            } else {
                running = false; joined = false
                event("error", "Viewer failed to join: $result")
            }
        }.let { Unit }
        override fun onError(errCode: Int, errMsg: String?, extraInfo: Bundle?) =
            main.post { event("error", "TRTC $errCode: ${errMsg.orEmpty()}", mapOf("code" to errCode)) }.let { Unit }
        override fun onRemoteUserEnterRoom(userId: String?) = main.post {
            if (userId == watched) {
                event("remoteUser", "Host entered room")
                subscribeIfPossible()
            }
        }.let { Unit }
        override fun onRemoteUserLeaveRoom(userId: String?, reason: Int) = main.post {
            if (userId == watched) { unsubscribe(); event("hostLeft", "Host left room") }
        }.let { Unit }
        override fun onUserVideoAvailable(userId: String?, available: Boolean) = main.post {
            if (userId != watched) return@post
            Log.i(tag, "onUserVideoAvailable host=$userId available=$available")
            event(if (available) "videoAvailable" else "videoUnavailable", "Host video available: $available")
            if (available) subscribeIfPossible() else unsubscribe()
        }.let { Unit }
        override fun onUserAudioAvailable(userId: String?, available: Boolean) = main.post {
            if (userId == watched) event("audioAvailable", "Host audio available: $available")
        }.let { Unit }
        override fun onFirstVideoFrame(userId: String?, streamType: Int, width: Int, height: Int) = main.post {
            if (userId == watched) {
                firstVideoReceived = true
                Log.i(tag, "FIRST_VIDEO host=$userId ${width}x$height")
                event("firstVideoFrame", "First remote video", mapOf("width" to width, "height" to height))
            }
        }.let { Unit }
        override fun onFirstAudioFrame(userId: String?) = main.post {
            if (userId == watched) event("firstAudioFrame", "First remote audio")
        }.let { Unit }
        override fun onConnectionLost() { event("connectionLost", "Connection lost") }
        override fun onConnectionRecovery() { event("connectionRecovered", "Connection recovered") }
        override fun onStatistics(stats: TRTCStatistics) = main.post {
            if (!joined) return@post
            val item = stats.remoteArray?.filter { it.userId == watched }?.maxByOrNull { it.frameRate }
            event("fpsStats", "TRTC receive statistics", mapOf(
                "fps" to (item?.frameRate ?: 0), "kbps" to (item?.videoBitrate ?: 0),
                "width" to (item?.width ?: 0), "height" to (item?.height ?: 0)))
            // One-time recovery only. Never loop indefinitely if the host has no video.
            if (subscribed && !firstVideoReceived && !retryDone &&
                SystemClock.elapsedRealtime() - joinedAtMs > 8000L) {
                retryDone = true
                event("videoRetry", "No first frame after 8s; retrying startRemoteView once")
                unsubscribe()
                subscribeIfPossible()
            }
        }.let { Unit }
    }

    fun join(cloud: TRTCCloud, params: TRTCCloudDef.TRTCParams, hostId: String): Boolean {
        if (running) return false
        running = true
        main.post {
            try {
                watched = hostId; rtc = cloud; joined = false
                firstVideoReceived = false; retryDone = false
                cloud.setListener(listener)
                event("joining", "Viewer entering room")
                cloud.enterRoom(params, TRTCCloudDef.TRTC_APP_SCENE_LIVE)
            } catch (e: Throwable) {
                running = false
                event("error", "Viewer join failed: ${e.message}")
            }
        }
        return true
    }
    fun leave() = main.post {
        unsubscribe()
        if (running) rtc?.exitRoom()
        rtc?.setListener(null)
        running = false; joined = false; rtc = null
        firstVideoReceived = false; retryDone = false
        event("left", "Viewer left room")
    }
    private fun subscribeIfPossible() {
        if (!running || !joined || subscribed) return
        val view = remote ?: run {
            Log.w(tag, "Cannot subscribe: RN remote video view has not attached")
            event("viewMissing", "Waiting for RN native remote video view")
            return
        }
        val cloud = rtc ?: return
        try {
            cloud.startRemoteView(watched, TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG, view)
            subscribed = true
            Log.i(tag, "startRemoteView called for $watched BIG stream")
            event("subscribing", "startRemoteView called for $watched BIG stream")
        } catch (e: Throwable) {
            Log.e(tag, "startRemoteView failed", e)
            event("error", "startRemoteView failed: ${e.message}")
        }
    }
    private fun unsubscribe() {
        if (subscribed) rtc?.stopRemoteView(watched, TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG)
        subscribed = false
    }
    fun attach(view: TXCloudVideoView) = main.post {
        if (remote !== view) { unsubscribe(); remote = view }
        Log.i(tag, "RN TXCloudVideoView attached")
        event("viewAttached", "RN Android remote video view attached")
        subscribeIfPossible()
    }
    fun detach(view: TXCloudVideoView) = main.post {
        if (remote === view) {
            unsubscribe()
            remote = null
            event("viewDetached", "RN Android remote video view detached")
        }
    }
}
