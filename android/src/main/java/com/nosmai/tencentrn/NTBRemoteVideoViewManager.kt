package com.nosmai.tencentrn

import android.util.Log
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.NTBRemoteVideoViewManagerDelegate
import com.facebook.react.viewmanagers.NTBRemoteVideoViewManagerInterface
import com.tencent.rtmp.ui.TXCloudVideoView

/** Fabric native video view backed by the SAME ViewerSession used by JS controls. */
@ReactModule(name = NTBRemoteVideoViewManager.REACT_CLASS)
class NTBRemoteVideoViewManager(private val ctx: ReactApplicationContext) :
    SimpleViewManager<TXCloudVideoView>(),
    NTBRemoteVideoViewManagerInterface<TXCloudVideoView> {
    companion object { const val REACT_CLASS = "NTBRemoteVideoView" }

    private val delegate =
        NTBRemoteVideoViewManagerDelegate<TXCloudVideoView, NTBRemoteVideoViewManager>(this)

    override fun getDelegate(): ViewManagerDelegate<TXCloudVideoView> = delegate
    override fun getName() = REACT_CLASS

    @ReactProp(name = "debugTag")
    override fun setDebugTag(view: TXCloudVideoView, debugTag: String?) {
        if (debugTag != null) Log.d("NosmaiTencentViewer", "Fabric view: $debugTag")
    }

    override fun createViewInstance(reactContext: ThemedReactContext): TXCloudVideoView =
        TXCloudVideoView(reactContext).also { view ->
            Log.i("NosmaiTencentViewer", "Fabric createViewInstance: TRTC video view created")
            NTBRemoteViewRegistry.registerView(view)
        }

    override fun onDropViewInstance(view: TXCloudVideoView) {
        NTBRemoteViewRegistry.unregisterView(view)
        super.onDropViewInstance(view)
    }
}
