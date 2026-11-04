package com.nosmai.tencentrn

import android.opengl.EGL14
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.nosmai.effect.api.NosmaiSDK
import com.tencent.trtc.TRTCCloud
import com.tencent.trtc.TRTCCloudDef
import com.tencent.trtc.TRTCCloudListener
import com.tencent.trtc.TRTCStatistics
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Port of the proven Flutter native capture, with RN used only for control/events. */
class NosmaiTencentBridgeModule(private val ctx: ReactApplicationContext) :
    ReactContextBaseJavaModule(ctx) {
    override fun getName() = "NosmaiTencentBridge"

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val active = AtomicBoolean(false)
    private val sourceFrames = AtomicLong(0)
    private val submittedFrames = AtomicLong(0)
    private val gpuErrorLogged = AtomicBoolean(false)
    private val firstFrameReported = AtomicBoolean(false)
    // Invalidates stale delayed "no processed frames" checks after stop/restart.
    private val hostGeneration = AtomicLong(0)
    @Volatile private var cloud: TRTCCloud? = null
    @Volatile private var connected = false
    // True between Host exitRoom() and onExitRoom(); a new enterRoom waits for it.
    @Volatile private var exitPending = false
    @Volatile private var audioMuted = false
    @Volatile private var videoMuted = false
    @Volatile private var uplinkFps = 0
    @Volatile private var uplinkKbps = 0
    @Volatile private var width = 0
    @Volatile private var height = 0
    private var sampleTime = SystemClock.elapsedRealtime()
    private var lastSource = 0L
    private var lastSubmit = 0L
    private var listeners = 0
    internal val viewer = ViewerSession(main, ::emitViewer)
    init { NTBRemoteViewRegistry.registerSession(viewer) }

    private fun emit(event: String, type: String, message: String, extras: Map<String, Any> = emptyMap()) {
        val payload = mapOf<String, Any>("type" to type, "message" to message) + extras
        main.post {
            if (ctx.hasActiveReactInstance()) {
                ctx.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
                    .emit(event, Arguments.makeNativeMap(payload))
            }
        }
    }
    private fun emitHost(type: String, msg: String, e: Map<String, Any> = emptyMap()) = emit("NTBHostEvent", type, msg, e)
    private fun emitViewer(type: String, msg: String, e: Map<String, Any> = emptyMap()) = emit("NTBViewerEvent", type, msg, e)

    private fun onWorker(op: () -> Unit) {
        try { worker.execute(op) } catch (_: RejectedExecutionException) { /* module invalidated */ }
    }

    private val listener = object : TRTCCloudListener() {
        override fun onEnterRoom(result: Long) {
            connected = result > 0
            emitHost(if (result > 0) "joined" else "joinFailed", "TRTC room result $result", mapOf("result" to result.toDouble()))
            if (result < 0) {
                // Release mic, custom capture and Nosmai dual output; the room was never entered.
                onWorker {
                    stopHost()
                    exitPending = false // a failed entry may not produce onExitRoom
                }
            }
        }
        override fun onExitRoom(reason: Int) {
            connected = false
            exitPending = false
            emitHost("left", "Host left TRTC", mapOf("reason" to reason))
        }
        override fun onConnectionLost() { emitHost("connectionLost", "Connection lost") }
        override fun onConnectionRecovery() { emitHost("connectionRecovered", "Connection recovered") }
        override fun onError(errCode: Int, errMsg: String?, extraInfo: android.os.Bundle?) {
            emitHost("error", errMsg ?: "TRTC error", mapOf("code" to errCode))
        }
        override fun onStatistics(stats: TRTCStatistics) {
            val s = stats.localArray?.firstOrNull { it.streamType == TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG }
                ?: stats.localArray?.firstOrNull()
            uplinkFps = s?.frameRate ?: 0
            uplinkKbps = s?.videoBitrate ?: 0
            width = s?.width ?: 0
            height = s?.height ?: 0
            if (active.get()) {
                emitHost("fpsStats", "TRTC send statistics", mapOf(
                    "fps" to uplinkFps, "kbps" to uplinkKbps, "width" to width, "height" to height))
            }
        }
    }

    private fun ensureCloud(): TRTCCloud = cloud ?: TRTCCloud.sharedInstance(ctx).also {
        it.setListener(listener)
        cloud = it
    }

    private fun runAsync(promise: Promise, op: () -> Any?) {
        worker.execute {
            try {
                val value = op()
                main.post { promise.resolve(value) }
            } catch (e: Throwable) {
                Log.e("NosmaiTencentRN", "Native operation failed", e)
                main.post { promise.reject("NATIVE_ERROR", e.message, e) }
            }
        }
    }

    /** Runs on the worker thread. Bounded: never blocks a new session for more than 3s. */
    private fun waitForPendingExit() {
        val deadline = SystemClock.elapsedRealtime() + 3000L
        while (exitPending && SystemClock.elapsedRealtime() < deadline) Thread.sleep(50)
        if (exitPending) Log.w("NosmaiTencentRN", "onExitRoom not received within 3s; continuing")
        exitPending = false
    }

    @ReactMethod fun addListener(eventName: String) { listeners++ }
    @ReactMethod fun removeListeners(count: Int) { listeners = (listeners - count).coerceAtLeast(0) }
    @ReactMethod fun initialize(promise: Promise) = runAsync(promise) { ensureCloud(); null }

    @ReactMethod fun getHostState(promise: Promise) = runAsync(promise) {
        Arguments.makeNativeMap(mapOf("active" to active.get(), "connected" to connected))
    }

    @ReactMethod fun getHostFps(promise: Promise) = runAsync(promise) {
        val now = SystemClock.elapsedRealtime()
        val elapsed = (now - sampleTime).coerceAtLeast(1L)
        val src = sourceFrames.get()
        val out = submittedFrames.get()
        val sourceFps = if (active.get()) ((src - lastSource) * 1000L / elapsed).toInt() else 0
        val submitFps = if (active.get()) ((out - lastSubmit) * 1000L / elapsed).toInt() else 0
        lastSource = src; lastSubmit = out; sampleTime = now
        Arguments.makeNativeMap(mapOf(
            "active" to active.get(), "sourceFps" to sourceFps,
            "submittedFps" to submitFps, "uplinkFps" to uplinkFps,
            "uplinkKbps" to uplinkKbps, "width" to width, "height" to height,
            "sourceFramesTotal" to src.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()))
    }

    private fun credentials(data: ReadableMap, viewerRole: Boolean): TRTCCloudDef.TRTCParams {
        val sdkAppId = data.getInt("sdkAppId")
        val roomId = data.getInt("roomId")
        val userId = data.getString("userId")?.takeIf { it.isNotBlank() } ?: error("Missing userId")
        val sig = data.getString("userSig")?.takeIf { it.isNotBlank() } ?: error("Missing UserSig")
        require(sdkAppId > 0 && roomId > 0) { "SDKAppID and RoomID must be positive" }
        return TRTCCloudDef.TRTCParams().apply {
            this.sdkAppId = sdkAppId
            this.roomId = roomId
            this.userId = userId
            this.userSig = sig
            role = if (viewerRole) TRTCCloudDef.TRTCRoleAudience else TRTCCloudDef.TRTCRoleAnchor
        }
    }

    /** Optional `video` options; omitted fields keep the tested 720p / 30 FPS / 1800 kbps defaults. */
    private fun encoderParam(data: ReadableMap): TRTCCloudDef.TRTCVideoEncParam {
        val v = if (data.hasKey("video") && !data.isNull("video")) data.getMap("video") else null
        fun has(key: String) = v != null && v.hasKey(key) && !v.isNull(key)
        val resolution = when (val r = if (has("resolution")) v!!.getString("resolution") else "720p") {
            "360p" -> TRTCCloudDef.TRTC_VIDEO_RESOLUTION_640_360
            "540p" -> TRTCCloudDef.TRTC_VIDEO_RESOLUTION_960_540
            "720p" -> TRTCCloudDef.TRTC_VIDEO_RESOLUTION_1280_720
            "1080p" -> TRTCCloudDef.TRTC_VIDEO_RESOLUTION_1920_1080
            else -> throw IllegalArgumentException("video.resolution must be 360p, 540p, 720p or 1080p (got $r)")
        }
        val fps = if (has("fps")) v!!.getDouble("fps").toInt() else 30
        require(fps in 1..30) { "video.fps must be between 1 and 30" }
        val bitrate = if (has("bitrateKbps")) v!!.getDouble("bitrateKbps").toInt() else 1800
        require(bitrate in 100..8000) { "video.bitrateKbps must be between 100 and 8000" }
        return TRTCCloudDef.TRTCVideoEncParam().apply {
            videoResolution = resolution
            videoResolutionMode = TRTCCloudDef.TRTC_VIDEO_RESOLUTION_MODE_PORTRAIT
            videoFps = fps
            videoBitrate = bitrate
        }
    }

    @ReactMethod fun start(data: ReadableMap, promise: Promise) = runAsync(promise) {
        check(!active.get() && !viewer.running) { "ROLE_BUSY: stop/leave current role first" }
        check(NosmaiGpuTextureSync.isAvailable()) { "Nosmai 3.0.7 synchronized GPU texture protocol unavailable" }
        val params = credentials(data, false)
        val encoder = encoderParam(data) // validate before touching any native state
        waitForPendingExit()
        val rtc = ensureCloud()
        rtc.setListener(listener)
        sourceFrames.set(0); submittedFrames.set(0)
        lastSource = 0; lastSubmit = 0; sampleTime = SystemClock.elapsedRealtime()
        connected = false; active.set(true); gpuErrorLogged.set(false); firstFrameReported.set(false)
        val generation = hostGeneration.incrementAndGet()
        try {
            NosmaiSDK.setFrameCallback(null)
            NosmaiSDK.setTextureFrameCallback { textureId, fw, fh, timestampNs, _ ->
                var completed = false
                try {
                    if (textureId > 0 && active.get() && fw in 1..4096 && fh in 1..4096) {
                        sourceFrames.incrementAndGet()
                        if (firstFrameReported.compareAndSet(false, true)) {
                            emitHost("firstSourceFrame", "First Nosmai processed frame reached native bridge",
                                mapOf("width" to fw, "height" to fh))
                        }
                        val egl = EGL14.eglGetCurrentContext()
                        check(egl != null && egl != EGL14.EGL_NO_CONTEXT) { "No Nosmai shared EGL context" }
                        check(GLES20.glIsTexture(textureId)) { "Nosmai texture invisible to TRTC share group" }
                        check(NosmaiGpuTextureSync.waitStreamFrame(textureId)) { "Nosmai texture fence not ready" }
                        val frame = TRTCCloudDef.TRTCVideoFrame().apply {
                            pixelFormat = TRTCCloudDef.TRTC_VIDEO_PIXEL_FORMAT_Texture_2D
                            bufferType = TRTCCloudDef.TRTC_VIDEO_BUFFER_TYPE_TEXTURE
                            texture = TRTCCloudDef.TRTCTexture().also { t ->
                                t.textureId = textureId
                                t.eglContext14 = egl
                            }
                            width = fw
                            height = fh
                            timestamp = 0L
                        }
                        rtc.sendCustomVideoData(TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG, frame)
                        completed = NosmaiGpuTextureSync.completeStreamFrame(textureId)
                        check(completed) { "Nosmai GPU frame completion failed" }
                        submittedFrames.incrementAndGet()
                    }
                } catch (e: Throwable) {
                    if (gpuErrorLogged.compareAndSet(false, true)) {
                        Log.e("NosmaiTencentRN", "GPU frame error", e)
                        emitHost("error", "Nosmai GPU texture handoff failed")
                    }
                } finally {
                    if (!completed && textureId > 0) {
                        try { NosmaiSDK.releaseStreamSlot(textureId) } catch (_: Throwable) {}
                    }
                }
            }
            NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.DUAL_OUTPUT)
            rtc.setVideoEncoderParam(encoder)
            rtc.enableCustomVideoCapture(TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG, true)
            if (!data.hasKey("publishAudio") || data.getBoolean("publishAudio"))
                rtc.startLocalAudio(TRTCCloudDef.TRTC_AUDIO_QUALITY_DEFAULT)
            emitHost("joining", "Host entering TRTC room")
            rtc.enterRoom(params, TRTCCloudDef.TRTC_APP_SCENE_LIVE)
            // Same diagnostic as iOS: room/audio can connect while video stays black.
            main.postDelayed({
                if (active.get() && hostGeneration.get() == generation && sourceFrames.get() == 0L) {
                    emitHost("noProcessedFrames",
                        "No processed Nosmai frames 3s after Host start; check NosmaiCameraView and startProcessing",
                        mapOf("sourceFramesTotal" to 0))
                }
            }, 3000L)
            true
        } catch (e: Throwable) { stopHost(); throw e }
    }

    private fun stopHost() {
        hostGeneration.incrementAndGet()
        if (!active.getAndSet(false)) return
        connected = false
        NosmaiSDK.setTextureFrameCallback(null)
        NosmaiSDK.setFrameCallback(null)
        try { NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.PREVIEW_ONLY) } catch (_: Throwable) {}
        cloud?.apply {
            // Mute state must not leak into the next Host session.
            if (audioMuted) muteLocalAudio(false)
            if (videoMuted) muteLocalVideo(TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG, false)
            stopLocalAudio()
            exitPending = true
            exitRoom()
            enableCustomVideoCapture(TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG, false)
        }
        audioMuted = false; videoMuted = false
        uplinkFps = 0; uplinkKbps = 0
        emitHost("stopping", "Host stop requested")
    }
    @ReactMethod fun stop(promise: Promise) = runAsync(promise) { stopHost(); null }
    @ReactMethod fun muteLocalAudio(mute: Boolean, promise: Promise) = runAsync(promise) {
        check(active.get()) { "Host is not streaming" }
        cloud?.muteLocalAudio(mute)
        audioMuted = mute
        null
    }
    @ReactMethod fun muteLocalVideo(mute: Boolean, promise: Promise) = runAsync(promise) {
        check(active.get()) { "Host is not streaming" }
        cloud?.muteLocalVideo(TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG, mute)
        videoMuted = mute
        null
    }
    @ReactMethod fun viewerJoin(data: ReadableMap, promise: Promise) = runAsync(promise) {
        check(!active.get()) { "ROLE_BUSY: stop host first" }
        val params = credentials(data, true)
        val hostUserId = data.getString("hostUserId") ?: error("Missing hostUserId")
        require(hostUserId != params.userId && hostUserId.isNotBlank()) { "Viewer UserID must differ from Host" }
        waitForPendingExit()
        viewer.join(ensureCloud(), params, hostUserId)
    }
    @ReactMethod fun viewerLeave(promise: Promise) = runAsync(promise) { viewer.leave(); null }
    @ReactMethod fun dispose(promise: Promise) = runAsync(promise) {
        viewer.leave(); stopHost(); cloud?.setListener(null); cloud = null
        exitPending = false // listener removed; onExitRoom will not arrive
        // Keep singleton lifetime with Tencent/host until app process exits.
        null
    }
    override fun invalidate() {
        worker.execute { viewer.leave(); stopHost(); cloud?.setListener(null) }
        worker.shutdown()
        super.invalidate()
    }
}
