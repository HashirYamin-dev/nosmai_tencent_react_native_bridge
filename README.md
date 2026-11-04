# Nosmai Tencent Bridge for React Native

**Nosmai Effects camera → Tencent TRTC livestreaming on Android and iOS, without moving video frames through JavaScript.**

[![React Native](https://img.shields.io/badge/React%20Native-0.81.5-blue)](https://reactnative.dev/)
![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS-green)
![Release](https://img.shields.io/badge/release-0.1.0--alpha.9-orange)

> **Release status — tested alpha (`0.1.0-alpha.9`).** Android Host → Android Viewer and iOS Host → iOS Viewer have been exercised on physical devices, with remote video at **720 × 1280 / approximately 30 FPS** in the reported tests. This is **not a production-stability guarantee**. Android ↔ iOS interoperation, fresh-install reproducibility, extended sessions, reconnection, and filter-by-filter QA still need verification. This repository is a **React Native** package; the [Flutter bridge](https://github.com/HashirYamin-dev/nosmai_tencent_bridge) is a separate project.

## Contents

1. [What this bridge does](#1-what-this-bridge-does)
2. [Requirements](#2-requirements)
3. [Install the package in a new React Native app](#3-install-the-package-in-a-new-react-native-app)
4. [Android native setup](#4-android-native-setup)
5. [iOS native setup](#5-ios-native-setup)
6. [Tencent credentials and Nosmai licenses](#6-tencent-credentials-and-nosmai-licenses)
7. [Host: Android camera and livestream](#7-host-android-camera-and-livestream)
8. [Host: iOS camera and livestream](#8-host-ios-camera-and-livestream)
9. [Viewer: Android and iOS](#9-viewer-android-and-ios)
10. [Events, FPS, and cleanup](#10-events-fps-and-cleanup)
11. [Two-device test](#11-two-device-test)
12. [Troubleshooting](#12-troubleshooting)
13. [Security and release checklist](#13-security-and-release-checklist)
14. [References](#14-references)

## 1. What this bridge does

The **Host** captures and processes camera frames with Nosmai Effects. The bridge forwards processed frames **natively** to Tencent TRTC custom video capture, which publishes video and microphone audio. The **Viewer** joins the same TRTC room using a different user identity and displays the remote video in a native React Native view.

```text
HOST (React Native)
  Nosmai camera + beauty/AR processing
       |
       | processed frames (native, not JS)
       v
  react-native-nosmai-tencent-bridge
       |
       | Android: GPU texture / EGL
       | iOS: CVPixelBuffer
       v
  Tencent TRTC custom video source + microphone
       |
       | network
       v
VIEWER (React Native)
  Tencent TRTC native video view + audio
```

The app uses TypeScript to control rooms, subscriptions, camera lifecycle, and UI. **Do not use Nosmai's sampled JS frame stream as a 30-FPS video transport. Do not open another TRTC camera on the Host.**

### Implemented APIs

```tsx
import {
  NosmaiTencentBridge,
  NosmaiTencentEvents,
  NosmaiLocalCameraView,
  TrtcViewer,
  TrtcRemoteVideoView,
} from 'react-native-nosmai-tencent-bridge';
```

| API | Purpose |
| --- | --- |
| `NosmaiTencentBridge.initialize()` | Initialize the native bridge/TRTC control path |
| `NosmaiTencentBridge.startStreaming(options)` | Request Host room entry and native video/audio publication |
| `NosmaiTencentBridge.stopStreaming()` | Stop Host stream |
| `NosmaiTencentBridge.getHostState()` | Read `{ active, connected }` |
| `NosmaiTencentBridge.getHostFps()` | Read source, submitted, uplink FPS/bitrate and dimensions |
| `NosmaiTencentBridge.muteLocalAudio(mute)` | Host, while streaming: mute/unmute the published mic (resets on stop) |
| `NosmaiTencentBridge.muteLocalVideo(mute)` | Host, while streaming: pause/resume the published video (resets on stop) |
| `NosmaiTencentEvents.subscribe(callback)` | Subscribe to Host native events (remove the returned subscription) |
| `NosmaiTencentBridge.dispose()` | Release native bridge session resources |
| `NosmaiTencentBridge.initializeNosmaiCamera(license)` | **iOS Host only:** initialize bridge-owned Nosmai camera |
| `NosmaiTencentBridge.setNosmaiSmoothing(value)` | **iOS Host only:** set smoothing |
| `NosmaiTencentBridge.switchNosmaiCamera()` | **iOS Host only:** switch camera |
| `NosmaiTencentBridge.stopNosmaiCamera()` | **iOS Host only:** release its camera |
| `<NosmaiLocalCameraView />` | **iOS Host only:** bridge-owned local preview |
| `TrtcViewer.join(options)` / `TrtcViewer.leave()` | Join/leave as a Viewer |
| `TrtcViewer.subscribe(callback)` | Subscribe to Viewer native events |
| `<TrtcRemoteVideoView />` | Android Fabric / iOS native remote video surface |

**A successful `startStreaming()` or `TrtcViewer.join()` return value only means the request was accepted.** Wait for events and actual remote FPS/picture before reporting a successful livestream.

## 2. Requirements

| Component | This alpha's tested/qualified baseline |
| --- | --- |
| React Native | `0.81.5`, New Architecture enabled |
| React | `19.1.x` |
| Node.js | `20.19.4+` |
| Nosmai React Native SDK | `@nosmai/react-native-effects-sdk@2.0.1` |
| Nosmai native Android SDK | `3.0.7` verified Android AAR |
| Nosmai native iOS SDK | `NosmaiCameraSDK 3.0.7` |
| Tencent TRTC Android | `LiteAVSDK_Professional 13.5.0.20670` declared by bridge |
| Tencent TRTC iOS | `TXLiteAVSDK_Professional 13.4.21067` declared by podspec |
| Android | API 24+; physical compatible ARM device |
| iOS | iOS 15+; **physical** arm64 iPhone (not Simulator) |
| Accounts | Valid, app-bound Nosmai licenses and Tencent TRTC SDKAppID |
| Auth | Different UserIDs and matching UserSigs for each connected user |

Native vendor versions differ between Android and iOS; **do not force their version numbers to match**. Use the versions actually declared in your checked-out package and resolved in Gradle/CocoaPods. Don't add a second, conflicting Tencent TRTC SDK edition or a second Nosmai native binary.

This package has native code. **Expo Go is not supported.** If using Expo, use a custom native development/release build and validate its native configuration separately; the steps below use bare React Native CLI.

## 3. Install the package in a new React Native app

Create a **new** bare React Native application:

```bash
npx @react-native-community/cli@latest init MyLiveApp --version 0.81.5
cd MyLiveApp
npm install @nosmai/react-native-effects-sdk@2.0.1
npm install github:HashirYamin-dev/nosmai_tencent_react_native_bridge
```

The **GitHub repository** is `nosmai_tencent_react_native_bridge`; the **npm package name** in its `package.json` is `react-native-nosmai-tencent-bridge`. These names do not need to be identical. **Do not use `npm install react-native-nosmai-tencent-bridge` until this package is actually published on npm.**

For a reproducible project, pin a **reviewed commit SHA** instead of a moving branch. Example:

```json
{
  "dependencies": {
    "react-native-nosmai-tencent-bridge": "github:HashirYamin-dev/nosmai_tencent_react_native_bridge#<REVIEWED_COMMIT_SHA>"
  }
}
```

Replace `<REVIEWED_COMMIT_SHA>` with a real commit from this repository, not a literal placeholder. If testing from a local checkout instead:

```bash
npm install ../react-native-nosmai-tencent-bridge
```

Verify native autolinking:

```bash
npm ls react-native @nosmai/react-native-effects-sdk react-native-nosmai-tencent-bridge
npx react-native config
npx tsc --noEmit
```

In the configuration output, both `@nosmai/react-native-effects-sdk` and `react-native-nosmai-tencent-bridge` should have an Android and/or iOS native entry. **Build and install the native app** after adding this package; JavaScript hot reload does not register native modules.

### Check your native setup automatically

After finishing sections 4 and 5, run the read-only setup checker from your app root:

```bash
npx nosmai-tencent-doctor
```

It reports missing `newArchEnabled`, a low `minSdkVersion`, duplicate Nosmai AARs, a low iOS deployment target, missing `Info.plist` camera/microphone descriptions, and missing Pods. It never changes files. Exit code `1` means a blocking problem was found.

## 4. Android native setup

### 4.1 Configure Android SDK and New Architecture

In `android/gradle.properties`:

```properties
newArchEnabled=true
```

In `android/app/build.gradle` (or equivalent Kotlin DSL), set a minimum SDK of 24 and use an Android `applicationId` for which your **Android Nosmai license** is valid:

```gradle
android {
    defaultConfig {
        minSdkVersion 24
        applicationId "com.yourcompany.myliveapp"
        ndk { abiFilters 'arm64-v8a' }
    }
}
```

The code above illustrates the relevant settings; merge them into your **existing** `android { defaultConfig { ... } }` block rather than pasting a second block. `applicationId` must match your licensed app identity. Prefer an ARM64 physical device for initial testing.

### 4.2 Add exactly one verified Nosmai Android AAR

The RN Nosmai package uses a native Android SDK AAR. Follow the [official Nosmai React Native installation guide](https://nosmai.com/docs/effects/installation/react-native/) and the **2.0.1 / 3.0.7** release notes for the exact verified artifact and SHA-256. Do **not** invent, rename, or download a random AAR.

If your package setup already resolves `com.nosmai:nosmai-sdk:3.0.7`, do not add another copy. If your app must supply a local AAR, place the verified file in `android/app/libs/` and wire that single binary according to the installed Nosmai RN package instructions. Check dependencies with:

```bash
cd android
./gradlew :app:dependencies --configuration debugRuntimeClasspath
cd ..
```

If Kotlin reports unresolved `NosmaiFilterInfo` / `NosmaiPipelineState`, resolve the **actual native SDK version and compilation classpath**; don't create fake classes. The bridge's Kotlin and Java compilation targets should both use JVM 17 with this RN baseline.

### 4.3 Camera, microphone and Internet permissions

**No manifest edit is needed.** The bridge's own manifest declares these, and Android merges them into your app automatically:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

A Viewer-only app that should not declare the camera can remove it in its own manifest with `<uses-permission android:name="android.permission.CAMERA" tools:node="remove" />`.

Request Host camera and microphone permissions **at runtime** (Android 6+). The Viewer doesn't need to initialize Nosmai or request Host camera permission.

```tsx
import {PermissionsAndroid, Platform} from 'react-native';

async function requestHostPermissions() {
  if (Platform.OS !== 'android') return;
  const grants = await PermissionsAndroid.requestMultiple([
    PermissionsAndroid.PERMISSIONS.CAMERA,
    PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
  ]);
  if (grants['android.permission.CAMERA'] !== 'granted' ||
      grants['android.permission.RECORD_AUDIO'] !== 'granted') {
    throw new Error('Camera and microphone permissions are required');
  }
}
```

### 4.4 Build on Android

```bash
npm start
```

In a **second terminal**:

```bash
npx react-native run-android
```

When using two USB Android devices, build once and install the **same APK** on both. Be careful: changing an existing app's `applicationId` or signing certificate can prevent updates; never uninstall another app without backing up its data.

## 5. iOS native setup

### 5.1 CocoaPods and minimum iOS target

Open `ios/Podfile` and use a compatible target of **iOS 15+**, per the React Native and Nosmai native SDK requirements. In your app root:

```bash
cd ios
pod install
cd ..
open ios/MyLiveApp.xcworkspace
```

Replace `MyLiveApp` with your generated app/workspace name. Always open **`.xcworkspace`**, not `.xcodeproj`, after installing Pods.

The bridge podspec declares `NosmaiCameraSDK 3.0.7` and `TXLiteAVSDK_Professional 13.4.21067`. The Nosmai RN dependency should resolve the **same** Nosmai native framework; don't add a duplicate manually.

### 5.2 Bundle ID, signing and permissions

In Xcode → your app target → **Signing & Capabilities**:

- Enable **Automatically manage signing** and select your Apple Development Team.
- Set a unique **Bundle Identifier** that matches your **iOS Nosmai license** exactly.
- Select a **physical iPhone** for camera and native framework testing.

Add to `ios/MyLiveApp/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Use the camera for real-time beauty effects and livestreaming.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Use the microphone for livestream audio.</string>
```

A license for Android `applicationId` is not automatically valid for the iOS Bundle Identifier.

### 5.3 Run on an iPhone

```bash
npm start
```

In another terminal, use Xcode → **Product → Run** on your physical iPhone, or:

```bash
npx react-native run-ios --device
```

The Nosmai iOS binary used here is intended for a physical ARM64 iPhone, not an Apple Silicon simulator. A debug app relies on Metro; a signed Release app should bundle JavaScript and can be tested without a cable.

**iOS Host camera ownership is different from Android in this bridge:** use the bridge's `NosmaiLocalCameraView` and `initializeNosmaiCamera()` on iOS. **Do not mount `NosmaiCameraView` simultaneously on the iOS Host**, because that can create a second camera owner and leave the processed callback without frames.

## 6. Tencent credentials and Nosmai licenses

Each app must obtain its own values. **This package does not create Tencent accounts, issue Nosmai licenses, or generate production UserSigs.**

| Value | Host | Viewer |
| --- | --- | --- |
| Tencent `sdkAppId` | Same Tencent project | Same Tencent project |
| `roomId` | Same positive numeric room ID | Same room ID |
| `userId` | Unique Host user ID | Different Viewer user ID |
| `userSig` | Signed for Host user ID | Separately signed for Viewer user ID |
| Nosmai license | Valid Android/iOS app-bound license | Not needed for Tencent-only Viewer |

Use your trusted backend to generate a **short-lived UserSig for the authenticated user**. Keep Tencent **SDKSecretKey only on the backend**. Never commit SDKSecretKey, personal Nosmai licenses, test UserSigs, private signing keys, or local credential files to GitHub. `sdkAppId` is a public project identifier, not the secret key.

For the code examples below, supply these values to the components after authentication/configuration:

```tsx
type LiveCredentials = {
  sdkAppId: number;
  roomId: number;
  hostUserId: string;
  hostUserSig: string;
  viewerUserId: string;
  viewerUserSig: string;
  androidNosmaiLicense: string;
  iosNosmaiLicense: string;
};
```

Keep credentials in an application-owned config/auth layer. The examples do **not** embed working keys.

## 7. Host: Android camera and livestream

Android uses the official Nosmai **Fabric camera preview** and SDK for processing. Mount the preview **before** starting processing. Initialize the bridge before camera processing so its native frame integration is available.

```tsx
import React, {useEffect, useState} from 'react';
import {Button, View} from 'react-native';
import {NosmaiCameraSdk, NosmaiCameraView} from '@nosmai/react-native-effects-sdk';
import {
  NosmaiTencentBridge,
  NosmaiTencentEvents,
} from 'react-native-nosmai-tencent-bridge';

export function AndroidHost({sdkAppId, roomId, userId, userSig, license}: {
  sdkAppId: number;
  roomId: number;
  userId: string;
  userSig: string;
  license: string;
}) {
  const [mounted, setMounted] = useState(false);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const sub = NosmaiTencentEvents.subscribe(event => {
      console.log('Host event:', event.type, event.message);
    });
    return () => sub.remove();
  }, []);

  async function initializeCamera() {
    await requestHostPermissions(); // implementation in section 4.3
    await NosmaiTencentBridge.initialize();
    const accepted = await NosmaiCameraSdk.initialize(license);
    if (!accepted) throw new Error('Nosmai init rejected; check license/app ID');
    await NosmaiCameraSdk.configureCamera({position: 'front'});
    await NosmaiCameraSdk.startProcessing();
    await NosmaiCameraSdk.setSkinSmoothing(0.4);
    setReady(true);
  }

  async function start() {
    await NosmaiTencentBridge.startStreaming({
      sdkAppId, roomId, userId, userSig, publishAudio: true,
    });
  }

  async function cleanup() {
    await NosmaiTencentBridge.stopStreaming();
    setReady(false);
    await NosmaiCameraSdk.stopProcessing();
    await NosmaiCameraSdk.cleanup();
    await NosmaiTencentBridge.dispose();
  }

  return <View style={{flex: 1}}>
    <NosmaiCameraView
      style={{height: 420}}
      cameraPosition="front"
      mirror
      onLayout={() => setMounted(true)}
      onError={error => console.warn('Nosmai camera:', error)}
    />
    <Button title="Initialize Nosmai" disabled={!mounted || ready}
      onPress={() => void initializeCamera().catch(console.error)} />
    <Button title="Start TRTC Live" disabled={!ready}
      onPress={() => void start().catch(console.error)} />
    <Button title="Stop and clean up"
      onPress={() => void cleanup().catch(console.error)} />
  </View>;
}
```

This is a minimal example; production apps should serialize repeated button taps, unmount the preview after stopping, coordinate navigation, and make cleanup idempotent. `requestHostPermissions()` is defined in section 4.3; import or put it in the same file.

## 8. Host: iOS camera and livestream

**Use the bridge-owned iOS Nosmai camera**, not a second `NosmaiCameraView` from the RN SDK. Mount `NosmaiLocalCameraView`, initialize the bridge, initialize the native Nosmai camera, and only then request TRTC livestreaming.

```tsx
import React, {useEffect, useState} from 'react';
import {Button, View} from 'react-native';
import {
  NosmaiTencentBridge,
  NosmaiTencentEvents,
  NosmaiLocalCameraView,
} from 'react-native-nosmai-tencent-bridge';

export function IOSHost({sdkAppId, roomId, userId, userSig, license}: {
  sdkAppId: number;
  roomId: number;
  userId: string;
  userSig: string;
  license: string;
}) {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const sub = NosmaiTencentEvents.subscribe(event => {
      console.log('iOS Host event:', event.type, event.message);
    });
    return () => sub.remove();
  }, []);

  async function initializeCamera() {
    await NosmaiTencentBridge.initialize();
    const result = await NosmaiTencentBridge.initializeNosmaiCamera(license);
    if (result === false) throw new Error('Nosmai camera initialization rejected');
    await NosmaiTencentBridge.setNosmaiSmoothing(0.4);
    setReady(true);
  }

  async function start() {
    await NosmaiTencentBridge.startStreaming({
      sdkAppId, roomId, userId, userSig, publishAudio: true,
    });
  }

  async function cleanup() {
    await NosmaiTencentBridge.stopStreaming();
    setReady(false);
    await NosmaiTencentBridge.stopNosmaiCamera();
    await NosmaiTencentBridge.dispose();
  }

  return <View style={{flex: 1}}>
    <NosmaiLocalCameraView style={{height: 420}} />
    <Button title="Initialize Nosmai" disabled={ready}
      onPress={() => void initializeCamera().catch(console.error)} />
    <Button title="Start TRTC Live" disabled={!ready}
      onPress={() => void start().catch(console.error)} />
    <Button title="Switch Camera" disabled={!ready}
      onPress={() => void NosmaiTencentBridge.switchNosmaiCamera().catch(console.error)} />
    <Button title="Stop and clean up"
      onPress={() => void cleanup().catch(console.error)} />
  </View>;
}
```

On iOS the bridge receives Nosmai's processed native `CVPixelBuffer`; Android instead uses Nosmai's native GPU texture. Do not pass frames through JS or manually start a second Tencent camera. The bridge's `armFrameTap()` is an iOS diagnostic entrypoint, **not** a substitute for a functioning native camera/processed-frame pipeline.

## 9. Viewer: Android and iOS

The Viewer needs Tencent credentials, but **does not initialize Nosmai**. Keep a **real, nonzero-sized native video view mounted before joining** (particularly important for Android Fabric). Use the same room but **different** UserIDs/UserSigs.

```tsx
import React, {useEffect} from 'react';
import {Button, View} from 'react-native';
import {
  TrtcViewer,
  TrtcRemoteVideoView,
} from 'react-native-nosmai-tencent-bridge';

export function LiveViewer({sdkAppId, roomId, viewerUserId, viewerUserSig, hostUserId}: {
  sdkAppId: number;
  roomId: number;
  viewerUserId: string;
  viewerUserSig: string;
  hostUserId: string;
}) {
  useEffect(() => {
    const sub = TrtcViewer.subscribe(event => {
      console.log('Viewer event:', event.type, event.message);
    });
    return () => sub.remove();
  }, []);

  return <View style={{flex: 1}}>
    <View collapsable={false} style={{height: 420, backgroundColor: '#000'}}>
      <TrtcRemoteVideoView
        collapsable={false}
        style={{width: '100%', height: '100%', backgroundColor: '#000'}}
      />
    </View>
    <Button title="Join Viewer" onPress={() => void TrtcViewer.join({
      sdkAppId,
      roomId,
      userId: viewerUserId,
      userSig: viewerUserSig,
      hostUserId,
    }).catch(console.error)} />
    <Button title="Leave Viewer" onPress={() => void TrtcViewer.leave().catch(console.error)} />
  </View>;
}
```

The Android native view uses **Fabric Codegen**. This alpha's previous Android black-screen bug was linked to native view lifecycle/mount timing; do not collapse, conditionally discard, or give zero height to the Viewer surface while waiting for room join. Video can be available on the TRTC network while the screen remains black if the native view is missing.

## 10. Events, FPS, and cleanup

### Subscribe to events

```tsx
const hostSubscription = NosmaiTencentEvents.subscribe(e => {
  console.log('HOST', e.type, e.message);
});
const viewerSubscription = TrtcViewer.subscribe(e => {
  console.log('VIEWER', e.type, e.message);
});

// On screen disposal:
hostSubscription.remove();
viewerSubscription.remove();
```

Typical events include `joining`, `joined`, `joinFailed`, `firstVideoFrame`, `firstAudioFrame`, `connectionLost`, `connectionRecovered`, `left`, `error`, and Viewer diagnostics such as `videoAvailable`, `viewAttached` or `viewMissing`. Exact events depend on native SDK conditions and package version.

Host diagnostics on **both** Android and iOS:

| Host event | Meaning |
| --- | --- |
| `firstSourceFrame` | The first processed Nosmai frame reached the bridge (`width`, `height`) |
| `noProcessedFrames` | No processed frames ~3 s after start — the room/audio may be live while video is black |
| `fpsStats` | Periodic TRTC send statistics (`fps`, `kbps`, `width`, `height`), so you don't have to poll `getHostFps()` |

If Host room entry fails (`joinFailed`), the bridge now releases the microphone, custom capture and Nosmai dual output by itself.

### Host effects: beauty, filters, AR, background (Android and iOS)

`NosmaiTencentEffects` is one API for both platforms. On Android it calls the Nosmai RN SDK; on iOS, where this bridge owns the Host camera, it calls the bridge's native effects methods (the RN SDK visual APIs reject on the iOS Host because they need their own camera owner). Use it after the Host reports `ready`.

```tsx
import {NosmaiTencentEffects} from 'react-native-nosmai-tencent-bridge';

const caps = await NosmaiTencentEffects.getCapabilities();      // {beauty, cloud, advanced} for this license
await NosmaiTencentEffects.setBeauty('skinSmoothing', 0.5);      // skinSmoothing | skinWhitening | teethWhitening, 0..1
await NosmaiTencentEffects.setReshape('faceSlim', 0.3);          // faceSlim, eye, nose, chin, lip, jaw, brow, ..., -1..1
const filters = await NosmaiTencentEffects.getCloudPackages('filter'); // or getLocalPackages(type)
await NosmaiTencentEffects.applyCloudPackage(filters[0]);        // downloads if needed, then applies
await NosmaiTencentEffects.setBackground({mode: 'blur', blurStrength: 0.6}); // or color / image / video
await NosmaiTencentEffects.clear('filter');                      // filter | effect | background | beauty | reshape | all
```

Package types: `filter`, `effect` (AR), `beauty_effect`, `background`, `game`. Everything applied on the Host is part of the published stream, so Viewers see it. On iOS, cloud downloads also emit `cloudDownloadProgress` Host events (`filterId`, `progress` 0..1).

### Host video quality

`startStreaming()` and `<NosmaiTencentHost session={...} />` accept an optional `video` object. Omitted fields keep the tested defaults (720p portrait, 30 FPS, 1800 kbps). Invalid values are rejected before anything starts.

```tsx
await NosmaiTencentBridge.startStreaming({
  ...hostCredentials,
  video: { resolution: '540p', fps: 24, bitrateKbps: 1200 }, // '360p' | '540p' | '720p' | '1080p'; fps 1–30; bitrate 100–8000
});
```

### Host FPS / uplink statistics

```tsx
const state = await NosmaiTencentBridge.getHostState();
const fps = await NosmaiTencentBridge.getHostFps();
console.log({
  active: state.active,
  connected: state.connected,
  sourceFps: fps.sourceFps,
  submittedFps: fps.submittedFps,
  uplinkFps: fps.uplinkFps,
  uplinkKbps: fps.uplinkKbps,
  width: fps.width,
  height: fps.height,
});
```

**Interpretation:**

- `sourceFps > 0`: frames are reaching the native source callback.
- `submittedFps > 0`: frames are being submitted to TRTC custom capture.
- `uplinkFps > 0`: TRTC reports a local video uplink; still verify Viewer picture.
- Viewer `firstVideoFrame` and nonzero received FPS with a **visible filtered image** are stronger end-to-end confirmation.
- Brief zeros during initial room entry or after stopping are expected; persistent zeros are not.

**Cleanup:** Stop publishing before releasing the Nosmai camera/preview. The Viewer calls `TrtcViewer.leave()` and removes its event listener. Do not run Host and Viewer roles simultaneously in one bridge instance. Stop and clean up the previous role before switching.

## 11. Two-device test

Install the **same app build** on both physical devices. Each connected participant requires its own UserSig.

| Device A — Host | Device B — Viewer |
| --- | --- |
| Same Tencent SDKAppID | Same Tencent SDKAppID |
| Same positive Room ID | Same Room ID |
| `host_001` for example | `viewer_001` for example |
| UserSig signed for `host_001` | UserSig signed for `viewer_001` |
| Nosmai app-bound platform license | No Nosmai camera/license needed for Viewer |
| Initialize camera, apply visible effect, Start | Mount native view, Join, verify video/audio |

For Android USB debugging on a Mac:

```bash
adb devices
adb -s <HOST_DEVICE_ID> reverse tcp:8081 tcp:8081
adb -s <VIEWER_DEVICE_ID> reverse tcp:8081 tcp:8081
```

Replace the bracketed device IDs with identifiers returned by `adb devices`. Run `npm start` in the app directory. In another terminal, install/build the Android app. **Don't overwrite a pre-existing app with the same package ID unless its data and signing identity are handled deliberately.**

Confirm all of the following before accepting the test: Host preview visible; actual beauty/AR effect visibly changes the **remote** picture; Host source/submitted/uplink FPS nonzero; Viewer first video/audio frames, visible video and nonzero received FPS; Stop/Join again; camera switch; audio playback. Repeat on both Android and iOS physical-device pairs.

**Reported same-platform test observations:** Android and iOS Host/Viewer tests have shown a 720 × 1280 portrait stream at around 30 FPS. These are observations, not fixed performance guarantees. **Android ↔ iOS cross-platform testing remains pending**.

## 12. Troubleshooting

| Symptom | Check / fix |
| --- | --- |
| `Cannot find native module` / `NosmaiTencentBridge not linked` | Install dependency, confirm RN autolinking, build native app again; Expo Go cannot load it |
| Metro `Unable to load script` | Start Metro from the correct app project, check port 8081 and `adb reverse` for each Android device |
| `EADDRINUSE` port 8081 | Another Metro is running; identify it with `lsof -nP -iTCP:8081 -sTCP:LISTEN` |
| Android `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Same app ID but different signing certificate; preserve/backup existing app data, use matching signing or a separate licensed app ID |
| Nosmai license rejected | Check Android `applicationId` or iOS Bundle Identifier and license platform |
| Android unresolved Nosmai native Kotlin types | Check the verified native AAR `3.0.7` is available on compile classpath; remove conflicting duplicates |
| Kotlin/Java JVM target mismatch | Align both compilation targets to 17 |
| Android Fabric `ViewManagerDelegate` / generated JNI missing | Check `codegenConfig`, RN Gradle plugin, and run library Codegen before Gradle app build |
| Host preview visible, `sourceFps = 0` | Nosmai processed-frame callback not active; inspect native callback/camera ownership and processing lifecycle |
| Host uplink nonzero but Viewer black | Check `TrtcRemoteVideoView` mounted with dimensions, Android Fabric `viewAttached`, and TRTC remote subscription |
| Viewer `viewMissing` | Native remote view not mounted/attached; keep it non-collapsable and mounted before room join |
| `firstAudioFrame` but no video | Audio works independently; inspect Host video callback/uplink and Viewer remote view/subscription |
| `ROLE_BUSY` | Stop Host or leave Viewer before starting another role; don't treat a failed button state as proof the native role stopped |
| iOS camera preview black | Avoid two concurrent camera owners. iOS Host uses `NosmaiLocalCameraView` + `initializeNosmaiCamera()` |
| iOS simulator build failure | Use physical iPhone; Nosmai iOS SDK is device-only in this release |
| Xcode `No space left on device` | Free build/cache disk space; don't delete source, Pods or credentials indiscriminately |
| Low FPS | Check heat, device load, selected effect, resolution and network; 30 FPS is a target |

For Android viewer native logs:

```bash
adb -s <VIEWER_DEVICE_ID> logcat -d -s NosmaiTencentViewer:V
```

Also inspect React Native, Nosmai and Tencent native error events. **Redact all licenses, UserSigs, tokens and personal data before sharing logs.**

## 13. Security and release checklist

- [ ] No Tencent SDKSecretKey, test UserSig, personal Nosmai license, `.env`, signing certificate, or credential JSON committed.
- [ ] The published package includes only library source/configuration, **not** `node_modules`, Gradle `.gradle`/`build`/`.cxx`, `Pods`, DerivedData or generated APKs.
- [ ] `npm pack --dry-run` shows only intended files and `npm run typecheck` succeeds.
- [ ] Android and iOS builds succeed in a **fresh application installed from the GitHub commit**, not just a local symlink/tarball.
- [ ] Android Host/Viewer and iOS Host/Viewer are tested with visible Nosmai effects and audio.
- [ ] Android → iOS and iOS → Android tested using the same Tencent project and compatible room settings.
- [ ] Repeated start/stop, leave/rejoin, camera switch, poor network, background/foreground, and 30+ minute sessions tested.
- [ ] Native frame ownership, GPU synchronization, thread safety, memory, battery and thermal behaviour profiled.
- [ ] Valid licenses and Tencent TRTC service plan confirmed for distribution.

The current repository is an **alpha GitHub source release**. Do not claim stable npm support or production-level zero-copy/performance guarantees until the remaining checks are complete.

## 14. References

- [Nosmai Effects React Native installation](https://nosmai.com/docs/effects/installation/react-native/)
- [Nosmai Effects React Native quickstart](https://nosmai.com/docs/effects/quickstart/react-native/)
- [Nosmai Effects releases and compatibility](https://nosmai.com/docs/effects/releases-and-compatibility/)
- [Tencent TRTC custom video capture](https://trtc.io/document/35158)
- [React Native documentation](https://reactnative.dev/docs/getting-started)
- [Flutter version of this bridge (separate repository)](https://github.com/HashirYamin-dev/nosmai_tencent_bridge)

**Support:** Open a GitHub issue with your React Native version, Android/iOS SDK versions, device model, **redacted** native logs, Host/Viewer event sequence and exact reproduction steps.
