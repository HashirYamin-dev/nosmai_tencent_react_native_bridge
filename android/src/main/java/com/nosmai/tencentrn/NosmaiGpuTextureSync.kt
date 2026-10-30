package com.nosmai.tencentrn

import android.util.Log
import com.nosmai.effect.api.NosmaiSDK
import java.lang.reflect.Method

/** GPU-only fence/slot protocol discovered from the Nosmai Agora reference implementation.
 * API is optional across SDK versions: we FAIL rather than silently using CPU I420.
 */
internal object NosmaiGpuTextureSync {
    private val waitMethod: Method? = try {
        NosmaiSDK::class.java.getMethod("waitStreamFrame", Integer.TYPE)
    } catch (_: ReflectiveOperationException) { null }
    private val completeMethod: Method? = try {
        NosmaiSDK::class.java.getMethod("completeStreamFrame", Integer.TYPE)
    } catch (_: ReflectiveOperationException) { null }
    fun isAvailable() = waitMethod != null && completeMethod != null

    fun waitStreamFrame(texId: Int): Boolean = try {
        waitMethod?.invoke(null, texId) == true
    } catch (e: Throwable) {
        Log.e("NosmaiTencentGPU", "Nosmai GPU wait/fence error", e); false
    }

    fun completeStreamFrame(texId: Int): Boolean = try {
        val method = completeMethod ?: throw IllegalStateException("Nosmai completeStreamFrame unavailable")
        method.invoke(null, texId)
        true
    } catch (e: Throwable) {
        Log.e("NosmaiTencentGPU", "Nosmai GPU completion error", e); false
    }
}
