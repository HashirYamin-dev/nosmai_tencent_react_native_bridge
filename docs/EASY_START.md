# Nosmai Tencent Bridge — Easy API (React Native)

The new **opt-in** `NosmaiTencentHost` and `NosmaiTencentViewer` components handle platform differences. Existing low-level APIs remain available and unchanged.

## In-app usage — both Android and iOS

```tsx
import React from 'react';
import type {HostOptions, ViewerOptions} from 'react-native-nosmai-tencent-bridge';
import {
  NosmaiTencentHost,
  NosmaiTencentViewer,
} from 'react-native-nosmai-tencent-bridge';

// Obtain these values from secure app configuration/auth backend.
// Do not commit licenses, Tencent UserSigs, or SDK secret keys.
function HostScreen({nosmaiKey, session}: {nosmaiKey: string; session: HostOptions}) {
  return (
    <NosmaiTencentHost
      licenseKey={nosmaiKey}
      session={session}
      style={{flex: 1}}
      smoothing={0.4}
      autoStart
      onStatus={(status, detail) => console.log('Host status:', status, detail)}
      onError={e => console.warn('Host error:', e.message)}
    />
  );
}

function ViewerScreen({session}: {session: ViewerOptions}) {
  return (
    <NosmaiTencentViewer
      session={session}
      style={{flex: 1}}
      autoJoin
      onStatus={(status, detail) => console.log('Viewer status:', status, detail)}
      onError={e => console.warn('Viewer error:', e.message)}
    />
  );
}
```

### Session shapes

```ts
// HOST — use unique host UserSig
const hostSession = {
  sdkAppId: YOUR_TENCENT_SDK_APP_ID,
  roomId: 1001,
  userId: 'host_001',
  userSig: HOST_USER_SIG_FROM_BACKEND,
  publishAudio: true,
};
// VIEWER — use different user ID / UserSig
const viewerSession = {
  sdkAppId: YOUR_TENCENT_SDK_APP_ID,
  roomId: 1001,
  userId: 'viewer_001',
  userSig: VIEWER_USER_SIG_FROM_BACKEND,
  hostUserId: 'host_001',
};
```

`licenseKey` is platform-specific: pass the **Android** license on Android and **iOS** license on iOS, each matching the installed native app identifier. Viewer needs no Nosmai license.

For manual controls, use refs:

```tsx
import {useRef} from 'react';
import {NosmaiTencentHost, type NosmaiTencentHostRef} from 'react-native-nosmai-tencent-bridge';
const host = useRef<NosmaiTencentHostRef>(null);
// <NosmaiTencentHost ref={host} autoStart={false} ... />
// await host.current?.start();
// await host.current?.stop();
// await host.current?.switchCamera();
// await host.current?.setSmoothing(0.6);
// await host.current?.muteAudio(true);  // while streaming; resets on stop
// await host.current?.muteVideo(true);
```

### What happens automatically?

**Host**: mounts correct native camera preview, requests Android camera/microphone permissions, initializes Tencent bridge and Nosmai camera, starts processed frame pipeline (Android), applies optional smoothing, requests Tencent publication, listens to native events, and stops/releases on unmount.

**Viewer**: mounts native remote video view **before** joining, requests Tencent join, delivers viewer events, leaves on unmount. Nosmai never initializes for viewer.

Android continues using the existing GPU/EGL native handoff; iOS continues using the existing processed `CVPixelBuffer` native path. **There is no new pixel processing in JS**.

**Status semantics:** `start-requested` and `join-requested` only mean the native request was accepted. Check `joined`, `first-video-frame`, remote video/audio and native FPS for a successful live stream.

### Requirements that still need app configuration

- RN 0.81.x, `react-native-nosmai-tencent-bridge`, `@nosmai/react-native-effects-sdk@2.0.1` and their native dependencies.
- iOS `Info.plist`: `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`; run `pod install` and sign a real iPhone build.
- Android Manifest: nothing to add — CAMERA, RECORD_AUDIO and INTERNET are merged from the bridge manifest; camera and mic are requested at runtime automatically.
- Run `npx nosmai-tencent-doctor` in the app root to check the native setup (read-only).
- iOS: the Host component waits for the first processed Nosmai frame before going live, so `autoStart` no longer races `VIDEO_NOT_READY`.
- Optional `session.video` (`resolution`, `fps`, `bitrateKbps`) sets Host encoder quality; defaults are 720p / 30 FPS / 1800 kbps.
- **Existing SDK Android AAR packaging issue is not changed by this patch.** If `NosmaiFilterInfo` compilation fails, configure the official AAR on the Nosmai SDK compile classpath using the verified AAR procedure. No fake classes/SDKs.
- Ensure app's Android `applicationId` / iOS Bundle ID matches its respective license.
- Mount only **one** Host or Viewer screen per native process. Use 2 devices and distinct UserSigs for testing.
- Components assume session/identity/license props are fixed for a mounted session. For another room/account, unmount and remount (change React `key`). Avoid simultaneous Host/Viewer ownership.
- Native lifecycle and reconnect/rotation tests still required on physical devices. This API is a developer-experience layer, not a new native implementation.

### Testing updated source in existing fresh app

The existing fresh app installs its bridge from GitHub. Before pushing, test from local source (do not reinstall from GitHub immediately):

```bash
cd ~/Documents/PROJECTS/react-native-nosmai-tencent-bridge
python3 ~/Downloads/ntb_easy_patch/scripts/apply_easy_api.py
npx tsc --noEmit
npm pack --pack-destination ~/Downloads
```

Then in your test app, install the newly packed tarball. **This replaces the GitHub-installed package temporarily**, so check the `npm pack` output for the exact tarball filename first. Keep private app config out of the bridge package. Run `npx tsc --noEmit` and build with Xcode / Gradle. If successful, commit the source repo and push its own release branch.

**No native code changes** are required specifically by this high-level API. Initial native integration, build settings, package versions and signed-license configuration still have to be correct.

### One-screen drop-in demo for `NosmaiBridgeFreshTest`

`examples/FreshTestApp.tsx` can replace the *test app's* `App.tsx` after a backup. It uses your pre-existing private `demoConfig.local.ts` and `androidLicense.local.ts`, and contains **no hardcoded license or UserSig**. Its two buttons mount the new Host/Viewer component directly.

```bash
cd ~/Documents/PROJECTS/NosmaiBridgeFreshTest
cp App.tsx App.before_easy_api.tsx.bak
# After unpacking ZIP to ~/Documents/PROJECTS/react-native-nosmai-tencent-bridge:
cp ~/Documents/PROJECTS/react-native-nosmai-tencent-bridge/ntb_easy_patch/examples/FreshTestApp.tsx App.tsx
npx tsc --noEmit
```

If you extract the ZIP at the repository root, its folder is `ntb_easy_patch`.
