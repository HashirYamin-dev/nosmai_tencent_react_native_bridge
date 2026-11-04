import React from 'react';
import {
  NativeModules,
  NativeEventEmitter,
  requireNativeComponent,
  type ViewProps,
  Platform,
  View,
} from 'react-native';

/**
 * JavaScript is CONTROL PLANE ONLY. Nosmai video frames MUST remain native.
 * This candidate uses RN NativeModules / legacy-view interop on New Architecture.
 * TurboModule/Fabric migration and physical-device tests are still required.
 */
export type TrtcCredentials = {
  sdkAppId: number;
  roomId: number;
  userId: string;
  userSig: string;
};
/** Host encoder settings. Every field is optional; defaults are 720p / 30 FPS / 1800 kbps (portrait). */
export type HostVideoOptions = {
  resolution?: '360p' | '540p' | '720p' | '1080p';
  /** 1–30. */
  fps?: number;
  /** 100–8000. */
  bitrateKbps?: number;
};
export type HostOptions = TrtcCredentials & { publishAudio?: boolean; video?: HostVideoOptions };
export type ViewerOptions = TrtcCredentials & { hostUserId: string };
export type BridgeEvent = {
  type: string;
  message: string;
  [key: string]: string | number | boolean | null | undefined;
};
export type HostFps = {
  active: boolean;
  sourceFps: number;
  submittedFps: number;
  uplinkFps: number;
  uplinkKbps: number;
  width: number;
  height: number;
  // Native iOS frame-tap diagnostics. Zero confirms no processed frames
  // entered this bridge even if the camera preview and TRTC room are active.
  frameTapArmed?: boolean;
  sourceFramesTotal?: number;
  sourceWidth?: number;
  sourceHeight?: number;
  sourcePixelFormat?: number;
};
export type HostState = { active: boolean; connected: boolean };

const native = NativeModules.NosmaiTencentBridge as
  | undefined
  | {
      initialize(): Promise<void>;
      armFrameTap?: () => Promise<boolean>;
      initializeNosmaiCamera?: (license: string) => Promise<boolean>;
      stopNosmaiCamera?: () => Promise<void>;
      setNosmaiSmoothing?: (amount: number) => Promise<void>;
      switchNosmaiCamera?: () => Promise<boolean>;
      start(options: HostOptions): Promise<boolean>;
      stop(): Promise<void>;
      dispose(): Promise<void>;
      getHostState(): Promise<HostState>;
      getHostFps(): Promise<HostFps>;
      muteLocalAudio?: (mute: boolean) => Promise<void>;
      muteLocalVideo?: (mute: boolean) => Promise<void>;
      viewerJoin(options: ViewerOptions): Promise<boolean>;
      viewerLeave(): Promise<void>;
      addListener(eventName: string): void;
      removeListeners(count: number): void;
    };

function getNative() {
  if (!native) {
    throw new Error('NosmaiTencentBridge not linked. Build the native app; Expo Go is not supported.');
  }
  return native;
}

export const NosmaiTencentBridge = {
  initialize: () => getNative().initialize(),
  // iOS Host-owned preview/capture. The React Native Nosmai Fabric preview
  // must NOT be mounted on the same iOS Host screen.
  initializeNosmaiCamera: (license: string) => {
    const fn = getNative().initializeNosmaiCamera;
    if (!fn) { return Promise.reject(new Error('iOS Nosmai camera owner unavailable')); }
    return fn(license);
  },
  stopNosmaiCamera: () => getNative().stopNosmaiCamera?.() ?? Promise.resolve(),
  setNosmaiSmoothing: (amount: number) => getNative().setNosmaiSmoothing?.(amount) ?? Promise.resolve(),
  switchNosmaiCamera: () => getNative().switchNosmaiCamera?.() ?? Promise.resolve(false),
  // iOS-only diagnostic: call before NosmaiCameraSdk.startProcessing().
  // Android keeps its existing GPU texture synchronization path unchanged.
  armFrameTap: () => {
    const fn = getNative().armFrameTap;
    if (!fn) { return Promise.resolve(false); }
    return fn();
  },
  startStreaming: (options: HostOptions) => getNative().start(options),
  stopStreaming: () => getNative().stop(),
  dispose: () => getNative().dispose(),
  getHostState: () => getNative().getHostState(),
  getHostFps: () => getNative().getHostFps(),
  /** Host only, while streaming. Mute state resets when the stream stops. */
  muteLocalAudio: (mute: boolean) => {
    const fn = getNative().muteLocalAudio;
    if (!fn) { return Promise.reject(new Error('muteLocalAudio unavailable in this native build')); }
    return fn(mute);
  },
  /** Host only, while streaming. Mute state resets when the stream stops. */
  muteLocalVideo: (mute: boolean) => {
    const fn = getNative().muteLocalVideo;
    if (!fn) { return Promise.reject(new Error('muteLocalVideo unavailable in this native build')); }
    return fn(mute);
  },
};

function stream(name: 'NTBHostEvent' | 'NTBViewerEvent', cb: (e: BridgeEvent) => void) {
  const em = new NativeEventEmitter(getNative());
  return em.addListener(name, cb);
}
export const NosmaiTencentEvents = { subscribe: (cb: (e: BridgeEvent) => void) => stream('NTBHostEvent', cb) };
export const TrtcViewer = {
  join: (options: ViewerOptions) => getNative().viewerJoin(options),
  leave: () => getNative().viewerLeave(),
  subscribe: (cb: (e: BridgeEvent) => void) => stream('NTBViewerEvent', cb),
};

const NativeRemoteVideo = Platform.OS === 'android'
  ? require('./NTBRemoteVideoNativeComponent').default
  : requireNativeComponent<ViewProps>('NTBRemoteVideoView');
const NativeNosmaiLocalPreview = Platform.OS === 'ios'
  ? requireNativeComponent<ViewProps>('NTBNosmaiLocalPreview')
  : View;
export const NosmaiLocalCameraView: React.ComponentType<ViewProps> = NativeNosmaiLocalPreview;
export const TrtcRemoteVideoView: React.ComponentType<ViewProps> = NativeRemoteVideo as React.ComponentType<ViewProps>;
