# Port status and known unverified items

Original input: `nosmai_tencent_bridge_ios_updated.zip` previously created from the Flutter project, not an independent vendor Native SDK sample. Flutter Android native Kotlin and iOS Objective-C code were the porting references.

| Area | Initial source | Verification |
|---|---|---|
| JS API | `src/index.ts` | Static/manual review only |
| Android NativeModules control | `NosmaiTencentBridgeModule.kt` | Not built |
| Android Host Nosmai texture -> Tencent custom input | Same Kotlin SDK calls from Flutter bridge | Not built/tested in RN camera lifecycle |
| Android Viewer | `ViewerSession.kt` + `NTBRemoteVideoViewManager.kt` | Not built |
| iOS NativeModules control/event emitter | `NosmaiTencentBridgeRN.m` | Not built |
| iOS Host Nosmai processed pixel buffer -> TRTC | Same SDK interface as tested Flutter native bridge | Not built/tested in RN camera lifecycle |
| iOS Viewer | `NTBRemoteVideoViewManager.m` | Not built |
| New Architecture (TurboModule/Fabric codegen) | Not implemented | Required for stable release |
| Official RN SDK native dependency compatibility | RN 2.0.1 / Nosmai 3.0.7 target | Must inspect built dependencies |

Potential blockers to investigate immediately:

1. RN native Nosmai Fabric View may have different ownership/routing of the processed-frame callback or EGL share setup than the Flutter implementation. **Do not claim frame handoff works until a second device receives a visibly filtered stream.**
2. The source uses RN NativeModules/legacy view interop rather than first-class TurboModule/Fabric. Confirm on RN 0.81.5 New Architecture before shipping; migrate for contemporary RN compatibility.
3. Android `compileOnly` Nosmai AAR must be available on the Gradle compile classpath and ONE copy in the app runtime. If the official RN wrapper vendors the AAR differently, align resolution rather than duplicating binaries.
4. iOS native TRTC/React pods and iOS framework headers must be checked by Xcode; Linux static review cannot confirm compilation.
5. The bridge does not own Nosmai license init or camera preview; those belong to the official RN Nosmai package and the application's Host screen.
6. Release config `package.json` intentionally sets `private:true`; this is not published.
