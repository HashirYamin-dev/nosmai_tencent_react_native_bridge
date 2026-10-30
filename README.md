# React Native Nosmai → Tencent TRTC Bridge

**Status: ALPHA / uncompiled native port — not a verified or production-ready release.**

This is a **separate React Native package** developed from the existing Flutter Nosmai–Tencent native implementation, **not** an edit to the working Flutter plugin. Frames never pass through JavaScript: Native Nosmai output is delivered to Tencent TRTC's custom video source.

## Supported paths (implementation candidates)

| Platform | Frame handoff | Transport | Status |
|---|---|---|---|
| Android | Nosmai GPU texture + EGL/fence -> TRTC custom texture | Tencent TRTC | Ported; **not compiled/device-tested under RN** |
| iOS | Nosmai processed `CVPixelBufferRef` -> TRTC custom PixelBuffer | Tencent TRTC | Ported; **not compiled/device-tested under RN** |
| Viewer | Native Tencent video view + TRTC audio | Tencent TRTC | Ported; **not compiled/device-tested under RN** |

This alpha uses React Native's existing NativeModule/native-view interop APIs, intended for initial integration testing on **RN 0.81.5 with New Architecture enabled**. It is **not yet a first-class Codegen TurboModule/Fabric implementation**. Test RN interop before upgrading to newer versions, and migrate the package APIs to TurboModule/Fabric for a supported stable release.

## 1. Start a new test application

Use a Mac with Xcode, CocoaPods, Java/Android SDK and Node >= 20.19.4. Bare RN is recommended for this native bridge (not Expo Go):

```sh
npx @react-native-community/cli@latest init NosmaiTrtcRNTest --version 0.81.5
cd NosmaiTrtcRNTest
npm install @nosmai/react-native-effects-sdk@2.0.1
npm install ../react-native-nosmai-tencent-bridge
```

The package is currently `private: true`; it is not published on npm. It can be installed from a local filesystem during development. Keep your working Flutter repository separate.

### Android native dependencies

- Set `minSdkVersion` to at least `24` and `newArchEnabled=true`.
- Make sure the **official Nosmai RN package** supplies exactly one verified Nosmai Android AAR (`3.0.7`) to the consuming app. The bridge declares only `compileOnly` on Nosmai's native AAR, to avoid packaging a second binary.
- The bridge declares `com.tencent.liteav:LiteAVSDK_Professional:13.5.0.20670`; do not also add a conflicting Tencent TRTC edition.
- Add camera and microphone permissions, request runtime permissions for Host only.
- Build on a real compatible Android ARM device. The source port has **not** been verified against the installed RN wrapper's texture callback lifecycle, so check native source/frame events before claiming successful integration.

The official Nosmai RN installation instructions describe how to install/verify the AAR for your selected wrapper version. Some older documentation still references 3.0.4; this alpha targets the RN `2.0.1` / native `3.0.7` release baseline.

### iOS native dependencies

The bridge's podspec declares:

- `React-Core`
- `NosmaiCameraSDK 3.0.7`
- `TXLiteAVSDK_Professional 13.4.21067`

The official Nosmai RN package also declares a Nosmai iOS pod; **use one resolved native Nosmai SDK version**, avoid manually linking a second framework. In your application's `ios/Podfile`, use iOS 15+ and the usual RN setup. Run `cd ios && bundle exec pod install` or `pod install`, and inspect the pod resolution/errors.

Add to the host app's `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Camera access for live beauty filters.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access for livestream audio.</string>
```

Set an app bundle ID that matches the **iOS Nosmai license**. Test on a **physical iPhone** (SDK binary is not intended for iOS simulator). For a Viewer-only app, Nosmai initialization and camera access are unnecessary.

## 2. React Native usage

```tsx
import { NosmaiCameraSdk, NosmaiCameraView } from '@nosmai/react-native-effects-sdk';
import {
  NosmaiTencentBridge,
  NosmaiTencentEvents,
  TrtcViewer,
  TrtcRemoteVideoView,
} from 'react-native-nosmai-tencent-bridge';
```

1. Mount one `NosmaiCameraView`; wait for its layout.
2. Call `NosmaiTencentBridge.initialize()` before starting Nosmai processing, especially on Android where EGL context sharing must be validated.
3. Initialize Nosmai using **your app-bound, platform-specific license**; configure its camera and start processing.
4. After preview is ready, call `startStreaming({sdkAppId, roomId, userId, userSig, publishAudio:true})`.
5. On a different device, render `TrtcRemoteVideoView` (sized with `style`) and use `TrtcViewer.join` with the same room and **distinct** viewer ID/UserSig.
6. Wait for events `joined`, `firstVideoFrame`, `firstAudioFrame`, and check `getHostFps()` and `fpsStats` before accepting the test.
7. Stop TRTC before stopping Nosmai processing and unmounting the preview; leave the Viewer and unsubscribe from events.

See [`docs/DEMO_INTEGRATION.md`](docs/DEMO_INTEGRATION.md) for example code.

### API

| API | Purpose |
|---|---|
| `NosmaiTencentBridge.initialize()` | Initialize native TRTC services; not Nosmai license init |
| `NosmaiTencentBridge.startStreaming(options)` | Request Host TRTC publishing from Nosmai's native processed output |
| `NosmaiTencentBridge.stopStreaming()` | Stop Host TRTC publishing; leave Nosmai preview running |
| `NosmaiTencentBridge.getHostFps()` | Source, submitted and uplink FPS/bitrate counters |
| `NosmaiTencentBridge.getHostState()` | Native Host active/room connection state |
| `NosmaiTencentBridge.dispose()` | Release Host/Viewer bridge session |
| `TrtcViewer.join(options)` | Join room as audience; supply separate UserSig |
| `TrtcViewer.leave()` | Leave audience room |
| `<TrtcRemoteVideoView style={{flex:1}} />` | Render native remote video |
| `NosmaiTencentEvents.subscribe(callback)` | Host native event subscription |
| `TrtcViewer.subscribe(callback)` | Viewer native event subscription |

Do not interpret `startStreaming() === true` as a guarantee that remote video is flowing: it means the request was accepted. Confirm remote video/filtered appearance on another device.

## 3. Testing and release blockers

**Before any public GitHub/npm release:**

- Compile Android/iOS with the actual `@nosmai/react-native-effects-sdk@2.0.1` package, and fix any RN/Gradle/Podspec API compatibility errors.
- Confirm RN New Architecture interoperability. The current NativeModules/legacy-view adapter is not Codegen/Fabric native yet.
- Test Android Host → Android Viewer and iPhone Host → iPhone Viewer; then Android ↔ iOS.
- Verify a visible Nosmai filter reaches the **remote** Viewer (not just a raw camera frame); check microphone audio, 720×1280 target, FPS/bitrate.
- Test switch camera, background/foreground, network handover, stop/join/rejoin and role switching.
- Verify Android GPU texture/EGL share and release slots in failure paths; iOS pixel format/ownership and frame lifetimes.
- Check the resolved Tencent pod and Maven versions are mutually compatible.
- Use backend-issued per-user UserSigs. **Never embed SDKSecretKey, UserSigs, Nosmai license or signing certificates in the npm package/repository.**

## Sources and version baselines

- Original Flutter repository: https://github.com/HashirYamin-dev/nosmai_tencent_bridge
- Nosmai React Native quickstart: https://nosmai.com/docs/effects/quickstart/react-native/
- Nosmai platform releases: https://nosmai.com/docs/effects/releases-and-compatibility/
- Tencent custom capture: https://trtc.io/document/35158
- React Native architecture: https://reactnative.dev/blog/2025/10/08/react-native-0.82
