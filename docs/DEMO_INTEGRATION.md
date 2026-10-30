# Host / Viewer smoke test (bare RN 0.81.5)

This is a **testing recipe**, not a compiled example application. Build the host project normally, install the native RN library locally, and supply credentials at runtime. The RN SDK's `NosmaiCameraView` owns the camera; TRTC must **not** start a second camera.

## Host

```tsx
import React, {useEffect, useState} from 'react';
import {Platform, View, Text, Button} from 'react-native';
import {NosmaiCameraSdk, NosmaiCameraView} from '@nosmai/react-native-effects-sdk';
import {NosmaiTencentBridge, NosmaiTencentEvents} from 'react-native-nosmai-tencent-bridge';

// Supply these props from your app's authorized configuration and backend.
type HostProps = {
  sdkAppId: number;
  hostUserSig: string;
  iosLicense: string;
  androidLicense: string;
};

export function HostView({sdkAppId, hostUserSig, iosLicense, androidLicense}: HostProps) {
  const license = Platform.OS === 'ios' ? iosLicense : androidLicense;
  const [mounted, setMounted] = useState(false);
  const [ready, setReady] = useState(false);
  const [status, setStatus] = useState('not started');
  useEffect(() => {
    const sub = NosmaiTencentEvents.subscribe(e => setStatus(`${e.type}: ${e.message}`));
    return () => { sub.remove(); };
  }, []);
  useEffect(() => {
    if (!mounted) return;
    let cancelled = false;
    async function setup() {
      await NosmaiTencentBridge.initialize();
      const accepted = await NosmaiCameraSdk.initialize(license);
      if (!accepted) throw new Error('Nosmai init rejected');
      await NosmaiCameraSdk.configureCamera({position: 'front'});
      await NosmaiCameraSdk.startProcessing();
      if (!cancelled) setReady(true);
    }
    void setup().catch(error => setStatus(String(error)));
    return () => {
      cancelled = true;
      void (async () => {
        try {
          await NosmaiTencentBridge.stopStreaming();
          await NosmaiCameraSdk.stopProcessing();
          await NosmaiCameraSdk.cleanup();
        } catch (error) { console.warn('Host cleanup:', error); }
      })();
    };
  }, [mounted, license]);
  return <View style={{flex: 1}}>
    <NosmaiCameraView
      style={{flex: 1}}
      cameraPosition="front"
      mirror
      onLayout={() => setMounted(true)}
      onReady={() => { void NosmaiCameraSdk.setSkinSmoothing(0.4); }}
      onError={e => setStatus(`${e.code}: ${e.message}`)}
    />
    <Text>{status}</Text>
    <Button title="Start Host" disabled={!ready} onPress={() => {
      // Use the actual string returned by your backend for this authenticated user.
      void NosmaiTencentBridge.startStreaming({
        sdkAppId,
        roomId: 1001,
        userId: 'host_001',
        userSig: hostUserSig,
        publishAudio: true,
      }).catch(error => setStatus(String(error)));
    }}/>
    <Button title="Stop Host" onPress={() => {
      void NosmaiTencentBridge.stopStreaming();
    }}/>
  </View>;
}
```

**Important:** Pass valid license and backend-issued UserSig props, never hard-code credentials in a published app. The Host owns one camera; a real app should coordinate navigation and await stream teardown before re-mounting.

## Viewer

```tsx
import React from 'react';
import {View, Button} from 'react-native';
import {TrtcViewer, TrtcRemoteVideoView} from 'react-native-nosmai-tencent-bridge';

export function ViewerView({sdkAppId, viewerUserSig}:
  {sdkAppId: number; viewerUserSig: string}) {
  return <View style={{flex: 1}}>
    <TrtcRemoteVideoView style={{flex: 1, backgroundColor: 'black'}} />
    <Button title="Join Viewer" onPress={() => {
      void TrtcViewer.join({
        sdkAppId, roomId: 1001, userId: 'viewer_001',
        userSig: viewerUserSig, hostUserId: 'host_001',
      });
    }}/>
    <Button title="Leave Viewer" onPress={() => { void TrtcViewer.leave(); }}/>
  </View>;
}
```

Monitor `TrtcViewer.subscribe(event => ...)` for `joined`, `firstVideoFrame`, `firstAudioFrame`, `fpsStats`, `error`. Without these signals, a blank Viewer surface is not a valid streaming test.
