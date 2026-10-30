package com.nosmai.tencentrn

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.tencent.rtmp.ui.TXCloudVideoView
import java.lang.ref.WeakReference

/**
 * Associates the native Fabric view with the legacy RN control module, regardless
 * of whether React Native creates the video ViewManager or NativeModule first.
 * All operations are serialized on the Android main thread.
 */
internal object NTBRemoteViewRegistry {
    private val main = Handler(Looper.getMainLooper())
    private var sessionRef: WeakReference<ViewerSession>? = null
    private var viewRef: WeakReference<TXCloudVideoView>? = null

    fun registerSession(session: ViewerSession) = main.post {
        val previous = sessionRef?.get()
        val view = viewRef?.get()
        if (previous !== session && previous != null && view != null) previous.detach(view)
        sessionRef = WeakReference(session)
        if (view != null) {
            Log.i("NosmaiTencentViewer", "Registry: native module available, binding retained video view")
            session.attach(view)
        }
    }.let { Unit }

    fun registerView(view: TXCloudVideoView) = main.post {
        val previous = viewRef?.get()
        val session = sessionRef?.get()
        if (previous != null && previous !== view) session?.detach(previous)
        viewRef = WeakReference(view)
        Log.i("NosmaiTencentViewer", "Registry: native video view created")
        session?.attach(view)
    }.let { Unit }

    fun unregisterView(view: TXCloudVideoView) = main.post {
        if (viewRef?.get() === view) {
            sessionRef?.get()?.detach(view)
            viewRef = null
            Log.i("NosmaiTencentViewer", "Registry: native video view detached")
        }
    }.let { Unit }
}
